//! 引擎共享状态：TorrentView 构建、SSE 事件广播、进度轮询任务。
//!
//! 对应设计契约 §3.6（TorrentView / stats）与 §3.9（SSE 事件流）。
//!
//! 设计要点：
//! * `TorrentView` 是**唯一**的 torrent 表示，`/torrents`、`/torrents/{id}`、
//!   `/torrents/{id}/stats`、`POST /torrents` 全部返回它（`/stats` 与 `/torrents/{id}` 同形）。
//! * `progress` 事件单独用更小的 payload（契约 §3.9 定义），字段名逐字对齐。
//! * 进度轮询每 500ms 一次（契约：频控 ≥500ms/torrent），并且：
//!   - 只要 `completedFiles` 变化就一定推送；
//!   - `completedFiles` 非空时，即使字节数没变也至少每 1s 重推一次
//!     （契约「只要该数组非空就必须推送 progress」的字面要求）；
//!   - 状态变化发 `state`，torrent 消失发 `torrent_removed`（轮询为准，避免重复事件）。

use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use librqbit::api::TorrentIdOrHash;
use librqbit::{Api, ManagedTorrent, Session, TorrentStatsState};
use serde::Serialize;
use serde_json::json;
use tokio::sync::{broadcast, Notify};

/// 进度轮询周期（≥500ms/torrent 的频控由它保证）。
pub const PROGRESS_TICK: Duration = Duration::from_millis(500);
/// `heartbeat` 事件间隔（契约 §3.9：每 15s）。
pub const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(15);
/// `completedFiles` 非空时的最小重推间隔。
pub const COMPLETED_REPUSH_INTERVAL: Duration = Duration::from_secs(1);
/// 广播通道容量：客户端落后时丢事件而不是阻塞引擎。
const EVENT_CHANNEL_CAPACITY: usize = 256;

/// 契约 §3.6 定义的可播放视频扩展名。
pub const VIDEO_EXTENSIONS: &[&str] = &[
    "mkv", "mp4", "webm", "avi", "mov", "ts", "m2ts", "flv", "wmv",
];

/// 一条待广播的 SSE 事件（`data` 已序列化为单行 JSON）。
#[derive(Debug, Clone)]
pub struct SseEvent {
    pub name: &'static str,
    pub data: String,
}

