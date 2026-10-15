//! `POST /torrents` 的失败语义（契约 §3.5）：
//!
//! * 参数校验错误 → 400 + 明确的 `error` code；
//! * 磁力链拿不到元数据 → 在 `metadataTimeoutMs` 内返回 **504 `metadata_timeout`**，
//!   **不能无限挂住**（librqbit 的 `add_torrent` 内部等元数据且没有超时，
//!   所以引擎必须自己用独立 task + deadline 实现）；
//! * 超时后 torrent 仍在后台找元数据：此时它还没被注册进 session，
//!   所以 `GET /torrents` 里看不到它是**正确行为**（不是丢任务）。
//!
//! 测试用「只接受连接、永不回话」的本地 TCP 监听器当 peer：BT 握手永远等不到响应，
//! 元数据解析必然卡住 → 用来确定性地触发超时分支。全程不访问公网。

mod common;

use std::time::{Duration, Instant};

use anyhow::Result;
use common::{local_session, silent_peer, TempDir, TestEngine};

#[tokio::test(flavor = "multi_thread")]
async fn add_torrent_validation_errors() -> Result<()> {
    let dir = TempDir::new("addval")?;
    let session = local_session(dir.path(), None).await?;
    let engine = TestEngine::start(session, vec![]).await?;

    let cases: Vec<(&str, serde_json::Value, &str)> = vec![
        ("missing_source", serde_json::json!({}), "missing_source"),
        (
            "ambiguous_source",
            serde_json::json!({
                "magnet": "magnet:?xt=urn:btih:0000000000000000000000000000000000000000",
                "torrentBase64": "ZDE6YQ==",
            }),
            "ambiguous_source",
        ),
        (
            "bad_magnet",
            serde_json::json!({ "magnet": "http://example.com/x.torrent" }),
            "bad_magnet",
        ),
        (
            "bad_info_hash",
            serde_json::json!({ "infoHash": "zzzz" }),
            "bad_info_hash",
        ),
        (
            "bad_torrent_base64",
            serde_json::json!({ "torrentBase64": "!!!not-base64!!!" }),
            "bad_torrent_base64",
        ),
        (
            "empty_only_files",
            serde_json::json!({
                "torrentBase64": "ZDE6YQ==",
                "onlyFiles": [],
            }),
            "empty_only_files",
        ),
        (
            "bad_initial_peer",
            serde_json::json!({
                "torrentBase64": "ZDE6YQ==",
                "initialPeers": ["not-an-address"],
            }),
            "bad_initial_peer",
        ),
    ];

    for (name, body, expected_code) in cases {
        let response = engine
            .post_json("/torrents", &body)
            .timeout(Duration::from_secs(15))
            .send(engine.addr)
            .await?;
        assert_eq!(
            response.status,
            400,
            "case {name}: expected 400, got {} ({})",
            response.status,
            response.body_str()
        );
        assert_eq!(
            response.error_code().as_deref(),
            Some(expected_code),
            "case {name}: body {}",
            response.body_str()
        );
        assert!(
            response
                .json()
                .get("message")
                .and_then(|m| m.as_str())
                .is_some_and(|m| !m.is_empty()),
            "case {name}: 错误必须带可行动 message，实际 {}",
            response.body_str()
        );
    }

    // 非法 JSON → 400 bad_json（不是 500，也不是静默成功）
    let bad_json = common::Request::post("/torrents")
        .bearer(&engine.token)
        .header("Content-Type", "application/json")
        .raw_body(b"{not json")
        .send(engine.addr)
        .await?;
    assert_eq!(bad_json.status, 400, "body: {}", bad_json.body_str());
    assert_eq!(bad_json.error_code().as_deref(), Some("bad_json"));

    assert_eq!(
        engine.get("/torrents").send(engine.addr).await?.json()["torrents"]
            .as_array()
            .map(Vec::len),
        Some(0),
        "校验失败的请求不得留下任何 torrent"
    );

    Ok(())
}

#[tokio::test(flavor = "multi_thread")]
async fn magnet_metadata_timeout_returns_504_without_hanging() -> Result<()> {
    let dir = TempDir::new("addtimeout")?;
    let session = local_session(dir.path(), None).await?;
    let engine = TestEngine::start(session, vec![]).await?;

    let peer = silent_peer().await?;
    let timeout_ms = 1_500u64;

    let started = Instant::now();
    let response = engine
        .post_json(
            "/torrents",
            &serde_json::json!({
                "magnet": "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
                "initialPeers": [peer.to_string()],
                "metadataTimeoutMs": timeout_ms,
            }),
        )
        .timeout(Duration::from_secs(30))
        .send(engine.addr)
        .await?;
    let elapsed = started.elapsed();

    assert_eq!(
        response.status,
        504,
        "期望 504 metadata_timeout，实际 {} ({})",
        response.status,
        response.body_str()
    );
    let body = response.json();
    assert_eq!(body["error"], "metadata_timeout");
    assert_eq!(body["phase"], "metadata");
    assert_eq!(body["infoHash"], "0123456789abcdef0123456789abcdef01234567");
    assert!(
        elapsed >= Duration::from_millis(timeout_ms),
        "must actually wait for the deadline, elapsed = {elapsed:?}"
    );
    assert!(
        elapsed < Duration::from_secs(20),
        "must not hang beyond the deadline, elapsed = {elapsed:?}"
    );

    // 元数据还没到 → torrent 尚未注册（正确行为：它仍在后台找元数据）
    let list = engine.get("/torrents").send(engine.addr).await?;
    assert_eq!(list.status, 200);
    assert_eq!(
        list.json()["torrents"].as_array().map(Vec::len),
        Some(0),
        "metadata 未就绪时不应出现在列表里"
    );

    // 同一个磁力链再提交一次：仍然 504（后台那次还在跑），但绝不能 panic/500
    let again = engine
        .post_json(
            "/torrents",
            &serde_json::json!({
                "magnet": "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
                "initialPeers": [peer.to_string()],
                "metadataTimeoutMs": 500,
            }),
        )
        .timeout(Duration::from_secs(30))
        .send(engine.addr)
        .await?;
    assert_eq!(again.status, 504, "body: {}", again.body_str());
    assert_eq!(again.error_code().as_deref(), Some("metadata_timeout"));

    Ok(())
}
