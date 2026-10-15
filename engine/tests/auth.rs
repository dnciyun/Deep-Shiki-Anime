//! 契约 §3.3 / §3.10.2：`/health` 免鉴权，其余全部要 token；`?token=` 生效。

mod common;

use std::time::Duration;

use anyhow::Result;
use common::{local_session, Request, TempDir, TestEngine};

const PROTECTED: &[(&str, &str)] = &[
    ("GET", "/torrents"),
    ("POST", "/torrents"),
    ("GET", "/torrents/0"),
    ("GET", "/torrents/0/stats"),
    ("POST", "/torrents/0/pause"),
    ("POST", "/torrents/0/resume"),
    ("DELETE", "/torrents/0"),
    ("GET", "/torrents/0/files/0/stream"),
    ("GET", "/events"),
    ("POST", "/shutdown"),
];

fn request_for<'a>(method: &str, path: &'a str) -> Request<'a> {
    match method {
        "GET" => Request::get(path),
        "POST" => Request::post(path),
        "DELETE" => Request::delete(path),
        other => panic!("unsupported method {other}"),
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn auth_rules() -> Result<()> {
    let dir = TempDir::new("auth")?;
    let session = local_session(dir.path(), None).await?;
    let engine = TestEngine::start(session, vec![]).await?;

    // ---------------------------------------------------------------- /health 免鉴权
    let health = Request::get("/health")
        .timeout(Duration::from_secs(15))
        .send(engine.addr)
        .await?;
    assert_eq!(health.status, 200, "body: {}", health.body_str());
    let health_json = health.json();
    assert_eq!(health_json["ok"], true);
    assert_eq!(health_json["sessions"], 0);
    assert!(
        !health_json["version"]
            .as_str()
            .unwrap_or_default()
            .is_empty(),
        "health must carry a version: {health_json}"
    );

    // 带错误 token 也一样免鉴权（health 完全不看鉴权）
    let health_bad_token = Request::get("/health?token=nope").send(engine.addr).await?;
    assert_eq!(health_bad_token.status, 200);

    // ---------------------------------------------------------------- 无 token → 401
    for (method, path) in PROTECTED {
        let response = request_for(method, path)
            .timeout(Duration::from_secs(15))
            .send(engine.addr)
            .await?;
        assert_eq!(
            response.status,
            401,
            "{method} {path} should be 401, got {} ({})",
            response.status,
            response.body_str()
        );
        assert_eq!(
            response.error_code().as_deref(),
            Some("unauthorized"),
            "{method} {path} body: {}",
            response.body_str()
        );
    }

    // ---------------------------------------------------------------- 错误 token → 401
    let wrong_bearer = Request::get("/torrents")
        .bearer("deadbeef")
        .send(engine.addr)
        .await?;
    assert_eq!(wrong_bearer.status, 401);

    // 少了 "Bearer " 前缀 → 401
    let no_prefix = Request::get("/torrents")
        .header("Authorization", &engine.token)
        .send(engine.addr)
        .await?;
    assert_eq!(no_prefix.status, 401);

    let wrong_query = Request::get("/torrents?token=deadbeef")
        .send(engine.addr)
        .await?;
    assert_eq!(wrong_query.status, 401);

    // 大小写/空白差异视为不同 token
    let trailing_space = Request::get(&format!("/torrents?token={}%20", engine.token))
        .send(engine.addr)
        .await?;
    assert_eq!(trailing_space.status, 401);

    // ---------------------------------------------------------------- 正确 token → 200
    let with_bearer = Request::get("/torrents")
        .bearer(&engine.token)
        .send(engine.addr)
        .await?;
    assert_eq!(with_bearer.status, 200, "body: {}", with_bearer.body_str());
    assert_eq!(
        with_bearer.json()["torrents"].as_array().map(Vec::len),
        Some(0)
    );

    let with_query = Request::get(&format!("/torrents?token={}", engine.token))
        .send(engine.addr)
        .await?;
    assert_eq!(with_query.status, 200, "body: {}", with_query.body_str());

    // 其他查询参数与 token 共存（DELETE 会带 deleteFiles）
    let with_both = Request::get(&format!(
        "/torrents?deleteFiles=false&token={}",
        engine.token
    ))
    .send(engine.addr)
    .await?;
    assert_eq!(with_both.status, 200, "body: {}", with_both.body_str());

    // ---------------------------------------------------------------- 未实现的路径不能返回 200
    let unknown = Request::get(&format!(
        "/definitely-not-an-endpoint?token={}",
        engine.token
    ))
    .send(engine.addr)
    .await?;
    assert_eq!(
        unknown.status, 404,
        "unknown route must 404, not fake success"
    );

    // 已知路径的错误方法 → 405
    let wrong_method = Request::post(&format!("/health?token={}", engine.token))
        .send(engine.addr)
        .await?;
    assert_eq!(wrong_method.status, 405);

    Ok(())
}
