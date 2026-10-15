//! HTTP 层：路由、鉴权、端点实现。
//!
//! 端点对照设计契约 §3.4：
//!
//! | 方法   | 路径                                   |
//! |--------|----------------------------------------|
//! | GET    | `/health`（免鉴权）                    |
//! | POST   | `/torrents`                            |
//! | GET    | `/torrents`                            |
//! | GET    | `/torrents/{id}`                       |
//! | GET    | `/torrents/{id}/stats`                 |
//! | POST   | `/torrents/{id}/pause` · `/resume`     |
//! | DELETE | `/torrents/{id}?deleteFiles=true|false`|
//! | GET    | `/torrents/{id}/files/{idx}/stream`    |
//! | GET    | `/events`（SSE）                       |
//! | POST   | `/shutdown`（契约 §4.1 的优雅停止入口）|

use std::collections::HashMap;
use std::convert::Infallible;
use std::future::Future;
use std::io::SeekFrom;
use std::net::SocketAddr;
use std::num::NonZeroU32;
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Duration;

use axum::body::Body;
use axum::extract::rejection::JsonRejection;
use axum::extract::{Path, Query, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::middleware::{self, Next};
use axum::response::sse::{Event, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, patch, post};
use axum::{Json, Router};
use base64::Engine as _;
use futures::stream::{Stream, StreamExt};
use librqbit::api::TorrentIdOrHash;
use librqbit::{AddTorrent, AddTorrentOptions, AddTorrentResponse, Magnet, TorrentStatsState};
use serde::Deserialize;
use serde_json::json;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncSeekExt, ReadBuf};
use tokio::sync::broadcast;
use tokio_stream::wrappers::BroadcastStream;
use tokio_util::io::ReaderStream;

use crate::state::{AppState, ResolveOutcome};

/// 契约 §3.5：磁力链等元数据就绪的默认超时。
pub const DEFAULT_METADATA_TIMEOUT_MS: u64 = 120_000;
/// 契约 §3.8：流式转发分块大小。
pub const STREAM_CHUNK: usize = 64 * 1024;

#[derive(Debug)]
pub struct ApiError {
    pub status: StatusCode,
    pub body: serde_json::Value,
}

impl ApiError {
    pub fn raw(status: StatusCode, body: serde_json::Value) -> Self {
        Self { status, body }
    }

    pub fn new(status: StatusCode, code: &str, message: impl Into<String>) -> Self {
        Self::raw(status, json!({ "error": code, "message": message.into() }))
    }

    pub fn bad_request(code: &str, message: impl Into<String>) -> Self {
        Self::new(StatusCode::BAD_REQUEST, code, message)
    }

    pub fn unauthorized() -> Self {
        Self::new(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            "missing or invalid token",
        )
    }

    pub fn not_found(code: &str, message: impl Into<String>) -> Self {
        Self::new(StatusCode::NOT_FOUND, code, message)
    }

    pub fn internal(code: &str, message: impl Into<String>) -> Self {
        Self::new(StatusCode::INTERNAL_SERVER_ERROR, code, message)
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.status, Json(self.body)).into_response()
    }
}

pub type ApiResult = Result<Response, ApiError>;

/// 这次 `POST /torrents` 是「发起解析」还是「复用别人正在跑的解析」。
enum AddOrigin {
    Leader,
    Join(broadcast::Receiver<ResolveOutcome>),
}

/// 组装路由：`/health` 免鉴权，其余全部要 token。
pub fn router(state: AppState) -> Router {
    let protected = Router::new()
        .route("/torrents", get(list_torrents).post(add_torrent))
        .route("/torrents/{id}", get(get_torrent).delete(delete_torrent))
        .route("/torrents/{id}/stats", get(get_torrent))
        .route("/torrents/{id}/pause", post(pause_torrent))
        .route("/torrents/{id}/resume", post(resume_torrent))
        .route("/torrents/{id}/files/{idx}/stream", get(stream_file))
        .route("/events", get(events))
        .route("/limits", patch(patch_limits))
        .route("/shutdown", post(shutdown))
        .layer(middleware::from_fn_with_state(state.clone(), require_auth));

    Router::new()
        .route("/health", get(health))
        .merge(protected)
        .with_state(state)
}

// ---------------------------------------------------------------- 鉴权

/// 恒定时间比较，避免 token 比较泄露长度以外的时序信息。
fn secure_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

fn query_token(query: Option<&str>) -> Option<&str> {
    let query = query?;
    for pair in query.split('&') {
        if let Some(value) = pair.strip_prefix("token=") {
            return Some(value);
        }
    }
    None
}

fn is_authorized(state: &AppState, headers: &HeaderMap, query: Option<&str>) -> bool {
    if let Some(value) = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
    {
        if secure_eq(value.trim(), &state.token) {
            return true;
        }
    }
    // mpv 直接拉流 URL，无法自定义 header，因此额外允许 ?token=（契约 §3.3）。
    query_token(query)
        .map(|t| secure_eq(t, &state.token))
        .unwrap_or(false)
}

