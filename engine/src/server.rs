//! 进程装配：建 session → 绑端口 → 写 runtime.json → ready → 服务（契约 §3.2）。
//!
//! 放在 lib 里（而不是 `main.rs`）是刻意的：二进制与集成测试共用同一套装配代码，
//! `main.rs` 只留一个薄壳，避免「测试通过但与真实二进制行为不一致」。

use std::future::IntoFuture;
use std::io::Write as _;
use std::net::Ipv4Addr;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};
use librqbit::limits::LimitsConfig;
use librqbit::{
    DhtSessionConfig, ListenerOptions, Session, SessionOptions, SessionPersistenceConfig,
    dht::DhtPersistenceConfig,
};
use tokio::sync::Notify;

use crate::cfg::{Args, RuntimeFile};
use crate::http::router;
use crate::state::{spawn_progress_task, spawn_stdin_watcher, AppState};

/// 启动顺序严格照契约 §3.2：
/// 建 session → 绑端口 → **先写 runtime.json（原子替换）** → 无条件 ready → 开始服务。
pub async fn run(args: Args) -> Result<()> {
    std::fs::create_dir_all(&args.download_dir)
        .with_context(|| format!("error creating download dir {:?}", args.download_dir))?;
    std::fs::create_dir_all(&args.state_dir)
        .with_context(|| format!("error creating state dir {:?}", args.state_dir))?;

    // 上一轮残留的 runtime.json 必须先删掉：Dart 只以「文件是否存在」判断引擎可用，
    // 留着旧文件会让它读到上一轮的端口与 token。
    match std::fs::remove_file(&args.runtime_file) {
        Ok(()) => tracing::debug!("removed stale runtime file"),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => {
            tracing::warn!(file = ?args.runtime_file, "error removing stale runtime file: {e:#}")
        }
    }

    let session = build_session(&args).await?;
    let restored = session.with_torrents(|t| t.count());
    tracing::info!(torrents = restored, "session created");

    let token = generate_token();
    let mut state = AppState::new(session, token.clone());
    state.seed_ratio = args.seed_ratio;

    // 1) 绑端口（0 → 系统分配，只绑回环）
    let listener = tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, args.port))
        .await
        .with_context(|| format!("error binding 127.0.0.1:{}", args.port))?;
    let port = listener
        .local_addr()
        .context("error reading local addr")?
        .port();

    // 2) 先写 runtime.json，Dart 看到文件即代表可用（token 不走 stdout）
    let runtime = RuntimeFile::new(port, token, &args.download_dir, &args.state_dir);
    runtime
        .write_atomic(&args.runtime_file)
        .context("error writing runtime file")?;

    // 3) 无条件 ready（stdout 只有这一行人类可读信息，不含 token）
    tracing::info!(
        port,
        runtime_file = %args.runtime_file.display(),
        download_dir = %args.download_dir.display(),
        state_dir = %args.state_dir.display(),
        "engine ready"
    );
    println!("rqbit-engine ready on {}", runtime.base_url);
    let _ = std::io::stdout().flush();

    // 4) 开始服务
    spawn_background_tasks(&state);
    spawn_stdin_watcher(state.shutdown.clone());
    spawn_ctrl_c_watcher(state.shutdown.clone());

    let app = router(state.clone());
    let shutdown = {
        let notify = state.shutdown.clone();
        async move { notify.notified().await }
    };
    let outcome = serve_until_shutdown(listener, app, shutdown).await;
    tracing::info!(?outcome, "http server stopped, shutting down session");
    state.session.stop().await;
    if let Err(e) = std::fs::remove_file(&args.runtime_file) {
        if e.kind() != std::io::ErrorKind::NotFound {
            tracing::warn!("error removing runtime file: {e:#}");
        }
    }
    tracing::info!("bye");
    // stdin watcher 可能卡在阻塞读上，直接退进程，避免 runtime 析构等它。
    std::process::exit(0);
}

