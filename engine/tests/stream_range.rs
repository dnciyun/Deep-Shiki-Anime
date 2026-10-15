//! 契约 §3.10.1：本机自播自收（无公网）验证 `/torrents` 与 `/stream` 的 Range 行为。
//!
//! 拓扑：本地做种会话（127.0.0.1 回环端口，`listen_addr` 固定回环）→ 下载会话通过
//! `initial_peers` 直连；DHT / tracker / LSD 全部关闭。

mod common;

use std::net::Ipv4Addr;
use std::time::Duration;

use anyhow::{Context, Result};
use base64::Engine as _;
use common::{
    body_offset, local_session, pseudo_random_bytes, read_for, read_until, Request, TempDir,
    TestEngine,
};
use librqbit::{
    create_torrent, spawn_utils::BlockingSpawner, AddTorrent, AddTorrentOptions,
    CreateTorrentOptions,
};

const FILE_LEN: usize = 2 * 1024 * 1024;
/// 64 KiB 分片：让 FileStream 必须逐片等待下载，才能真正走到「缺片挂起」的路径。
const PIECE_LEN: u32 = 64 * 1024;
const FILE_NAME: &str = "ep01.mkv";

#[tokio::test(flavor = "multi_thread")]
async fn stream_range_end_to_end() -> Result<()> {
    match tokio::time::timeout(Duration::from_secs(240), scenario()).await {
        Ok(result) => result,
        Err(_) => anyhow::bail!("scenario timed out after 240s"),
    }
}