async fn require_auth(
    State(state): State<AppState>,
    req: axum::extract::Request,
    next: Next,
) -> Response {
    if is_authorized(&state, req.headers(), req.uri().query()) {
        next.run(req).await
    } else {
        ApiError::unauthorized().into_response()
    }
}

// ---------------------------------------------------------------- 基础端点

async fn health(State(state): State<AppState>) -> Json<serde_json::Value> {
    Json(json!({
        "ok": true,
        "version": state.version,
        "sessions": state.torrent_count(),
    }))
}

async fn shutdown(State(state): State<AppState>) -> Json<serde_json::Value> {
    // 优雅停止入口（契约 §4.1）。先返回 200 再退出：Dart 侧只给 2s 超时。
    tracing::info!("shutdown requested via POST /shutdown");
    state.shutdown.notify_one();
    Json(json!({ "ok": true }))
}

async fn list_torrents(State(state): State<AppState>) -> Json<serde_json::Value> {
    Json(json!({ "torrents": state.list_views() }))
}

async fn get_torrent(State(state): State<AppState>, Path(id): Path<String>) -> ApiResult {
    let idx = parse_torrent_id(&id)?;
    match state.view_of(idx) {
        Some(view) => Ok(Json(view).into_response()),
        None => Err(ApiError::not_found(
            "no_such_torrent",
            format!("no torrent with id {id}"),
        )),
    }
}

// ---------------------------------------------------------------- POST /torrents

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AddTorrentRequest {
    pub magnet: Option<String>,
    pub info_hash: Option<String>,
    pub torrent_base64: Option<String>,
    pub name: Option<String>,
    pub only_files: Option<Vec<usize>>,
    pub start_paused: Option<bool>,
    pub sub_folder: Option<String>,
    pub metadata_timeout_ms: Option<u64>,
    /// 扩展（契约未定义，本地测试/调试用）：直连 peer，形如 `127.0.0.1:16001`。
    pub initial_peers: Option<Vec<String>>,
}

fn parse_torrent_id(raw: &str) -> Result<TorrentIdOrHash, ApiError> {
    TorrentIdOrHash::parse(raw).map_err(|e| {
        ApiError::bad_request(
            "bad_id",
            format!("{raw:?} is neither an integer id nor a 40-char info hash: {e:#}"),
        )
    })
}