/// 收到 shutdown 信号后，留给「正在写的响应」（尤其 `/shutdown` 的 200）flush 的时间。
///
/// ⚠️ 这个上限**只能作用在收到信号之后**。曾经把整个 `serve` future 包进
/// `timeout(3s, …)`，结果无论有没有信号，引擎都会在 ready 后 3 秒自杀 ——
/// 那才是「POST /torrents 报连接已关闭 / stream 拿到 206 头后 reset」的真凶。
pub const SHUTDOWN_DRAIN: Duration = Duration::from_millis(800);

#[derive(Debug)]
pub enum ServeOutcome {
    /// 收到 shutdown 信号（`/shutdown`、stdin EOF、Ctrl-C）。
    Signalled { drained: bool },
    /// 服务端自己结束了（监听器错误等），不是正常退出路径。
    ServerEnded(Option<String>),
}

/// 服务循环：**一直服务到 shutdown 信号**，信号到达后再给 in-flight 响应一个很短的
/// flush 窗口，然后不再等待（契约 §3.8：`/stream` 挂起是正常的，不能拖住退出）。
pub async fn serve_until_shutdown<F>(
    listener: tokio::net::TcpListener,
    app: axum::Router,
    signal: F,
) -> ServeOutcome
where
    F: std::future::Future<Output = ()> + Send,
{
    // 注意：axum 0.8 的 `Serve` 实现的是 `IntoFuture`，不是 `Future`，
    // 所以 select!/timeout 里必须先 `.into_future()`。
    let server = axum::serve(listener, app).into_future();
    tokio::pin!(server);

    tokio::select! {
        result = &mut server => ServeOutcome::ServerEnded(result.err().map(|e| e.to_string())),
        _ = signal => {
            let drained = tokio::time::timeout(SHUTDOWN_DRAIN, &mut server).await.is_ok();
            ServeOutcome::Signalled { drained }
        }
    }
}

/// 拉起「引擎行为相关」的后台任务：进度轮询 + SSE 事件源（`progress`/`state`/
/// `torrent_removed`/`heartbeat`）。
///
/// 二进制（[`run`]）与集成测试都必须调用它 —— 否则测试里 `/events` 一个事件都收不到，
/// 会出现「测试通过但真实二进制行为不同」的假绿灯。
pub fn spawn_background_tasks(state: &AppState) {
    spawn_progress_task(state.clone());
}

/// 建 librqbit session。
///
/// * DHT 开启（默认全开策略；磁力链无 tracker 时的主路径）
/// * tracker 关闭 = 否；内置默认 tracker + `--trackers` 追加（去重）
/// * LSD 开启：**靠 librqbit 的默认值**（本函数没有显式设 `disable_local_service_discovery`）
///   —— 依赖库默认，升级 librqbit 时要重新确认；PEX 同样由库默认开启，无开关
/// * TCP 监听 + UPnP 端口映射开启（用户选择的「全开」策略）
/// * `--state-dir` 作为 JSON 会话持久化目录 + `fastresume`：跨进程重启可继续下载
pub async fn build_session(args: &Args) -> Result<Arc<Session>> {
    let listen = ListenerOptions {
        enable_upnp_port_forwarding: true,
        ..Default::default()
    };

    let mut opts = SessionOptions {
        // DHT 的持久化路由表也放回**引擎自己的 state 目录**。
        //
        // 默认位置是 `%LOCALAPPDATA%\rqbit\dht\cache\dht.json` —— 同属引擎状态却被拆到
        // 支持目录之外（用户 2026-10-11「不要没用的缓存」）。放进来以后整个引擎状态只有
        // 一个目录，用户要看/要删都在同一处。
        dht: Some(DhtSessionConfig {
            persistence: Some(DhtPersistenceConfig {
                config_filename: Some(args.state_dir.join("dht.json")),
                ..Default::default()
            }),
            ..Default::default()
        }),
        disable_trackers: false,
        fastresume: true,
        persistence: Some(SessionPersistenceConfig::Json {
            folder: Some(args.state_dir.clone()),
        }),
        listen: Some(listen),
        ratelimits: LimitsConfig {
            upload_bps: args.upload_bps(),
            download_bps: args.download_bps(),
        },
        client_name_and_version: Some(format!("DSAnima/{}", env!("CARGO_PKG_VERSION"))),
        ..Default::default()
    };

    let mut accepted = 0usize;
    opts.trackers = args
        .tracker_urls()
        .into_iter()
        .filter_map(|t| match t.parse() {
            Ok(url) => {
                accepted += 1;
                Some(url)
            }
            Err(_) => {
                tracing::warn!(tracker = %t, "ignoring unparseable tracker url");
                None
            }
        })
        .collect();
    tracing::info!(trackers = accepted, "trackers configured");

    Session::new_with_opts(args.download_dir.clone(), opts)
        .await
        .context("error creating librqbit session")
}