/// 后台磁力解析的最终结果（给 in-flight 表里的「同行者」用）。
#[derive(Debug, Clone)]
pub enum ResolveOutcome {
    /// 已经注册进 session，带上引擎分配的 id（同行者自己再 `session.get(id)` 拿 handle）。
    Added(usize),
    /// 解析失败（没有可用 peer / peer 流耗尽 / add 报错）。
    Failed(String),
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TorrentFileView {
    pub index: usize,
    pub path: String,
    pub length: u64,
    pub downloaded: u64,
    pub progress: f64,
    pub included: bool,
    pub mime: String,
    pub is_video: bool,
    pub complete: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TorrentView {
    pub id: usize,
    pub info_hash: String,
    pub name: String,
    pub state: &'static str,
    pub error: Option<String>,
    pub total_bytes: u64,
    pub progress_bytes: u64,
    pub uploaded_bytes: u64,
    pub download_bps: u64,
    pub upload_bps: u64,
    pub peers: u64,
    pub progress: f64,
    pub finished: bool,
    pub output_folder: String,
    pub files: Vec<TorrentFileView>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileProgressView {
    pub index: usize,
    pub downloaded: u64,
    pub complete: bool,
    pub progress: f64,
}

/// `event: progress` 的 payload（契约 §3.9 逐字对齐）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProgressView {
    pub id: usize,
    pub progress_bytes: u64,
    pub total_bytes: u64,
    pub download_bps: u64,
    pub upload_bps: u64,
    pub peers: u64,
    pub finished: bool,
    pub files: Vec<FileProgressView>,
    pub completed_files: Vec<usize>,
}

/// 单个文件的内部快照。
#[derive(Debug, Clone)]
pub struct FileSnapshot {
    pub index: usize,
    pub path: String,
    pub length: u64,
    pub downloaded: u64,
    pub included: bool,
}

impl FileSnapshot {
    pub fn complete(&self) -> bool {
        self.downloaded >= self.length
    }

    pub fn progress(&self) -> f64 {
        if self.length == 0 {
            return if self.complete() { 1.0 } else { 0.0 };
        }
        (self.downloaded as f64 / self.length as f64).clamp(0.0, 1.0)
    }
}

/// torrent 的一次完整快照，`TorrentView` 与 `progress` 事件都由它派生。
#[derive(Debug, Clone)]
pub struct TorrentSnapshot {
    pub id: usize,
    pub info_hash: String,
    pub name: String,
    pub state: &'static str,
    pub error: Option<String>,
    pub total_bytes: u64,
    pub progress_bytes: u64,
    pub uploaded_bytes: u64,
    pub download_bps: u64,
    pub upload_bps: u64,
    pub peers: u64,
    pub finished: bool,
    pub output_folder: String,
    pub files: Vec<FileSnapshot>,
}

impl TorrentSnapshot {
    pub fn progress(&self) -> ProgressView {
        ProgressView {
            id: self.id,
            progress_bytes: self.progress_bytes,
            total_bytes: self.total_bytes,
            download_bps: self.download_bps,
            upload_bps: self.upload_bps,
            peers: self.peers,
            finished: self.finished,
            files: self
                .files
                .iter()
                .map(|f| FileProgressView {
                    index: f.index,
                    downloaded: f.downloaded,
                    complete: f.complete(),
                    progress: f.progress(),
                })
                .collect(),
            completed_files: self
                .files
                .iter()
                .filter(|f| f.complete())
                .map(|f| f.index)
                .collect(),
        }
    }

    /// 变成对外契约里的 `TorrentView`（`mime` 需要 `Api`，故放在这里）。
    pub fn view(&self, api: &Api) -> TorrentView {
        TorrentView {
            id: self.id,
            info_hash: self.info_hash.clone(),
            name: self.name.clone(),
            state: self.state,
            error: self.error.clone(),
            total_bytes: self.total_bytes,
            progress_bytes: self.progress_bytes,
            uploaded_bytes: self.uploaded_bytes,
            download_bps: self.download_bps,
            upload_bps: self.upload_bps,
            peers: self.peers,
            progress: ratio(self.progress_bytes, self.total_bytes),
            finished: self.finished,
            output_folder: self.output_folder.clone(),
            files: self
                .files
                .iter()
                .map(|f| {
                    let mime = api
                        .torrent_file_mime_type(TorrentIdOrHash::Id(self.id), f.index)
                        .unwrap_or("application/octet-stream")
                        .to_owned();
                    let is_video = is_video_media(&f.path, &mime);
                    TorrentFileView {
                        index: f.index,
                        path: f.path.clone(),
                        length: f.length,
                        downloaded: f.downloaded,
                        progress: f.progress(),
                        included: f.included,
                        mime,
                        is_video,
                        complete: f.complete(),
                    }
                })
                .collect(),
        }
    }
}

fn ratio(part: u64, total: u64) -> f64 {
    if total == 0 {
        0.0
    } else {
        (part as f64 / total as f64).clamp(0.0, 1.0)
    }
}

/// `isVideo`：扩展名或 mime 任一命中（契约 §3.6）。
pub fn is_video_media(path: &str, mime: &str) -> bool {
    if mime.to_ascii_lowercase().starts_with("video/") {
        return true;
    }
    match path.rsplit_once('.') {
        Some((_, ext)) => VIDEO_EXTENSIONS.contains(&ext.to_ascii_lowercase().as_str()),
        None => false,
    }
}

/// 引擎全局状态，axum `State`。
#[derive(Clone)]
pub struct AppState {
    pub session: Arc<Session>,
    pub api: Api,
    pub token: Arc<str>,
    pub version: &'static str,
    /// 做种比例；0 = 不做限制。
    pub seed_ratio: f64,
    /// 额外 initial peers（本地测试/调试用；HTTP 请求里的 `initialPeers` 会追加）。
    pub initial_peers: Vec<SocketAddr>,
    /// 优雅退出信号：`/shutdown`、stdin EOF、Ctrl-C 都会触发。
    pub shutdown: Arc<Notify>,
    events: broadcast::Sender<Arc<SseEvent>>,
    display_names: Arc<Mutex<HashMap<usize, String>>>,
    /// in-flight 磁力解析表：infoHash → 结果广播发送端。
    /// 同一 infoHash 在解析中被重复 POST 时，后来者**复用同一个后台任务**，
    /// 不再各开一个（用户狂点「播放」会同时开 N 个 BT 握手）。
    resolving: Arc<Mutex<HashMap<String, broadcast::Sender<ResolveOutcome>>>>,
}

impl AppState {
    pub fn new(session: Arc<Session>, token: impl Into<String>) -> Self {
        let (events, _rx) = broadcast::channel(EVENT_CHANNEL_CAPACITY);
        let token: String = token.into();
        Self {
            api: Api::new(session.clone(), None),
            session,
            token: Arc::<str>::from(token),
            version: env!("CARGO_PKG_VERSION"),
            seed_ratio: 0.0,
            initial_peers: Vec::new(),
            shutdown: Arc::new(Notify::new()),
            events,
            display_names: Arc::new(Mutex::new(HashMap::new())),
            resolving: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// 尝试成为某个 info hash 的「解析 leader」。
    ///
    /// 返回 `(is_leader, outcome_rx)`：
    /// * `true` → 调用方负责真正发起 `add_torrent`，结束后必须调用 [`Self::finish_resolve`]；
    /// * `false` → 已经有人在解析，调用方应改为等待 `outcome_rx`（不要另起任务）。
    pub fn begin_resolve(&self, info_hash: &str) -> (bool, broadcast::Receiver<ResolveOutcome>) {
        let mut map = self.resolving.lock().expect("resolving mutex poisoned");
        if let Some(tx) = map.get(info_hash) {
            return (false, tx.subscribe());
        }
        let (tx, rx) = broadcast::channel(1);
        map.insert(info_hash.to_owned(), tx);
        (true, rx)
    }

    /// 解析结束（成功或失败）：广播结果给所有同行者并清掉 in-flight 记录。
    pub fn finish_resolve(&self, info_hash: &str, outcome: ResolveOutcome) {
        let tx = self
            .resolving
            .lock()
            .expect("resolving mutex poisoned")
            .remove(info_hash);
        if let Some(tx) = tx {
            // 没有同行者时 send 会 Err（无接收端），这是正常情况。
            let _ = tx.send(outcome);
        }
    }

    /// 当前是否有该 info hash 的解析在跑（诊断/测试用）。
    pub fn is_resolving(&self, info_hash: &str) -> bool {
        self.resolving
            .lock()
            .expect("resolving mutex poisoned")
            .contains_key(info_hash)
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Arc<SseEvent>> {
        self.events.subscribe()
    }

    /// 广播一条事件；没有订阅者时静默丢弃（这是正常情况）。
    pub fn emit(&self, name: &'static str, data: serde_json::Value) {
        let ev = Arc::new(SseEvent {
            name,
            data: data.to_string(),
        });
        let _ = self.events.send(ev);
    }

    /// 覆盖展示名（`POST /torrents` 的 `name` 字段）。仅影响展示，不改变落盘目录。
    pub fn set_display_name(&self, id: usize, name: String) {
        self.display_names
            .lock()
            .expect("display_names mutex poisoned")
            .insert(id, name);
    }

    fn name_of(&self, handle: &Arc<ManagedTorrent>) -> String {
        let id = handle.id();
        if let Some(name) = self
            .display_names
            .lock()
            .expect("display_names mutex poisoned")
            .get(&id)
        {
            return name.clone();
        }
        handle
            .name()
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| handle.info_hash().as_string())
    }

    /// 采集一个 torrent 的快照。元数据尚未就绪时 `files` 为空、`totalBytes` 为 0。
    ///
    /// 参数类型是 `&Arc<ManagedTorrent>`：librqbit 的 `ManagedTorrentHandle` 只是这个别名，
    /// 但它没有被 re-export 到 crate 根，外部 crate 无法命名，所以这里直接用底层类型。
    pub fn snapshot_one(&self, handle: &Arc<ManagedTorrent>) -> TorrentSnapshot {
        let stats = handle.stats();
        let only_files = handle.only_files();
        let files = match handle.with_metadata(|m| {
            m.info
                .iter_file_details()
                .enumerate()
                .map(|(index, d)| (index, d.filename.to_string(), d.len))
                .collect::<Vec<(usize, String, u64)>>()
        }) {
            Ok(files) => files,
            Err(_) => Vec::new(),
        };
        let files = files
            .into_iter()
            .map(|(index, path, length)| FileSnapshot {
                index,
                path,
                length,
                downloaded: stats.file_progress.get(index).copied().unwrap_or(0),
                included: only_files
                    .as_ref()
                    .map(|only| only.contains(&index))
                    .unwrap_or(true),
            })
            .collect();

        let (download_bps, upload_bps, peers) = match stats.live.as_ref() {
            Some(live) => (
                live.download_speed.as_bytes(),
                live.upload_speed.as_bytes(),
                live.snapshot.peer_stats.live as u64,
            ),
            None => (0, 0, 0),
        };

        TorrentSnapshot {
            id: handle.id(),
            info_hash: handle.info_hash().as_string(),
            name: self.name_of(handle),
            state: state_str(&stats.state),
            error: stats.error.clone(),
            total_bytes: stats.total_bytes,
            progress_bytes: stats.progress_bytes,
            uploaded_bytes: stats.uploaded_bytes,
            download_bps,
            upload_bps,
            peers,
            finished: stats.finished,
            output_folder: handle.output_folder().to_string_lossy().into_owned(),
            files,
        }
    }

    /// 全部 torrent 快照，按 id 升序（顺序稳定，便于前端 diff）。
    pub fn snapshots(&self) -> Vec<TorrentSnapshot> {
        let mut out: Vec<TorrentSnapshot> = self
            .session
            .with_torrents(|torrents| torrents.map(|(_, h)| self.snapshot_one(h)).collect());
        out.sort_by_key(|s| s.id);
        out
    }

    pub fn list_views(&self) -> Vec<TorrentView> {
        self.snapshots().iter().map(|s| s.view(&self.api)).collect()
    }

    pub fn view_of(&self, idx: TorrentIdOrHash) -> Option<TorrentView> {
        let handle = self.session.get(idx)?;
        Some(self.snapshot_one(&handle).view(&self.api))
    }

    pub fn torrent_count(&self) -> usize {
        self.session.with_torrents(|torrents| torrents.count())
    }

    /// `event: torrent_added`（契约 §3.9）。
    pub fn emit_torrent_added(&self, idx: TorrentIdOrHash) {
        if let Some(view) = self.view_of(idx) {
            self.emit("torrent_added", json!({ "torrent": view }));
        }
    }

    pub fn output_folder_of(&self, idx: TorrentIdOrHash) -> Option<String> {
        self.session
            .get(idx)
            .map(|h| h.output_folder().to_string_lossy().into_owned())
    }
}

/// librqbit 状态 → 契约里的 `state` 字符串。
pub fn state_str(state: &TorrentStatsState) -> &'static str {
    match state {
        TorrentStatsState::Initializing { .. } => "initializing",
        TorrentStatsState::Live => "live",
        TorrentStatsState::Paused => "paused",
        TorrentStatsState::Error => "error",
    }
}

#[derive(Debug)]
struct SeenTorrent {
    state: &'static str,
    error: Option<String>,
    progress_bytes: u64,
    files_len: usize,
    completed_files: Vec<usize>,
    finished: bool,
    download_bps: u64,
    peers: u64,
    sent_at: Instant,
}

/// 后台进度任务：500ms 轮询 + 15s 心跳，事件源是 `session` 本身。
pub fn spawn_progress_task(state: AppState) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(PROGRESS_TICK);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        ticker.tick().await; // 第一个 tick 立即返回，先吃掉
        let mut seen: HashMap<usize, SeenTorrent> = HashMap::new();
        let mut heartbeat_at = Instant::now();
        let mut ratio_stopped: HashSet<usize> = HashSet::new();

        loop {
            ticker.tick().await;
            let snapshots = state.snapshots();
            let mut alive: HashSet<usize> = HashSet::with_capacity(snapshots.len());

            for snap in &snapshots {
                alive.insert(snap.id);
                let prev = seen.get(&snap.id);

                if prev
                    .map(|p| p.state != snap.state || p.error != snap.error)
                    .unwrap_or(true)
                {
                    state.emit(
                        "state",
                        json!({ "id": snap.id, "state": snap.state, "error": snap.error }),
                    );
                }

                let progress = snap.progress();
                let completed = progress.completed_files.clone();
                let changed = match prev {
                    None => true,
                    Some(p) => {
                        p.progress_bytes != progress.progress_bytes
                            || p.completed_files != completed
                            || p.files_len != progress.files.len()
                            || p.finished != progress.finished
                            || p.download_bps != progress.download_bps
                            || p.peers != progress.peers
                    }
                };
                // 契约：completedFiles 非空就必须持续推送（即便字节数没变）。
                let repush = !completed.is_empty()
                    && prev
                        .map(|p| p.sent_at.elapsed() >= COMPLETED_REPUSH_INTERVAL)
                        .unwrap_or(true);

                if changed || repush {
                    state.emit(
                        "progress",
                        serde_json::to_value(&progress).unwrap_or(serde_json::Value::Null),
                    );
                    seen.insert(
                        snap.id,
                        SeenTorrent {
                            state: snap.state,
                            error: snap.error.clone(),
                            progress_bytes: progress.progress_bytes,
                            files_len: progress.files.len(),
                            completed_files: completed,
                            finished: progress.finished,
                            download_bps: progress.download_bps,
                            peers: progress.peers,
                            sent_at: Instant::now(),
                        },
                    );
                } else if let Some(p) = seen.get_mut(&snap.id) {
                    p.state = snap.state;
                    p.error = snap.error.clone();
                }

                maybe_stop_seeding(&state, snap, &mut ratio_stopped);
            }

            let removed: Vec<usize> = seen
                .keys()
                .copied()
                .filter(|id| !alive.contains(id))
                .collect();
            for id in removed {
                state.emit("torrent_removed", json!({ "id": id }));
                seen.remove(&id);
                ratio_stopped.remove(&id);
            }

            if heartbeat_at.elapsed() >= HEARTBEAT_INTERVAL {
                state.emit("heartbeat", json!({}));
                heartbeat_at = Instant::now();
            }
        }
    })
}