fn is_hex40(s: &str) -> bool {
    s.len() == 40 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

async fn add_torrent(
    State(state): State<AppState>,
    body: Result<Json<AddTorrentRequest>, JsonRejection>,
) -> ApiResult {
    let Json(req) = body.map_err(|e| ApiError::bad_request("bad_json", e.body_text()))?;

    let provided = [
        req.magnet.is_some(),
        req.info_hash.is_some(),
        req.torrent_base64.is_some(),
    ]
    .iter()
    .filter(|present| **present)
    .count();
    if provided == 0 {
        return Err(ApiError::bad_request(
            "missing_source",
            "one of magnet / infoHash / torrentBase64 is required",
        ));
    }
    if provided > 1 {
        return Err(ApiError::bad_request(
            "ambiguous_source",
            "provide exactly one of magnet / infoHash / torrentBase64",
        ));
    }
    if let Some(only) = req.only_files.as_ref() {
        if only.is_empty() {
            return Err(ApiError::bad_request(
                "empty_only_files",
                "onlyFiles must not be an empty array",
            ));
        }
    }

    // 用 owned 形式构造（`AddTorrent<'static>`）：add 要丢进独立 task，
    // 不能借用请求体。
    let add: AddTorrent<'static> = if let Some(magnet) = req.magnet.as_ref() {
        let magnet = magnet.trim();
        if !(magnet.starts_with("magnet:") || is_hex40(magnet)) {
            return Err(ApiError::bad_request(
                "bad_magnet",
                "magnet must start with \"magnet:\" or be a 40-char info hash",
            ));
        }
        AddTorrent::from_url(magnet.to_owned())
    } else if let Some(hash) = req.info_hash.as_ref() {
        let hash = hash.trim().to_ascii_lowercase();
        if !is_hex40(&hash) {
            return Err(ApiError::bad_request(
                "bad_info_hash",
                "infoHash must be exactly 40 hex characters",
            ));
        }
        AddTorrent::from_url(format!("magnet:?xt=urn:btih:{hash}"))
    } else {
        let encoded = req.torrent_base64.as_deref().unwrap_or_default().trim();
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map_err(|e| ApiError::bad_request("bad_torrent_base64", format!("{e}")))?;
        if bytes.is_empty() {
            return Err(ApiError::bad_request(
                "empty_torrent",
                "torrentBase64 decoded to zero bytes",
            ));
        }
        AddTorrent::from_bytes(bytes)
    };

    // 元数据阶段超时返回 504 时，把 infoHash 一并告诉客户端（方便它按 hash 重试/查询）。
    let info_hash_hint: Option<String> = match &add {
        AddTorrent::Url(url) => Magnet::parse(url)
            .ok()
            .and_then(|m| m.as_id20())
            .map(|h| h.as_string()),
        AddTorrent::TorrentFileBytes(_) => None,
    };

    let mut peers = state.initial_peers.clone();
    if let Some(extra) = req.initial_peers.as_ref() {
        for peer in extra {
            let addr: SocketAddr = peer
                .parse()
                .map_err(|e| ApiError::bad_request("bad_initial_peer", format!("{peer:?}: {e}")))?;
            peers.push(addr);
        }
    }

    let metadata_timeout = Duration::from_millis(
        req.metadata_timeout_ms
            .unwrap_or(DEFAULT_METADATA_TIMEOUT_MS),
    );

    let display_name = req
        .name
        .as_deref()
        .map(str::trim)
        .filter(|n| !n.is_empty())
        .map(str::to_owned);

    let opts = AddTorrentOptions {
        paused: req.start_paused.unwrap_or(false),
        only_files: req.only_files.clone(),
        // 契约 §3.5：必须开启，否则断点续传/做种会失败。
        overwrite: true,
        sub_folder: req.sub_folder.clone(),
        initial_peers: if peers.is_empty() { None } else { Some(peers) },
        ..Default::default()
    };

    // ⚠️ librqbit 9 的 `Session::add_torrent()` 对**磁力链会在内部等待元数据**
    // （`add_torrent_internal` → `resolve_magnet` → `read_metainfo_from_peer_receiver`），
    // 而且**没有任何超时**；元数据没到之前 torrent 也不会被注册进 session。
    // 所以契约 §3.5 的「超时 504 但保留 torrent 继续找元数据」必须在外面实现：
    // add 放进独立 task，HTTP 侧用一条总 deadline 控制响应；超时后 task 继续跑，
    // 一旦成功注册就补发 `torrent_added`（客户端通过 SSE 或重试都能拿到）。
    //
    // 同时用 in-flight 表按下 info hash 去重：解析进行中重复 POST 同一个 hash 时，
    // 后来者**复用同一个后台任务**（不再新开 BT 握手），拿到结果后返回和首个请求
    // 完全一样的 200/504 形状（不引入新的 202：语义上它就是在等同一个结果）。
    let deadline = tokio::time::Instant::now() + metadata_timeout;
    let (origin, is_leader) = match info_hash_hint.as_deref() {
        Some(key) => {
            let (leader, rx) = state.begin_resolve(key);
            if leader {
                (AddOrigin::Leader, true)
            } else {
                tracing::debug!(info_hash = key, "joining an in-flight magnet resolution");
                (AddOrigin::Join(rx), false)
            }
        }
        // .torrent 字节：元数据本来就有，不需要去重
        None => (AddOrigin::Leader, true),
    };

    let (id, handle) = match origin {
        AddOrigin::Leader => {
            let session = state.session.clone();
            let task_state = state.clone();
            let task_key = info_hash_hint.clone();
            let (tx, mut rx) = tokio::sync::oneshot::channel();
            tokio::spawn(async move {
                let result = session.add_torrent(add, Some(opts)).await;
                if let Some(key) = task_key.as_deref() {
                    let outcome = match &result {
                        Ok(AddTorrentResponse::Added(id, _))
                        | Ok(AddTorrentResponse::AlreadyManaged(id, _)) => {
                            ResolveOutcome::Added(*id)
                        }
                        Ok(AddTorrentResponse::ListOnly(_)) => {
                            ResolveOutcome::Failed("session returned list-only".to_owned())
                        }
                        Err(e) => ResolveOutcome::Failed(format!("{e:#}")),
                    };
                    task_state.finish_resolve(key, outcome);
                }
                let _ = tx.send(result);
            });

            let attempt = tokio::time::timeout_at(deadline, &mut rx).await;
            match attempt {
                Ok(Ok(Ok(response))) => match response {
                    AddTorrentResponse::Added(id, handle)
                    | AddTorrentResponse::AlreadyManaged(id, handle) => (id, handle),
                    AddTorrentResponse::ListOnly(_) => {
                        return Err(ApiError::internal(
                            "unexpected_list_only",
                            "session returned list-only although list_only was not requested",
                        ))
                    }
                },
                Ok(Ok(Err(e))) => {
                    return Err(ApiError::bad_request("add_failed", format!("{e:#}")))
                }
                Ok(Err(_recv)) => {
                    return Err(ApiError::internal(
                        "add_task_failed",
                        "the torrent-add task disappeared before reporting a result",
                    ))
                }
                Err(_elapsed) => {
                    let state_late = state.clone();
                    let name_late = display_name.clone();
                    let hint_late = info_hash_hint.clone();
                    tokio::spawn(async move {
                        match rx.await {
                            Ok(Ok(response)) => {
                                let id = match &response {
                                    AddTorrentResponse::Added(id, _)
                                    | AddTorrentResponse::AlreadyManaged(id, _) => Some(*id),
                                    AddTorrentResponse::ListOnly(_) => None,
                                };
                                if let Some(id) = id {
                                    if let Some(name) = name_late {
                                        state_late.set_display_name(id, name);
                                    }
                                    tracing::info!(
                                        id,
                                        info_hash = ?hint_late,
                                        "metadata resolved after the HTTP timeout; torrent is now managed"
                                    );
                                    state_late.emit_torrent_added(TorrentIdOrHash::Id(id));
                                }
                            }
                            Ok(Err(e)) => tracing::warn!(
                                info_hash = ?hint_late,
                                "background magnet resolution failed: {e:#}"
                            ),
                            Err(_) => tracing::debug!("background add task dropped its result"),
                        }
                    });
                    return Err(ApiError::raw(
                        StatusCode::GATEWAY_TIMEOUT,
                        json!({
                            "error": "metadata_timeout",
                            "phase": "metadata",
                            "infoHash": info_hash_hint,
                            "metadataTimeoutMs": metadata_timeout.as_millis() as u64,
                            "message": "metadata was not ready in time; the torrent keeps searching in the background and will show up via GET /torrents or the torrent_added SSE event",
                        }),
                    ));
                }
            }
        }
        // broadcast::Receiver 本身不是 Future，要用 recv()（oneshot 那种直接 await 不适用）
        AddOrigin::Join(mut rx) => match tokio::time::timeout_at(deadline, rx.recv()).await {
            Ok(Ok(ResolveOutcome::Added(id))) => {
                let handle = state.session.get(TorrentIdOrHash::Id(id)).ok_or_else(|| {
                    ApiError::internal(
                        "add_task_failed",
                        "torrent disappeared right after magnet resolution",
                    )
                })?;
                (id, handle)
            }
            Ok(Ok(ResolveOutcome::Failed(message))) => {
                return Err(ApiError::bad_request("add_failed", message))
            }
            Ok(Err(_recv)) => {
                return Err(ApiError::internal(
                    "add_task_failed",
                    "the shared magnet resolution ended without a result",
                ))
            }
            Err(_elapsed) => {
                return Err(ApiError::raw(
                    StatusCode::GATEWAY_TIMEOUT,
                    json!({
                        "error": "metadata_timeout",
                        "phase": "metadata",
                        "infoHash": info_hash_hint,
                        "metadataTimeoutMs": metadata_timeout.as_millis() as u64,
                        "message": "another request is already resolving this info hash; that task keeps running in the background",
                    }),
                ))
            }
        },
    };

    // 展示名只由 leader 应用：同行者复用的是 leader 的 add 参数（与 librqbit
    // AlreadyManaged 的语义一致——重复提交不改变已有 torrent 的选项）。
    if is_leader {
        if let Some(name) = display_name {
            state.set_display_name(id, name);
        }
    }

    // 契约 §3.5：等元数据/初始检查就绪再返回，否则前端拿不到文件列表。
    // 这里复用同一条 deadline（整个「拿到文件列表」的总预算），超时同样 504。
    let info_hash = handle.info_hash().as_string();
    match tokio::time::timeout_at(deadline, handle.wait_until_initialized()).await {
        Ok(Ok(())) => {}
        Ok(Err(e)) => {
            return Err(ApiError::raw(
                StatusCode::INTERNAL_SERVER_ERROR,
                json!({
                    "error": "torrent_error",
                    "message": format!("{e:#}"),
                    "id": id,
                    "infoHash": info_hash,
                }),
            ))
        }
        Err(_) => {
            return Err(ApiError::raw(
                StatusCode::GATEWAY_TIMEOUT,
                json!({
                    "error": "metadata_timeout",
                    "phase": "initializing",
                    "id": id,
                    "infoHash": info_hash,
                    "metadataTimeoutMs": metadata_timeout.as_millis() as u64,
                }),
            ))
        }
    }

    // `torrent_added` 只由 leader 发：同行者拿到的是同一个 torrent，重复发会让
    // 客户端看到两次 added 事件。
    if is_leader {
        state.emit_torrent_added(TorrentIdOrHash::Id(id));
    }
    Ok(Json(state.snapshot_one(&handle).view(&state.api)).into_response())
}

