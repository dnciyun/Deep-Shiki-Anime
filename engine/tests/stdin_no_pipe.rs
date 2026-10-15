//! 鲁棒性回归：**没有任何 stdin 的启动器**不能让引擎在宽限期之后自杀。
//!
//! 场景（真实世界全都踩过）：`Start-Process` 带 stdout/stderr 重定向、快捷方式、Windows
//! 服务、`flutter run` / VS 调试启动器 —— 这些都不给子进程 stdin。子进程第一次 read
//! 立刻拿到 EOF；如果把它当退出信号，引擎会在启动约 10 秒后神秘退出（`POST /torrents`
//! 报「基础连接已经关闭」、`/stream` 拿到 206 头之后 reset）。
//!
//! 这里用**真实二进制** + `Stdio::null()` 复现该环境，等 13 秒后断言 `/health` 仍 200
//! 且进程仍在；再等一轮确认不是「刚好还没到点」。
//!
//! ⚠️ 默认**跳过**：这个用例会启动真实二进制，而真实二进制默认开 DHT/UPnP（会碰公网），
//! 与「cargo test 禁止公网」的约束冲突。需要时显式打开：
//!
//! ```powershell
//! $env:DSANIMA_ENGINE_E2E='1'; cargo test --test stdin_no_pipe -- --nocapture
//! ```

mod common;

use std::net::SocketAddr;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use common::{Request, TempDir};

#[tokio::test(flavor = "multi_thread")]
async fn engine_survives_without_stdin() -> Result<()> {
    if std::env::var("DSANIMA_ENGINE_E2E").is_err() {
        eprintln!("SKIPPED: set DSANIMA_ENGINE_E2E=1 to run the real-binary stdin regression test");
        return Ok(());
    }

    let exe = env!("CARGO_BIN_EXE_rqbit-engine");
    let wd = TempDir::new("nostdin")?;
    let runtime_file = wd.join("runtime.json");

    let mut child = Command::new(exe)
        .args(["--port", "0"])
        .arg("--runtime-file")
        .arg(&runtime_file)
        .arg("--download-dir")
        .arg(wd.join("dl"))
        .arg("--state-dir")
        .arg(wd.join("state"))
        // 关键：模拟「启动器根本没给 stdin」
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .with_context(|| format!("error spawning {exe}"))?;

    let deadline = Instant::now() + Duration::from_secs(60);
    while !runtime_file.exists() {
        if Instant::now() > deadline {
            anyhow::bail!("runtime.json 未在 60s 内出现");
        }
        if let Some(status) = child.try_wait()? {
            anyhow::bail!("引擎在写出 runtime.json 之前就退出了：{status}");
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }

    let runtime: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&runtime_file)?)?;
    assert_eq!(runtime["schema"], 1, "runtime.json schema 必须是 1");
    let port = runtime["port"].as_u64().context("runtime.json 缺少 port")? as u16;
    let token = runtime["token"]
        .as_str()
        .context("runtime.json 缺少 token")?
        .to_owned();
    let addr = SocketAddr::from(([127, 0, 0, 1], port));

    // 睡过宽限期（STDIN_EOF_GRACE = 10s）再多一点
    tokio::time::sleep(Duration::from_secs(13)).await;
    assert!(
        child.try_wait()?.is_none(),
        "无 stdin 的引擎在宽限期后自杀了（正是要防的回归）"
    );
    let health = Request::get("/health")
        .timeout(Duration::from_secs(10))
        .send(addr)
        .await?;
    assert_eq!(health.status, 200, "body: {}", health.body_str());
    assert_eq!(health.json()["ok"], true);

    // 再等一轮：确认不是「刚好还没到点」
    tokio::time::sleep(Duration::from_secs(5)).await;
    assert!(
        child.try_wait()?.is_none(),
        "无 stdin 的引擎在第二次等待后自杀"
    );
    let health2 = Request::get("/health")
        .timeout(Duration::from_secs(10))
        .send(addr)
        .await?;
    assert_eq!(health2.status, 200);
    eprintln!("OK: 引擎在 Stdio::null() 下存活 >18s，/health 两次都是 200");

    // 清理：走 /shutdown 优雅退出
    let _ = Request::post("/shutdown")
        .bearer(&token)
        .timeout(Duration::from_secs(10))
        .send(addr)
        .await;
    let deadline = Instant::now() + Duration::from_secs(15);
    while child.try_wait()?.is_none() {
        if Instant::now() > deadline {
            child.kill()?;
            break;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }

    Ok(())
}