/// 64 位 hex（32 字节 CSPRNG 随机数）。
fn generate_token() -> String {
    let mut out = String::with_capacity(64);
    for _ in 0..4 {
        out.push_str(&format!("{:016x}", rand::random::<u64>()));
    }
    out
}

fn spawn_ctrl_c_watcher(notify: Arc<Notify>) {
    tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            tracing::info!("ctrl-c received, shutting down");
            notify.notify_one();
        }
    });
}

/// 同时写 stderr 与（可选）日志文件。
#[derive(Clone)]
struct LogSink {
    file: Option<Arc<Mutex<std::fs::File>>>,
}

impl std::io::Write for LogSink {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let _ = std::io::stderr().write_all(buf);
        match &self.file {
            Some(f) => f.lock().expect("log file mutex poisoned").write(buf),
            None => Ok(buf.len()),
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        let _ = std::io::stderr().flush();
        if let Some(f) = &self.file {
            f.lock().expect("log file mutex poisoned").flush()?;
        }
        Ok(())
    }
}

/// `engine.log` 的单文件上限：超过就轮转成 `engine.log.1`（只留一代）。
///
/// 用户 2026-10-11「不要没用的缓存」：以前是 append 打开、**没有任何轮转** ——
/// 实测长期使用后 280KB 且只会继续长。只留一代足够回答"上次怎么退出的"，
/// 且不会把文件堆起来。
pub const MAX_LOG_BYTES: u64 = 8 * 1024 * 1024;

/// 超过 `max_bytes` 就把 `path` 轮转成 `path.1`（覆盖上一代）。
pub fn rotate_log_if_needed(path: &Path, max_bytes: u64) -> Result<()> {
    let Ok(meta) = std::fs::metadata(path) else {
        return Ok(()); // 还没有日志文件：第一次运行
    };
    if meta.len() < max_bytes {
        return Ok(());
    }
    let rotated = path.with_extension("log.1");
    match std::fs::remove_file(&rotated) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => eprintln!("error removing old rotated log {rotated:?}: {e:#}"),
    }
    std::fs::rename(path, &rotated)
        .with_context(|| format!("error rotating log {path:?}"))?;
    Ok(())
}