// ---------------------------------------------------------------- PATCH /limits

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LimitsPatch {
    /// 字节/秒；`0` = 不限；缺省 = 不改
    pub download_bps: Option<u64>,
    /// 字节/秒；`0` = 不限；缺省 = 不改
    pub upload_bps: Option<u64>,
}

fn to_limit(value: u64, name: &str) -> Result<Option<NonZeroU32>, ApiError> {
    if value == 0 {
        return Ok(None);
    }
    let v = u32::try_from(value).map_err(|_| {
        ApiError::bad_request(
            "bad_limit",
            format!("{name}={value} exceeds u32::MAX (librqbit stores bps as u32)"),
        )
    })?;
    Ok(NonZeroU32::new(v))
}

/// `PATCH /limits`：热改上传/下载限速（librqbit `Session::ratelimits` 是运行时可改的）。
/// body `{"downloadBps":102400,"uploadBps":0}`（字节/秒，0 = 不限，缺省 = 不改），
/// 返回**生效后**的值，客户端可以据此回显（`0` 表示不限）。
async fn patch_limits(
    State(state): State<AppState>,
    body: Result<Json<LimitsPatch>, JsonRejection>,
) -> ApiResult {
    let Json(patch) = body.map_err(|e| ApiError::bad_request("bad_json", e.body_text()))?;
    if patch.download_bps.is_none() && patch.upload_bps.is_none() {
        return Err(ApiError::bad_request(
            "empty_patch",
            "provide at least one of downloadBps / uploadBps",
        ));
    }
    if let Some(v) = patch.upload_bps {
        state
            .session
            .ratelimits
            .set_upload_bps(to_limit(v, "uploadBps")?);
    }
    if let Some(v) = patch.download_bps {
        state
            .session
            .ratelimits
            .set_download_bps(to_limit(v, "downloadBps")?);
    }
    let effective = state.session.ratelimits.get_config();
    Ok(Json(json!({
        "downloadBps": effective.download_bps.map(|v| v.get()).unwrap_or(0),
        "uploadBps": effective.upload_bps.map(|v| v.get()).unwrap_or(0),
    }))
    .into_response())
}