/// `--seed-ratio > 0` 时，达到比例后暂停该 torrent（停止上传）。
/// 默认 0 表示不做任何做种比例干预。
fn maybe_stop_seeding(state: &AppState, snap: &TorrentSnapshot, stopped: &mut HashSet<usize>) {
    if state.seed_ratio <= 0.0 || !snap.finished || snap.total_bytes == 0 {
        return;
    }
    if stopped.contains(&snap.id) {
        return;
    }
    let ratio = snap.uploaded_bytes as f64 / snap.total_bytes as f64;
    if ratio < state.seed_ratio {
        return;
    }
    stopped.insert(snap.id);
    let session = state.session.clone();
    let id = snap.id;
    tokio::spawn(async move {
        if let Some(handle) = session.get(TorrentIdOrHash::Id(id)) {
            match session.pause(&handle).await {
                Ok(()) => tracing::info!(id, ratio, "seed ratio reached, torrent paused"),
                Err(e) => tracing::debug!(id, "seed ratio pause skipped: {e:#}"),
            }
        }
    });
}

/// stdin EOF 触发优雅退出的**宽限期**（见 [`stdin_eof_means_exit`]）。
pub const STDIN_EOF_GRACE: Duration = Duration::from_secs(10);

/// 判断「刚读到的这个 EOF 该不该当成父进程要求退出」。
///
/// * 宽限期内就 EOF → 说明启动器**根本没给 stdin**（`Start-Process` 带重定向、快捷方式、
///   Windows 服务、VS/`flutter run` 调试启动器……），服务器语义上不该退出 → 返回 `false`，
///   调用方必须**永久结束 watcher**（绝不能再 read 一次：那样会在恰好 `grace` 之后
///   拿到第二个 EOF，把引擎弄死）。
/// * 宽限期后 EOF → 真正的管道父进程（Dart 侧）关掉了 stdin → 返回 `true`，优雅退出。
pub async fn stdin_eof_means_exit<R>(mut reader: R, grace: Duration) -> bool
where
    R: tokio::io::AsyncRead + Unpin,
{
    use tokio::io::AsyncReadExt;
    let started = Instant::now();
    let mut buf = [0u8; 1024];
    loop {
        match reader.read(&mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(_) => continue,
        }
    }
    let elapsed = started.elapsed();
    if elapsed < grace {
        tracing::info!(
            elapsed_ms = elapsed.as_millis() as u64,
            "stdin 在启动宽限期内就 EOF（启动器没给 stdin），永久忽略 stdin 退出信号"
        );
        return false;
    }
    true
}

