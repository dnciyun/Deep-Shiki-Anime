//! 契约 §3.4 / §3.10.3：`{id}` 同时接受引擎分配的整数 id 与 40 位 info hash；
//! 顺带覆盖 pause/resume 幂等与 DELETE 的 `deleteFiles` 校验。

mod common;

use std::time::Duration;

use anyhow::{Context, Result};
use common::{local_session, pseudo_random_bytes, wait_until, Request, TempDir, TestEngine};
use librqbit::api::TorrentIdOrHash;
use librqbit::{
    create_torrent, spawn_utils::BlockingSpawner, AddTorrent, AddTorrentOptions,
    CreateTorrentOptions,
};

const FILE_LEN: usize = 256 * 1024;
const FILE_NAME: &str = "movie.mkv";

#[tokio::test(flavor = "multi_thread")]
async fn torrent_id_accepts_integer_and_info_hash() -> Result<()> {
    // ---------------------------------------------------------------- 准备：本地已有完整数据
    let src = TempDir::new("hashsrc")?;
    let content = pseudo_random_bytes(FILE_LEN, 0xfeed_face_dead_beef);
    std::fs::write(src.path().join(FILE_NAME), &content)?;

    let torrent = create_torrent(
        &src.path().join(FILE_NAME),
        CreateTorrentOptions {
            name: None,
            trackers: Vec::new(),
            piece_length: Some(64 * 1024),
        },
        &BlockingSpawner::new(1),
    )
    .await?;
    let torrent_bytes = torrent.as_bytes()?;
    let info_hash = torrent.info_hash().as_string();
    assert_eq!(info_hash.len(), 40);

    let dl = TempDir::new("hashdl")?;
    let session = local_session(dl.path(), None).await?;
    let handle = session
        .add_torrent(
            AddTorrent::from_bytes(torrent_bytes),
            Some(AddTorrentOptions {
                paused: false,
                overwrite: true,
                output_folder: Some(src.path().to_string_lossy().into_owned()),
                ..Default::default()
            }),
        )
        .await
        .context("error adding torrent to session")?
        .into_handle()
        .context("session did not return a handle")?;
    let id = handle.id();
    handle.wait_until_initialized().await?;

    let engine = TestEngine::start(session, vec![]).await?;
    wait_until(
        || {
            engine
                .state
                .view_of(TorrentIdOrHash::Id(id))
                .map(|v| v.finished && v.state == "live")
                .unwrap_or(false)
        },
        Duration::from_secs(60),
        "torrent to finish its initial data check and go live",
    )
    .await?;

    // ---------------------------------------------------------------- 整数 id
    let by_int = engine
        .get(&format!("/torrents/{id}"))
        .send(engine.addr)
        .await?;
    assert_eq!(by_int.status, 200, "body: {}", by_int.body_str());
    let view = by_int.json();
    assert_eq!(view["id"].as_u64(), Some(id as u64));
    assert_eq!(view["infoHash"].as_str(), Some(info_hash.as_str()));
    assert_eq!(view["state"], "live");
    assert_eq!(view["error"], serde_json::Value::Null);
    assert_eq!(view["totalBytes"].as_u64(), Some(FILE_LEN as u64));
    assert_eq!(view["progressBytes"].as_u64(), Some(FILE_LEN as u64));
    assert_eq!(view["finished"], true);
    assert_eq!(view["progress"], 1.0);
    assert_eq!(view["files"][0]["index"], 0);
    assert_eq!(view["files"][0]["path"], FILE_NAME);
    assert_eq!(view["files"][0]["length"].as_u64(), Some(FILE_LEN as u64));
    assert_eq!(
        view["files"][0]["downloaded"].as_u64(),
        Some(FILE_LEN as u64)
    );
    assert_eq!(view["files"][0]["complete"], true);
    assert_eq!(view["files"][0]["included"], true);
    assert_eq!(view["files"][0]["isVideo"], true);
    assert!(view["outputFolder"].as_str().is_some());

    // ---------------------------------------------------------------- info hash
    let by_hash = engine
        .get(&format!("/torrents/{info_hash}"))
        .send(engine.addr)
        .await?;
    assert_eq!(by_hash.status, 200, "body: {}", by_hash.body_str());
    assert_eq!(by_hash.json()["id"].as_u64(), Some(id as u64));

    // 大写 hex 也应接受（TorrentIdOrHash::parse 走 Id20::from_str）
    let by_upper = engine
        .get(&format!("/torrents/{}", info_hash.to_uppercase()))
        .send(engine.addr)
        .await?;
    assert_eq!(by_upper.status, 200, "body: {}", by_upper.body_str());

    // /stats 与 /torrents/{id} 同形（同一份 TorrentView）
    let stats = engine
        .get(&format!("/torrents/{info_hash}/stats"))
        .send(engine.addr)
        .await?;
    assert_eq!(stats.status, 200);
    assert_eq!(stats.json(), view);

    // 列表里也应当有它
    let list = engine.get("/torrents").send(engine.addr).await?;
    assert_eq!(list.status, 200);
    let list = list.json();
    assert_eq!(list["torrents"].as_array().map(Vec::len), Some(1));
    assert_eq!(
        list["torrents"][0]["infoHash"].as_str(),
        Some(info_hash.as_str())
    );

    // ---------------------------------------------------------------- 用 hash 串流 + Range
    let stream = engine
        .get(&format!("/torrents/{info_hash}/files/0/stream"))
        .header("Range", "bytes=0-15")
        .timeout(Duration::from_secs(30))
        .send(engine.addr)
        .await?;
    assert_eq!(stream.status, 206, "body: {}", stream.body_str());
    assert_eq!(stream.body, content[..16].to_vec());

    // ---------------------------------------------------------------- pause / resume（幂等）
    let paused = engine
        .post_json(
            &format!("/torrents/{info_hash}/pause"),
            &serde_json::json!({}),
        )
        .timeout(Duration::from_secs(30))
        .send(engine.addr)
        .await?;
    assert_eq!(paused.status, 200, "body: {}", paused.body_str());
    assert_eq!(paused.json()["state"], "paused");

    // 再 pause 一次：已经暂停 → 幂等成功，不是错误
    let paused_again = engine
        .post_json(&format!("/torrents/{id}/pause"), &serde_json::json!({}))
        .send(engine.addr)
        .await?;
    assert_eq!(
        paused_again.status,
        200,
        "body: {}",
        paused_again.body_str()
    );
    assert_eq!(
        engine
            .get(&format!("/torrents/{id}"))
            .send(engine.addr)
            .await?
            .json()["state"],
        "paused"
    );

    let resumed = engine
        .post_json(
            &format!("/torrents/{info_hash}/resume"),
            &serde_json::json!({}),
        )
        .send(engine.addr)
        .await?;
    assert_eq!(resumed.status, 200, "body: {}", resumed.body_str());
    let resumed_view = engine
        .get(&format!("/torrents/{id}"))
        .send(engine.addr)
        .await?;
    assert_eq!(resumed_view.json()["state"], "live");

    // ---------------------------------------------------------------- 未知 / 非法 id
    let missing_int = engine.get("/torrents/987654").send(engine.addr).await?;
    assert_eq!(missing_int.status, 404);
    assert_eq!(missing_int.error_code().as_deref(), Some("no_such_torrent"));

    let missing_hash = engine
        .get(&format!("/torrents/{}", "a".repeat(40)))
        .send(engine.addr)
        .await?;
    assert_eq!(missing_hash.status, 404);
    assert_eq!(
        missing_hash.error_code().as_deref(),
        Some("no_such_torrent")
    );

    let bad_id = engine.get("/torrents/not-an-id").send(engine.addr).await?;
    assert_eq!(bad_id.status, 400);
    assert_eq!(bad_id.error_code().as_deref(), Some("bad_id"));

    let bad_index = engine
        .get(&format!(
            "/torrents/{id}/files/oops/stream?token={}",
            engine.token
        ))
        .send(engine.addr)
        .await?;
    assert_eq!(bad_index.status, 400);
    assert_eq!(bad_index.error_code().as_deref(), Some("bad_file_index"));

    // ---------------------------------------------------------------- deleteFiles 校验
    let bad_delete = Request::delete(&format!(
        "/torrents/{id}?deleteFiles=maybe&token={}",
        engine.token
    ))
    .send(engine.addr)
    .await?;
    assert_eq!(bad_delete.status, 400);
    assert_eq!(bad_delete.error_code().as_deref(), Some("bad_delete_files"));

    // 默认 deleteFiles=false：删掉记录但保留磁盘文件
    let deleted = Request::delete(&format!("/torrents/{info_hash}?token={}", engine.token))
        .send(engine.addr)
        .await?;
    assert_eq!(deleted.status, 200, "body: {}", deleted.body_str());
    let deleted_json = deleted.json();
    assert_eq!(deleted_json["ok"], true);
    assert_eq!(deleted_json["filesDeleted"], false);
    assert!(src.path().join(FILE_NAME).exists(), "files must be kept");

    let gone = engine
        .get(&format!("/torrents/{id}"))
        .send(engine.addr)
        .await?;
    assert_eq!(gone.status, 404);
    assert_eq!(
        engine.get("/torrents").send(engine.addr).await?.json()["torrents"]
            .as_array()
            .map(Vec::len),
        Some(0)
    );

    // 重复删除 → 404
    let delete_again = Request::delete(&format!("/torrents/{id}?token={}", engine.token))
        .send(engine.addr)
        .await?;
    assert_eq!(delete_again.status, 404);

    Ok(())
}