// ---------------------------------------------------------------- pause / resume / delete

fn ok_state(id: usize, state: &str) -> Response {
    Json(json!({ "ok": true, "id": id, "state": state })).into_response()
}

async fn pause_torrent(State(state): State<AppState>, Path(id): Path<String>) -> ApiResult {
    let idx = parse_torrent_id(&id)?;
    let handle = state.session.get(idx).ok_or_else(|| {
        ApiError::not_found("no_such_torrent", format!("no torrent with id {id}"))
    })?;
    let tid = handle.id();
    match state.session.pause(&handle).await {
        Ok(()) => Ok(ok_state(tid, "paused")),
        Err(e) => {
            // 已经暂停 → 幂等成功。
            if matches!(handle.stats().state, TorrentStatsState::Paused) {
                Ok(ok_state(tid, "paused"))
            } else {
                Err(ApiError::internal("pause_failed", format!("{e:#}")))
            }
        }
    }
}

async fn resume_torrent(State(state): State<AppState>, Path(id): Path<String>) -> ApiResult {
    let idx = parse_torrent_id(&id)?;
    let handle = state.session.get(idx).ok_or_else(|| {
        ApiError::not_found("no_such_torrent", format!("no torrent with id {id}"))
    })?;
    let tid = handle.id();
    match state.session.unpause(&handle).await {
        Ok(()) => Ok(ok_state(tid, "live")),
        Err(e) => {
            // 已经在跑 → 幂等成功。
            if matches!(handle.stats().state, TorrentStatsState::Live) {
                Ok(ok_state(tid, "live"))
            } else {
                Err(ApiError::internal("resume_failed", format!("{e:#}")))
            }
        }
    }
}

async fn delete_torrent(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
) -> ApiResult {
    let idx = parse_torrent_id(&id)?;
    // 契约 §3.4：deleteFiles 默认 false。
    let delete_files = match params.get("deleteFiles") {
        None => false,
        Some(v) if v.eq_ignore_ascii_case("true") => true,
        Some(v) if v.eq_ignore_ascii_case("false") => false,
        Some(v) => {
            return Err(ApiError::bad_request(
                "bad_delete_files",
                format!("deleteFiles must be true or false, got {v:?}"),
            ))
        }
    };

    let tid = state
        .session
        .get(idx)
        .ok_or_else(|| ApiError::not_found("no_such_torrent", format!("no torrent with id {id}")))?
        .id();

    // librqbit 9.0.1 的 `Session::delete()` 在 metadata 尚未解析（磁力还在找元数据）时会
    // `expect("TODO")` panic。放到独立 task 里执行：panic 不会打断请求，也不会带走进程；
    // 该 panic 发生在从 session db 移除之后，因此用实测结果如实回报。
    let session = state.session.clone();
    let joined =
        tokio::spawn(async move { session.delete(TorrentIdOrHash::Id(tid), delete_files).await })
            .await;

    match joined {
        Ok(Ok(())) => Ok(Json(json!({
            "ok": true,
            "id": tid,
            "deleted": true,
            "filesDeleted": delete_files,
        }))
        .into_response()),
        Ok(Err(e)) => Err(ApiError::internal("delete_failed", format!("{e:#}"))),
        Err(join_err) => {
            let still_managed = state.session.get(TorrentIdOrHash::Id(tid)).is_some();
            if still_managed {
                tracing::error!(id = tid, "delete task failed: {join_err}");
                Err(ApiError::internal(
                    "delete_failed",
                    format!("torrent {tid} is still managed: {join_err}"),
                ))
            } else {
                tracing::warn!(
                    id = tid,
                    "torrent removed, but librqbit panicked while deleting (metadata was not resolved yet); no files were written, so nothing was deleted from disk"
                );
                Ok(Json(json!({
                    "ok": true,
                    "id": tid,
                    "deleted": true,
                    "filesDeleted": false,
                    "note": "torrent had no metadata yet; nothing had been written to disk",
                }))
                .into_response())
            }
        }
    }
}

// ---------------------------------------------------------------- 边下边播

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RangeSpec {
    /// 无 Range 头 → 200 全长。
    Full,
    /// 单段 Range → 206。
    Satisfiable { start: u64, end: u64 },
    /// 语法/范围非法 → 416。
    Unsatisfiable,
    /// 多段 Range：契约只要求单段，这里显式 501，不做假成功。
    MultiRange,
}