async fn scenario() -> Result<()> {
    // ---------------------------------------------------------------- 1. 源文件 + .torrent
    let seed_root = TempDir::new("seed")?;
    let seed_dir = seed_root.path();
    let content = pseudo_random_bytes(FILE_LEN, 0x1234_5678_9abc_def0);
    std::fs::write(seed_dir.join(FILE_NAME), &content).context("error writing source file")?;

    let torrent = create_torrent(
        &seed_dir.join(FILE_NAME),
        CreateTorrentOptions {
            name: None,
            trackers: Vec::new(),
            piece_length: Some(PIECE_LEN),
        },
        &BlockingSpawner::new(1),
    )
    .await
    .context("error creating torrent")?;
    let torrent_bytes = torrent.as_bytes().context("error serializing torrent")?;
    let info_hash = torrent.info_hash().as_string();

    // ---------------------------------------------------------------- 2. 做种会话
    let seed_session = local_session(seed_dir, Some((Ipv4Addr::LOCALHOST, 0).into())).await?;
    let seed_handle = seed_session
        .add_torrent(
            AddTorrent::from_bytes(torrent_bytes.clone()),
            Some(AddTorrentOptions {
                paused: false,
                overwrite: true,
                output_folder: Some(seed_dir.to_string_lossy().into_owned()),
                ..Default::default()
            }),
        )
        .await
        .context("error adding torrent to seeder")?
        .into_handle()
        .context("seeder did not return a handle")?;
    tokio::time::timeout(Duration::from_secs(90), seed_handle.wait_until_completed())
        .await
        .context("seeder did not finish checking its data")??;
    let peer = seed_session
        .listen_addr()
        .context("seeder session has no listen addr")?;
    assert!(
        peer.ip().is_loopback(),
        "seeder must listen on loopback only, got {peer}"
    );

    // ---------------------------------------------------------------- 3. 下载会话 + HTTP 引擎
    let dl_root = TempDir::new("dl")?;
    let leech_session = local_session(dl_root.path(), None).await?;
    let engine = TestEngine::start(leech_session, vec![peer]).await?;

    // ---------------------------------------------------------------- 4. POST /torrents
    let added = engine
        .post_json(
            "/torrents",
            &serde_json::json!({
                "torrentBase64": base64::engine::general_purpose::STANDARD.encode(&torrent_bytes),
                "metadataTimeoutMs": 60_000u64,
            }),
        )
        .timeout(Duration::from_secs(120))
        .send(engine.addr)
        .await
        .context("POST /torrents failed")?;
    assert_eq!(added.status, 200, "body: {}", added.body_str());
    let body = added.json();
    assert_eq!(body["infoHash"].as_str(), Some(info_hash.as_str()));
    let id = body["id"].as_u64().context("response has no id")?;
    let files = body["files"].as_array().context("response has no files")?;
    assert_eq!(files.len(), 1, "expected exactly one file: {body}");
    assert_eq!(files[0]["index"], 0);
    assert_eq!(files[0]["path"], FILE_NAME);
    assert_eq!(files[0]["length"].as_u64(), Some(FILE_LEN as u64));
    assert_eq!(files[0]["included"], true);
    assert_eq!(files[0]["mime"], "video/x-matroska");
    assert_eq!(files[0]["isVideo"], true);
    // 这里不断言 downloaded/complete==false：回环下载在响应返回前就可能已经开始。
    // 未完成分支的确定性断言在 events.rs（无 peer → 必然 0 字节），
    // 完成分支在下方第 9 步与本文件末尾断言。
    assert!(files[0]["downloaded"].is_u64());
    assert!(files[0]["complete"].is_boolean());

    // 同一 info hash 重复提交 → 幂等返回既有 id（契约 §3.5）
    let again = engine
        .post_json(
            "/torrents",
            &serde_json::json!({
                "torrentBase64": base64::engine::general_purpose::STANDARD.encode(&torrent_bytes),
            }),
        )
        .send(engine.addr)
        .await?;
    assert_eq!(again.status, 200, "body: {}", again.body_str());
    assert_eq!(
        again.json()["id"].as_u64(),
        Some(id),
        "re-add must be idempotent"
    );

    // 播放 URL 用 ?token= 的形式（mpv 无法自定义 header，契约 §3.3）
    let stream_path = format!("/torrents/{id}/files/0/stream?token={}", engine.token);

    // ---------------------------------------------------------------- 5. 无 Range → 200 全文
    let full = Request::get(&stream_path)
        .timeout(Duration::from_secs(180))
        .send(engine.addr)
        .await
        .context("GET stream (no range) failed")?;
    assert_eq!(full.status, 200, "body: {}", full.body_str());
    assert_eq!(full.header("accept-ranges"), Some("bytes"));
    assert_eq!(full.header("content-type"), Some("video/x-matroska"));
    assert_eq!(
        full.header("content-length")
            .and_then(|v| v.parse::<u64>().ok()),
        Some(FILE_LEN as u64)
    );
    assert_eq!(full.body.len(), FILE_LEN, "streamed length mismatch");
    assert!(
        full.body == content,
        "streamed bytes differ from the source file"
    );

    // ---------------------------------------------------------------- 6. Range 1024-2047 → 206
    let ranged = Request::get(&stream_path)
        .header("Range", "bytes=1024-2047")
        .timeout(Duration::from_secs(120))
        .send(engine.addr)
        .await
        .context("GET stream (range) failed")?;
    assert_eq!(ranged.status, 206, "body: {}", ranged.body_str());
    assert_eq!(
        ranged.header("content-range"),
        Some(format!("bytes 1024-2047/{FILE_LEN}").as_str())
    );
    assert_eq!(
        ranged
            .header("content-length")
            .and_then(|v| v.parse::<u64>().ok()),
        Some(1024)
    );
    assert_eq!(ranged.body, content[1024..2048].to_vec());

    // 开区间 Range → 206 到 EOF
    let open_ended = Request::get(&stream_path)
        .header("Range", &format!("bytes={}-", FILE_LEN - 16))
        .timeout(Duration::from_secs(120))
        .send(engine.addr)
        .await?;
    assert_eq!(open_ended.status, 206);
    assert_eq!(
        open_ended.header("content-range"),
        Some(format!("bytes {}-{}/{FILE_LEN}", FILE_LEN - 16, FILE_LEN - 1).as_str())
    );
    assert_eq!(open_ended.body, content[FILE_LEN - 16..].to_vec());

    // ---------------------------------------------------------------- 7. 越界 Range → 416
    let bad_range = Request::get(&stream_path)
        .header("Range", "bytes=999999999-")
        .timeout(Duration::from_secs(30))
        .send(engine.addr)
        .await?;
    assert_eq!(bad_range.status, 416);
    assert_eq!(
        bad_range.header("content-range"),
        Some(format!("bytes */{FILE_LEN}").as_str())
    );
    assert_eq!(
        bad_range.error_code().as_deref(),
        Some("range_not_satisfiable")
    );

    // 语法非法同样 416
    let malformed = Request::get(&stream_path)
        .header("Range", "bytes=abc-def")
        .timeout(Duration::from_secs(30))
        .send(engine.addr)
        .await?;
    assert_eq!(malformed.status, 416);

    // 多段 Range 明确不支持（契约只要求单段）：501，不做假成功
    let multi = Request::get(&stream_path)
        .header("Range", "bytes=0-15,32-47")
        .timeout(Duration::from_secs(30))
        .send(engine.addr)
        .await?;
    assert_eq!(multi.status, 501);
    assert_eq!(
        multi.error_code().as_deref(),
        Some("multi_range_not_supported")
    );

    // ---------------------------------------------------------------- 8. 401
    let unauthorized = Request::get(&format!("/torrents/{id}/files/0/stream"))
        .timeout(Duration::from_secs(15))
        .send(engine.addr)
        .await?;
    assert_eq!(unauthorized.status, 401);
    assert_eq!(unauthorized.error_code().as_deref(), Some("unauthorized"));

    // 不存在的文件 → 404 no_such_file（契约 §3.8）
    let missing_file = Request::get(&format!(
        "/torrents/{id}/files/99/stream?token={}",
        engine.token
    ))
    .timeout(Duration::from_secs(15))
    .send(engine.addr)
    .await?;
    assert_eq!(missing_file.status, 404);
    assert_eq!(missing_file.error_code().as_deref(), Some("no_such_file"));

    // ---------------------------------------------------------------- 9. 完成状态
    // 全部下载完成后 progress=1 且文件 complete=true（file_progress 换算，契约 §3.6）
    let view = engine
        .get(&format!("/torrents/{id}"))
        .send(engine.addr)
        .await?;
    assert_eq!(view.status, 200);
    let view = view.json();
    assert_eq!(view["files"][0]["complete"], true);
    assert_eq!(
        view["files"][0]["downloaded"].as_u64(),
        Some(FILE_LEN as u64)
    );
    assert_eq!(view["finished"], true);
    assert!(view["progress"].as_f64().unwrap() > 0.99);

    // SSE 的 snapshot 也应当能立刻反映该 torrent
    let mut sse = Request::get(&format!("/events?token={}", engine.token))
        .open(engine.addr)
        .await?;
    let text = read_until(&mut sse, &[&info_hash], Duration::from_secs(10)).await?;
    assert!(text.contains("event: snapshot"), "no snapshot: {text}");
    assert!(
        text.contains(&format!("\"id\":{id}")),
        "no torrent in snapshot: {text}"
    );

    Ok(())
}