/// 父进程关掉 stdin 时触发优雅退出（契约 §4.1：`/shutdown` 或关 stdin）。
///
/// 判定逻辑与理由见 [`stdin_eof_means_exit`]。
pub fn spawn_stdin_watcher(notify: Arc<Notify>) {
    tokio::spawn(async move {
        if stdin_eof_means_exit(tokio::io::stdin(), STDIN_EOF_GRACE).await {
            tracing::info!("stdin closed, shutting down");
            notify.notify_one();
        } else {
            tracing::debug!("stdin watcher permanently disabled");
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 回归测试：「启动器没给 stdin」绝不能被当成退出请求。
    ///
    /// 空 reader 等价于立即 EOF（`Start-Process` 带重定向 / 快捷方式 / 服务都是这样）。
    /// 关键不变量：判定为「没有 stdin」之后**不能再读第二次**，否则会在恰好宽限期之后
    /// 拿到第二个 EOF 把引擎弄死 —— 这里断言直接返回 false。
    #[tokio::test]
    async fn stdin_eof_within_grace_is_ignored_permanently() {
        let empty = tokio::io::empty();
        assert!(
            !stdin_eof_means_exit(empty, Duration::from_millis(30)).await,
            "宽限期内的 EOF 必须返回 false（永久忽略），不能触发退出"
        );
    }

    /// 真正的管道父进程（Dart）在很久之后关掉 stdin → 必须触发优雅退出。
    #[tokio::test]
    async fn stdin_eof_after_grace_triggers_exit() {
        use tokio::io::AsyncWriteExt;

        let (mut tx, rx) = tokio::io::duplex(64);
        let grace = Duration::from_millis(80);
        let watcher = tokio::spawn(stdin_eof_means_exit(rx, grace));

        // 父进程先写点东西（证明管道一开始是活的），等到超过宽限期再关掉
        tx.write_all(b"ping").await.unwrap();
        tokio::time::sleep(Duration::from_millis(150)).await;
        drop(tx);

        assert!(
            watcher.await.unwrap(),
            "宽限期之后的 EOF 必须触发退出（契约 §4.1 的「关 stdin」路径）"
        );
    }

    #[test]
    fn video_detection_uses_extension_and_mime() {
        assert!(is_video_media("a/b.mkv", "application/octet-stream"));
        assert!(is_video_media("episode.MP4", ""));
        assert!(is_video_media("x.bin", "video/x-matroska"));
        assert!(is_video_media("show.m2ts", ""));
        assert!(!is_video_media("subs.ass", "text/x-ssa"));
        assert!(!is_video_media("noext", "application/octet-stream"));
    }

    #[test]
    fn completion_tolerates_zero_length_and_overrun() {
        let f = |downloaded: u64, length: u64| FileSnapshot {
            index: 0,
            path: "a.mkv".into(),
            length,
            downloaded,
            included: true,
        };
        assert!(f(10, 10).complete());
        assert!(f(11, 10).complete());
        assert!(f(0, 0).complete());
        assert!(!f(9, 10).complete());
        assert_eq!(f(5, 10).progress(), 0.5);
    }

    #[test]
    fn progress_view_flags_completed_files() {
        let snap = TorrentSnapshot {
            id: 7,
            info_hash: "0".repeat(40),
            name: "n".into(),
            state: "live",
            error: None,
            total_bytes: 20,
            progress_bytes: 10,
            uploaded_bytes: 0,
            download_bps: 0,
            upload_bps: 0,
            peers: 3,
            finished: false,
            output_folder: "F:\\dl".into(),
            files: vec![
                FileSnapshot {
                    index: 0,
                    path: "a.mkv".into(),
                    length: 10,
                    downloaded: 10,
                    included: true,
                },
                FileSnapshot {
                    index: 1,
                    path: "b.srt".into(),
                    length: 10,
                    downloaded: 0,
                    included: false,
                },
            ],
        };
        let p = snap.progress();
        assert_eq!(p.completed_files, vec![0]);
        assert_eq!(p.files.len(), 2);
        assert!(p.files[0].complete);
        assert!(!p.files[1].complete);
        let v: serde_json::Value = serde_json::to_value(&p).unwrap();
        assert_eq!(v["id"], 7);
        assert_eq!(v["completedFiles"][0], 0);
        assert_eq!(v["progressBytes"], 10);
        assert_eq!(v["totalBytes"], 20);
        assert_eq!(v["files"][0]["index"], 0);
        assert_eq!(v["files"][0]["downloaded"], 10);
        assert_eq!(v["files"][0]["complete"], true);
    }

    #[test]
    fn state_strings_match_contract() {
        assert_eq!(
            state_str(&TorrentStatsState::Initializing { paused: false }),
            "initializing"
        );
        assert_eq!(state_str(&TorrentStatsState::Live), "live");
        assert_eq!(state_str(&TorrentStatsState::Paused), "paused");
        assert_eq!(state_str(&TorrentStatsState::Error), "error");
    }
}