/// 解析 `Range` 头（契约 §3.8：`bytes=start-end` / `bytes=start-`）。
pub fn parse_range(header: Option<&str>, len: u64) -> RangeSpec {
    let raw = match header {
        None => return RangeSpec::Full,
        Some(v) => v.trim(),
    };
    let specs = match raw.split_once('=') {
        Some((unit, rest)) if unit.trim().eq_ignore_ascii_case("bytes") => rest.trim(),
        _ => return RangeSpec::Unsatisfiable,
    };
    if specs.contains(',') {
        return RangeSpec::MultiRange;
    }
    let (start_raw, end_raw) = match specs.split_once('-') {
        Some(v) => v,
        None => return RangeSpec::Unsatisfiable,
    };
    let (start_raw, end_raw) = (start_raw.trim(), end_raw.trim());

    if start_raw.is_empty() {
        // 后缀形式 `bytes=-N`：最后 N 字节。
        let n: u64 = match end_raw.parse() {
            Ok(v) => v,
            Err(_) => return RangeSpec::Unsatisfiable,
        };
        if n == 0 || len == 0 {
            return RangeSpec::Unsatisfiable;
        }
        return RangeSpec::Satisfiable {
            start: len.saturating_sub(n),
            end: len - 1,
        };
    }

    let start: u64 = match start_raw.parse() {
        Ok(v) => v,
        Err(_) => return RangeSpec::Unsatisfiable,
    };
    let end = if end_raw.is_empty() {
        if len == 0 {
            return RangeSpec::Unsatisfiable;
        }
        len - 1
    } else {
        match end_raw.parse::<u64>() {
            Ok(v) => v,
            Err(_) => return RangeSpec::Unsatisfiable,
        }
    };

    if start >= len || end < start {
        return RangeSpec::Unsatisfiable;
    }
    RangeSpec::Satisfiable {
        start,
        end: end.min(len - 1),
    }
}

/// 把 `FileStream` 的 `Err` 变成「等一会再试」，而不是让响应体中道崩掉。
///
/// 为什么必须有这一层（实测 bug，2026-10-09）：`tokio_util::io::ReaderStream` 遇到
/// 内层 `poll_read` 返回 `Err` 时会**结束整个 body**；hyper 随即拆掉连接，客户端看到
/// 的是 `curl: (56) Recv failure: Connection was reset` —— 尽管头已经正确发出
/// （`206` + `Content-Range`）。
///
/// 而 `FileStream::poll_read` 在「需要的那片还没下到」时会走
/// `poll_try_io!(... with_storage_and_file ...)` 的错误分支：例如 torrent 仍处于
/// `Initializing`（刚加完磁力、正在校验）时 `with_storage_and_file` 直接
/// `bail!("invalid state")`。于是**请求刚开始就崩**，而它本该挂起等数据 —— 也就是
/// 契约 §3.8 最核心的「读不到片就挂起」语义。单测没抓到它，是因为测试里的做种端在
/// 本机、分片几乎立刻到位，错误窗口被盖住了。
///
/// 策略：可恢复错误 → 退避重试，客户端那边表现为「请求挂起」；连续失败超过阈值才
/// 真正把错误抛出去（那是存储层真坏了，如磁盘不可写），并留一条 warn 日志。
struct RetryingReader<R> {
    inner: R,
    delay: Pin<Box<tokio::time::Sleep>>,
    attempt: u32,
    armed: bool,
}

/// 连续失败上限：超过则认定存储层真的坏了，不再无限重试。
///
/// 3000 × 200ms ≈ 10 分钟「一个字节都没读到」才放弃。取这么大是因为：
/// torrent 在 `Initializing`（大文件初始校验）期间 `with_storage_and_file` 会一直
/// 返回 Err，而契约 §3.8 明确「长期挂起是正常的」——客户端（mpv）愿意等，
/// 我们不能在校验还没结束时就把 body 掐了。
const STREAM_MAX_RETRIES: u32 = 3000;
/// 重试退避上限（首几次失败用这个间隔；failures 多了也不线性拉长，
/// 免得烂种场景下客户端等太久才拿到第一批字节）。
const STREAM_RETRY_BACKOFF: Duration = Duration::from_millis(200);

impl<R> RetryingReader<R> {
    fn new(inner: R) -> Self {
        Self {
            inner,
            delay: Box::pin(tokio::time::sleep(Duration::ZERO)),
            attempt: 0,
            armed: false,
        }
    }
}

impl<R: AsyncRead + Unpin> AsyncRead for RetryingReader<R> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        loop {
            if self.armed {
                // 退避计时中：到点后唤醒并重试；期间不碰内层 reader。
                match self.delay.as_mut().poll(cx) {
                    Poll::Ready(()) => {
                        self.armed = false;
                        continue;
                    }
                    Poll::Pending => return Poll::Pending,
                }
            }