/// 核心语义（契约 §3.8）：**缺片时请求要挂起，而不是报错/500/416/503。**
///
/// 场景：本地 session **没有任何 peer**（无 DHT / 无 tracker / 无 initial_peers），
/// 所以一个字节都下不来；此时请求起点落在「已下载区间之外」（已下载 = 空集，任意起点都在外面），
/// 端点是 `Range: bytes=<len-1024>-`：
///
/// * 响应头必须是合法的 `206 + Content-Range`（说明走了正常的 Range 路径）；
/// * **body 一个字节都不能有**（因为片没下到）；
/// * 在观察窗口内连接**不能 EOF/结束**（结束就意味着报错或假成功）。
///
/// 用 `read_for(3s)` 把「挂起」变成有界断言，避免测试自己卡死。
#[tokio::test(flavor = "multi_thread")]
async fn range_beyond_downloaded_region_hangs_instead_of_erroring() -> Result<()> {
    const HANG_FILE_LEN: usize = 512 * 1024;

    let src = TempDir::new("hangsrc")?;
    std::fs::write(
        src.path().join("ep02.mkv"),
        pseudo_random_bytes(HANG_FILE_LEN, 0x5eed),
    )?;
    let torrent = create_torrent(
        &src.path().join("ep02.mkv"),
        CreateTorrentOptions {
            name: None,
            trackers: Vec::new(),
            piece_length: Some(32 * 1024),
        },
        &BlockingSpawner::new(1),
    )
    .await?;
    let torrent_bytes = torrent.as_bytes()?;

    let dl = TempDir::new("hangdl")?;
    // 关键：没有任何 peer 来源 → 永远下不到任何片（确定性，不依赖网络/时延）
    let session = local_session(dl.path(), None).await?;
    let engine = TestEngine::start(session, vec![]).await?;

    let added = engine
        .post_json(
            "/torrents",
            &serde_json::json!({
                "torrentBase64": base64::engine::general_purpose::STANDARD.encode(&torrent_bytes),
                "metadataTimeoutMs": 30_000u64,
            }),
        )
        .timeout(Duration::from_secs(60))
        .send(engine.addr)
        .await?;
    assert_eq!(added.status, 200, "body: {}", added.body_str());
    let id = added.json()["id"].as_u64().context("no id")?;
    // 没有 peer → 一个字节都没下（这也是 complete=false 的确定性样本）
    let view = engine
        .get(&format!("/torrents/{id}"))
        .send(engine.addr)
        .await?;
    let view = view.json();
    assert_eq!(view["progressBytes"].as_u64(), Some(0));
    assert_eq!(view["files"][0]["complete"], false);
    assert_eq!(view["files"][0]["downloaded"].as_u64(), Some(0));

    // Range 起点落在「已下载区间之外」（此处已下载为空集）
    let start = HANG_FILE_LEN - 1024;
    let mut sock = Request::get(&format!(
        "/torrents/{id}/files/0/stream?token={}",
        engine.token
    ))
    .header("Range", &format!("bytes={start}-"))
    .open(engine.addr)
    .await?;

    let (raw, saw_eof) = read_for(&mut sock, Duration::from_secs(3)).await?;
    let text = String::from_utf8_lossy(&raw).into_owned();
    let body_len = body_offset(&raw)
        .map(|off| raw.len().saturating_sub(off))
        .unwrap_or(0);

    assert!(
        !saw_eof,
        "缺片时请求必须挂起，不能结束（结束 = 报错或空 body）。收到：\n{text}"
    );
    assert_eq!(
        body_len, 0,
        "片还没下载，不应该有任何 body 字节。收到：\n{text}"
    );
    if !raw.is_empty() {
        assert!(
            text.starts_with("HTTP/1.1 206"),
            "有响应就必须是 206（不能是 500/503/416）：\n{text}"
        );
        assert!(
            text.to_ascii_lowercase().contains(&format!(
                "content-range: bytes {start}-{}/",
                HANG_FILE_LEN - 1
            )),
            "Content-Range 必须正确：\n{text}"
        );
    }

    Ok(())
}
