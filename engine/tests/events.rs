//! 契约 §3.9：`/events` 的 SSE 事件流。
//!
//! 覆盖全部六种事件：`snapshot`（连接即发）、`torrent_added`、`state`、`progress`
//! （含 `completedFiles` 字段与未完成文件）、`torrent_removed`、`heartbeat`（15s）。

mod common;

use std::time::Duration;

use anyhow::Result;
use base64::Engine as _;
use common::{local_session, pseudo_random_bytes, read_until, Request, TempDir, TestEngine};
use librqbit::{create_torrent, spawn_utils::BlockingSpawner, CreateTorrentOptions};

const FILE_LEN: usize = 64 * 1024;

#[tokio::test(flavor = "multi_thread")]
async fn sse_emits_all_event_types() -> Result<()> {
    // 准备一个 .torrent（下载会话没有 peer，所以下载永远停在 0：这是确定性的“未完成”样本）
    let src = TempDir::new("evsrc")?;
    std::fs::write(
        src.path().join("ep01.mkv"),
        pseudo_random_bytes(FILE_LEN, 99),
    )?;
    let torrent = create_torrent(
        &src.path().join("ep01.mkv"),
        CreateTorrentOptions {
            name: None,
            trackers: Vec::new(),
            piece_length: Some(32 * 1024),
        },
        &BlockingSpawner::new(1),
    )
    .await?;
    let torrent_bytes = torrent.as_bytes()?;

    let dl = TempDir::new("evdl")?;
    let session = local_session(dl.path(), None).await?;
    let engine = TestEngine::start(session, vec![]).await?;

    // ---------------------------------------------------------------- snapshot
    let mut sse = Request::get(&format!("/events?token={}", engine.token))
        .open(engine.addr)
        .await?;
    let snapshot = read_until(
        &mut sse,
        &["event: snapshot", "data: {\"torrents\":[]}"],
        Duration::from_secs(15),
    )
    .await?;
    assert!(
        snapshot
            .to_ascii_lowercase()
            .contains("content-type: text/event-stream"),
        "wrong content type: {snapshot}"
    );

    // ---------------------------------------------------------------- torrent_added / state / progress
    let added = engine
        .post_json(
            "/torrents",
            &serde_json::json!({
                "torrentBase64": base64::engine::general_purpose::STANDARD.encode(&torrent_bytes),
                "name": "SSE 测试番剧",
                "metadataTimeoutMs": 30_000u64,
            }),
        )
        .timeout(Duration::from_secs(60))
        .send(engine.addr)
        .await?;
    assert_eq!(added.status, 200, "body: {}", added.body_str());
    let added_json = added.json();
    let id = added_json["id"].as_u64().expect("no id");
    // `name` 只覆盖展示名（不动落盘目录）
    assert_eq!(added_json["name"], "SSE 测试番剧");

    let events = read_until(
        &mut sse,
        &["event: torrent_added", "event: state", "event: progress"],
        Duration::from_secs(15),
    )
    .await?;
    assert!(events.contains("event: torrent_added"), "{events}");
    assert!(events.contains("event: state"), "{events}");
    assert!(events.contains("event: progress"), "{events}");
    assert!(
        events.contains(&format!("\"id\":{id}")),
        "events must carry the torrent id: {events}"
    );
    // progress 的字段名严格照契约
    assert!(events.contains("\"completedFiles\""), "{events}");
    assert!(events.contains("\"progressBytes\""), "{events}");
    assert!(events.contains("\"downloadBps\""), "{events}");
    assert!(events.contains("\"uploadBps\""), "{events}");
    assert!(events.contains("\"peers\""), "{events}");
    // 没有 peer → 文件必然未完成
    assert!(
        events.contains("\"complete\":false"),
        "expected an incomplete file progress: {events}"
    );
    assert!(
        events.contains("\"completedFiles\":[]"),
        "no file can be complete without peers: {events}"
    );
    // 展示名进了 torrent_added 的 TorrentView
    assert!(events.contains("SSE 测试番剧"), "{events}");

    // ---------------------------------------------------------------- heartbeat（15s）
    let heartbeat = read_until(&mut sse, &["event: heartbeat"], Duration::from_secs(25)).await?;
    assert!(heartbeat.contains("event: heartbeat"), "{heartbeat}");
    assert!(heartbeat.contains("data: {}"), "{heartbeat}");

    // ---------------------------------------------------------------- torrent_removed
    let deleted = Request::delete(&format!("/torrents/{id}?token={}", engine.token))
        .send(engine.addr)
        .await?;
    assert_eq!(deleted.status, 200, "body: {}", deleted.body_str());
    let removed = read_until(
        &mut sse,
        &["event: torrent_removed"],
        Duration::from_secs(15),
    )
    .await?;
    assert!(removed.contains("event: torrent_removed"), "{removed}");
    assert!(
        removed.contains(&format!("{{\"id\":{id}}}")),
        "removed event payload: {removed}"
    );

    Ok(())
}