            // 出错时不写 buf：librqbit 的读路径是 pread_exact（要么成功要么不写），
            // 这里无需回滚已填充长度。
            match Pin::new(&mut self.inner).poll_read(cx, buf) {
                Poll::Ready(Ok(())) => {
                    self.attempt = 0;
                    return Poll::Ready(Ok(()));
                }
                Poll::Pending => return Poll::Pending,
                Poll::Ready(Err(e)) => {
                    self.attempt += 1;
                    if self.attempt >= STREAM_MAX_RETRIES {
                        tracing::warn!(
                            attempt = self.attempt,
                            error = %e,
                            "stream read failed repeatedly; giving up"
                        );
                        return Poll::Ready(Err(e));
                    }
                    if self.attempt == 1 {
                        tracing::debug!(error = %e, "stream read failed; waiting for the piece");
                    }
                    self.delay
                        .as_mut()
                        .reset(tokio::time::Instant::now() + STREAM_RETRY_BACKOFF);
                    self.armed = true;
                }
            }
        }
    }
}

fn retrying_read<R: AsyncRead + Send + Unpin + 'static>(reader: R) -> RetryingReader<R> {
    RetryingReader::new(reader)
}

fn boxed_read<R: AsyncRead + Send + Unpin + 'static>(
    reader: R,
) -> Box<dyn AsyncRead + Send + Unpin> {
    Box::new(reader)
}

fn build_response(
    status: StatusCode,
    headers: Vec<(&'static str, String)>,
    body: Body,
) -> ApiResult {
    let mut builder = Response::builder().status(status);
    for (name, value) in headers {
        builder = builder.header(name, value);
    }
    builder
        .body(body)
        .map_err(|e| ApiError::internal("response_build_failed", e.to_string()))
}

async fn stream_file(
    State(state): State<AppState>,
    Path((id, idx)): Path<(String, String)>,
    headers: HeaderMap,
) -> ApiResult {
    let torrent_id = parse_torrent_id(&id)?;
    let file_index: usize = idx.parse().map_err(|_| {
        ApiError::bad_request("bad_file_index", format!("{idx:?} is not a file index"))
    })?;

    let handle = state
        .api
        .mgr_handle(torrent_id)
        .map_err(|_| ApiError::not_found("no_such_torrent", format!("no torrent with id {id}")))?;

    // `onlyFiles` 之外的文件永远不会被下载：直接 404，避免请求无限挂起。
    if let Some(only) = handle.only_files() {
        if !only.contains(&file_index) {
            return Err(ApiError::not_found(
                "no_such_file",
                format!("file {file_index} is not part of this torrent's onlyFiles selection"),
            ));
        }
    }

    // metadata 未就绪 / 文件不存在 → 404 no_such_file（契约 §3.8）。
    let mut stream = handle.clone().stream(file_index).await.map_err(|e| {
        ApiError::not_found(
            "no_such_file",
            format!("file {file_index} of torrent {id} is not streamable yet: {e:#}"),
        )
    })?;

    let len = stream.len();
    let mime = state
        .api
        .torrent_file_mime_type(torrent_id, file_index)
        .unwrap_or("application/octet-stream");

    let range_header = headers.get(header::RANGE).and_then(|v| v.to_str().ok());
    let spec = parse_range(range_header, len);
    tracing::debug!(%id, file_index, len, range = ?range_header, "stream request");

    match spec {
        RangeSpec::Full => {
            // RetryingReader：把「片还没到」的 Err 变成挂起重试，避免响应体中道崩掉。
            let body = Body::from_stream(ReaderStream::with_capacity(
                boxed_read(retrying_read(stream)),
                STREAM_CHUNK,
            ));
            build_response(
                StatusCode::OK,
                vec![
                    ("Content-Type", mime.to_owned()),
                    ("Accept-Ranges", "bytes".to_owned()),
                    ("Content-Length", len.to_string()),
                ],
                body,
            )
        }
        RangeSpec::Satisfiable { start, end } => {
            // 读不到片时 FileStream 的 poll 返回 Pending：请求会挂起直到该片下载完成，
            // 这正是 mpv 需要的背压行为（契约 §3.8），因此这里**不设任何超时**。
            stream
                .seek(SeekFrom::Start(start))
                .await
                .map_err(|e| ApiError::internal("seek_failed", e.to_string()))?;
            let to_take = end - start + 1;
            let body = Body::from_stream(ReaderStream::with_capacity(
                boxed_read(retrying_read(stream.take(to_take))),
                STREAM_CHUNK,
            ));
            build_response(
                StatusCode::PARTIAL_CONTENT,
                vec![
                    ("Content-Type", mime.to_owned()),
                    ("Accept-Ranges", "bytes".to_owned()),
                    ("Content-Length", to_take.to_string()),
                    ("Content-Range", format!("bytes {start}-{end}/{len}")),
                ],
                body,
            )
        }
        RangeSpec::Unsatisfiable => build_response(
            StatusCode::RANGE_NOT_SATISFIABLE,
            vec![
                ("Content-Type", "application/json".to_owned()),
                ("Accept-Ranges", "bytes".to_owned()),
                ("Content-Range", format!("bytes */{len}")),
            ],
            Body::from(json!({ "error": "range_not_satisfiable", "length": len }).to_string()),
        ),
        RangeSpec::MultiRange => build_response(
            StatusCode::NOT_IMPLEMENTED,
            vec![("Content-Type", "application/json".to_owned())],
            Body::from(
                json!({
                    "error": "multi_range_not_supported",
                    "message": "only a single byte range is supported",
                    "length": len,
                })
                .to_string(),
            ),
        ),
    }
}

// ---------------------------------------------------------------- SSE

async fn events(
    State(state): State<AppState>,
) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    // 契约 §3.9：连接后立即发一次全量 snapshot。
    let snapshot = json!({ "torrents": state.list_views() }).to_string();
    let initial = futures::stream::once(async move {
        Ok::<_, Infallible>(Event::default().event("snapshot").data(snapshot))
    });
    let receiver = state.subscribe();
    let rest = BroadcastStream::new(receiver).filter_map(|msg| async move {
        match msg {
            Ok(ev) => Some(Ok::<_, Infallible>(
                Event::default().event(ev.name).data(ev.data.clone()),
            )),
            // 客户端落后导致丢事件：跳过即可，snapshot/progress 都是幂等的。
            Err(_) => None,
        }
    });
    Sse::new(initial.chain(rest))
}