pub fn init_tracing(log_file: Option<&Path>) -> Result<()> {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));

    let file = match log_file {
        Some(path) => {
            if let Some(parent) = path.parent() {
                if !parent.as_os_str().is_empty() {
                    std::fs::create_dir_all(parent)
                        .with_context(|| format!("error creating log dir {parent:?}"))?;
                }
            }
            rotate_log_if_needed(path, MAX_LOG_BYTES)?;
            let f = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
                .with_context(|| format!("error opening log file {path:?}"))?;
            Some(Arc::new(Mutex::new(f)))
        }
        None => None,
    };

    let sink = LogSink { file };
    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_ansi(false)
        .with_writer(move || sink.clone())
        .init();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::routing::get;
    use std::time::Instant;

    async fn one_shot_http(addr: std::net::SocketAddr, path: &str) -> String {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let mut stream = tokio::net::TcpStream::connect(addr).await.unwrap();
        stream
            .write_all(
                format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
                    .as_bytes(),
            )
            .await
            .unwrap();
        let mut buf = Vec::new();
        stream.read_to_end(&mut buf).await.unwrap();
        String::from_utf8_lossy(&buf).into_owned()
    }

    /// 回归测试：**服务器不能自己到点退出**。
    ///
    /// 曾经的写法是 `timeout(3s, axum::serve(...))`，于是无论有没有 shutdown 信号，
    /// 引擎都在 ready 后 3 秒自杀 —— 外部表现就是「POST /torrents 报基础连接已关闭 /
    /// stream 拿到 206 头之后 reset」。这个测试盯住那个不变量：
    /// 4 秒后任务仍在跑，且 `/health` 仍能 200；发信号后才在 1 秒内退出。
    #[tokio::test(flavor = "multi_thread")]
    async fn server_keeps_running_until_signal() {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let addr = listener.local_addr().unwrap();
        let app: axum::Router = axum::Router::new().route("/health", get(|| async { "ok" }));

        let (tx, rx) = tokio::sync::oneshot::channel::<()>();
        let handle = tokio::spawn(async move {
            serve_until_shutdown(listener, app, async move {
                let _ = rx.await;
            })
            .await
        });

        // 故意等超过旧的 3 秒上限
        tokio::time::sleep(Duration::from_secs(4)).await;
        assert!(
            !handle.is_finished(),
            "server 在 4 秒后自己退出了（回归！）"
        );

        let response = tokio::time::timeout(Duration::from_secs(5), one_shot_http(addr, "/health"))
            .await
            .expect("4 秒后 /health 仍然必须可达");
        assert!(
            response.starts_with("HTTP/1.1 200"),
            "unexpected response: {response}"
        );

        let started = Instant::now();
        tx.send(()).unwrap();
        let outcome = tokio::time::timeout(Duration::from_secs(3), handle)
            .await
            .expect("收到信号后必须及时退出")
            .unwrap();
        assert!(
            matches!(outcome, ServeOutcome::Signalled { .. }),
            "unexpected outcome: {outcome:?}"
        );
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "退出太慢：{:?}",
            started.elapsed()
        );
    }

    /// 用户 2026-10-11「不要没用的缓存」：`engine.log` 以前 append 打开、**永不轮转**。
    #[test]
    fn rotate_log_when_it_exceeds_the_limit() {
        let dir = std::env::temp_dir().join(format!("dsanima-logrotate-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("engine.log");

        // 小文件：不动。
        std::fs::write(&log, b"small").unwrap();
        rotate_log_if_needed(&log, 16).unwrap();
        assert!(log.exists());
        assert!(!log.with_extension("log.1").exists());

        // 超限：轮转成 engine.log.1，原文件从此处重新开始。
        std::fs::write(&log, vec![b'x'; 64]).unwrap();
        rotate_log_if_needed(&log, 16).unwrap();
        assert!(!log.exists(), "轮转后原文件应被移走（调用方会重新创建）");
        assert_eq!(std::fs::metadata(log.with_extension("log.1")).unwrap().len(), 64);

        // 再轮转一次：只保留一代，旧的那份被覆盖。
        std::fs::write(&log, vec![b'y'; 32]).unwrap();
        rotate_log_if_needed(&log, 16).unwrap();
        assert_eq!(std::fs::metadata(log.with_extension("log.1")).unwrap().len(), 32);

        // 文件不存在（第一次运行）：静默通过。
        std::fs::remove_file(log.with_extension("log.1")).unwrap();
        rotate_log_if_needed(&log, 16).unwrap();

        let _ = std::fs::remove_dir_all(&dir);
    }
}