// ---------------------------------------------------------------- 测试

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn range_full_when_absent() {
        assert_eq!(parse_range(None, 100), RangeSpec::Full);
    }

    #[test]
    fn range_single_segment() {
        assert_eq!(
            parse_range(Some("bytes=1024-2047"), 4096),
            RangeSpec::Satisfiable {
                start: 1024,
                end: 2047
            }
        );
        assert_eq!(
            parse_range(Some("bytes=1024-"), 4096),
            RangeSpec::Satisfiable {
                start: 1024,
                end: 4095
            }
        );
        // 超出文件尾 → 截断到 EOF
        assert_eq!(
            parse_range(Some("bytes=4090-99999"), 4096),
            RangeSpec::Satisfiable {
                start: 4090,
                end: 4095
            }
        );
        assert_eq!(
            parse_range(Some("Bytes=0-0"), 10),
            RangeSpec::Satisfiable { start: 0, end: 0 }
        );
    }

    #[test]
    fn range_suffix() {
        assert_eq!(
            parse_range(Some("bytes=-100"), 1000),
            RangeSpec::Satisfiable {
                start: 900,
                end: 999
            }
        );
        // 后缀比文件还长 → 整个文件
        assert_eq!(
            parse_range(Some("bytes=-5000"), 1000),
            RangeSpec::Satisfiable { start: 0, end: 999 }
        );
    }

    #[test]
    fn range_invalid_is_unsatisfiable() {
        // 契约 §3.8 的用例：越界 → 416
        assert_eq!(
            parse_range(Some("bytes=999999999-"), 2_097_152),
            RangeSpec::Unsatisfiable
        );
        assert_eq!(
            parse_range(Some("bytes=abc-def"), 100),
            RangeSpec::Unsatisfiable
        );
        assert_eq!(
            parse_range(Some("bytes=50-10"), 100),
            RangeSpec::Unsatisfiable
        );
        assert_eq!(parse_range(Some("bytes=-0"), 100), RangeSpec::Unsatisfiable);
        assert_eq!(
            parse_range(Some("items=0-10"), 100),
            RangeSpec::Unsatisfiable
        );
        assert_eq!(parse_range(Some("bytes=0-"), 0), RangeSpec::Unsatisfiable);
        assert_eq!(
            parse_range(Some("bytes=garbage"), 100),
            RangeSpec::Unsatisfiable
        );
    }

    #[test]
    fn range_multi_is_explicitly_unsupported() {
        assert_eq!(
            parse_range(Some("bytes=0-99,200-299"), 1000),
            RangeSpec::MultiRange
        );
    }

    #[test]
    fn token_extraction_from_query() {
        assert_eq!(query_token(Some("token=abc")), Some("abc"));
        assert_eq!(query_token(Some("foo=1&token=abc&bar=2")), Some("abc"));
        assert_eq!(query_token(Some("token=")), Some(""));
        assert_eq!(query_token(Some("foo=1")), None);
        assert_eq!(query_token(None), None);
    }

    #[test]
    fn secure_eq_checks_lengths_and_bytes() {
        assert!(secure_eq("abc", "abc"));
        assert!(!secure_eq("abc", "abd"));
        assert!(!secure_eq("abc", "ab"));
        assert!(!secure_eq("", "a"));
    }

    #[test]
    fn info_hash_validation() {
        assert!(is_hex40(&"a".repeat(40)));
        assert!(is_hex40("0123456789abcdef0123456789ABCDEF01234567"));
        assert!(!is_hex40(&"a".repeat(39)));
        assert!(!is_hex40(&"z".repeat(40)));
    }

    #[test]
    fn torrent_id_accepts_int_and_hash() {
        assert!(parse_torrent_id("3").is_ok());
        assert!(parse_torrent_id(&"a".repeat(40)).is_ok());
        assert!(parse_torrent_id("not-an-id").is_err());
    }
}
