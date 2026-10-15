//! 集成测试公共辅助：临时目录、极简 HTTP/1.1 客户端、本地引擎装配。
//!
//! **所有测试都禁止访问公网**：DHT 关闭、tracker 关闭、LSD 关闭，需要 peer 时用
//! `initial_peers` 直连本地回环做种会话。

#![allow(dead_code)]

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use librqbit::{ListenerOptions, Session, SessionOptions};
use rqbit_engine::state::AppState;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

/// 测试用固定 token（64 位 hex，与真实引擎同形）。
pub const TOKEN: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// 自管理生命周期的临时目录（不引入 extra 依赖）。
pub struct TempDir {
    path: PathBuf,
}

impl TempDir {
    pub fn new(prefix: &str) -> Result<Self> {
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let path =
            std::env::temp_dir().join(format!("dsanima-{prefix}-{}-{n}", std::process::id()));
        if path.exists() {
            let _ = std::fs::remove_dir_all(&path);
        }
        std::fs::create_dir_all(&path).with_context(|| format!("error creating {path:?}"))?;
        Ok(Self { path })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn join(&self, name: &str) -> PathBuf {
        self.path.join(name)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        // librqbit 可能还持有文件句柄，Windows 上删除失败是可接受的。
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

/// 本地测试 session：无 DHT、无 tracker、无 LSD、无持久化。
pub async fn local_session(dir: &Path, listen: Option<SocketAddr>) -> Result<Arc<Session>> {
    let opts = SessionOptions {
        dht: None,
        disable_trackers: true,
        disable_local_service_discovery: true,
        persistence: None,
        fastresume: false,
        listen: listen.map(|addr| ListenerOptions {
            listen_addr: addr,
            ..Default::default()
        }),
        ..Default::default()
    };
    Session::new_with_opts(dir.to_path_buf(), opts)
        .await
        .context("error creating local test session")
}

/// 测试用确定性伪随机字节（可复现，不需要额外依赖）。
pub fn pseudo_random_bytes(len: usize, seed: u64) -> Vec<u8> {
    let mut x = seed | 1;
    let mut out = Vec::with_capacity(len);
    for _ in 0..len {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        out.push((x & 0xff) as u8);
    }
    out
}

/// 装配好的测试引擎（HTTP 服务跑在独立 task 上）。
pub struct TestEngine {
    pub addr: SocketAddr,
    pub token: String,
    pub state: AppState,
}

impl TestEngine {
    /// `initial_peers` 必须在建 router **之前**设好：`AppState` 是 Clone，router 拿到的是副本，
    /// 之后再改 `engine.state.initial_peers` 不会影响已经交给 axum 的那份。
    pub async fn start(session: Arc<Session>, initial_peers: Vec<SocketAddr>) -> Result<Self> {
        let token = TOKEN.to_owned();
        let mut state = AppState::new(session, token.clone());
        state.initial_peers = initial_peers;
        // 与真实二进制共用同一段装配：不拉这个，/events 就没有 progress/state/heartbeat
        rqbit_engine::server::spawn_background_tasks(&state);
        let app = rqbit_engine::http::router(state.clone());
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .context("error binding test http listener")?;
        let addr = listener.local_addr()?;
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        Ok(Self { addr, token, state })
    }

    /// `GET`（带 Bearer token）。
    pub fn get<'a>(&self, path: &'a str) -> Request<'a> {
        Request::get(path).bearer(&self.token)
    }

    /// `GET`，不带任何鉴权。
    pub fn get_unauthenticated<'a>(&self, path: &'a str) -> Request<'a> {
        Request::get(path)
    }

    /// `POST /torrents`，body 为 JSON。
    pub fn post_json<'a>(&self, path: &'a str, body: &serde_json::Value) -> Request<'a> {
        Request::post(path)
            .bearer(&self.token)
            .json_body(body)
            .expect("test json body")
    }
}

#[derive(Debug, Clone)]
pub struct HttpResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl HttpResponse {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }

    pub fn body_str(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }

    pub fn json(&self) -> serde_json::Value {
        serde_json::from_slice(&self.body).unwrap_or(serde_json::Value::Null)
    }

    pub fn error_code(&self) -> Option<String> {
        self.json()
            .get("error")
            .and_then(|v| v.as_str())
            .map(str::to_owned)
    }
}

/// 极简 HTTP/1.1 请求构造器（测试里只用本机回环）。
pub struct Request<'a> {
    method: &'a str,
    path: &'a str,
    headers: Vec<(String, String)>,
    body: Option<Vec<u8>>,
    timeout: Duration,
}

impl<'a> Request<'a> {
    pub fn get(path: &'a str) -> Self {
        Self::new("GET", path)
    }

    pub fn post(path: &'a str) -> Self {
        Self::new("POST", path)
    }

    pub fn delete(path: &'a str) -> Self {
        Self::new("DELETE", path)
    }

    fn new(method: &'a str, path: &'a str) -> Self {
        Self {
            method,
            path,
            headers: Vec::new(),
            body: None,
            timeout: Duration::from_secs(120),
        }
    }

    pub fn header(mut self, name: &str, value: &str) -> Self {
        self.headers.push((name.to_owned(), value.to_owned()));
        self
    }

    pub fn bearer(self, token: &str) -> Self {
        self.header("Authorization", &format!("Bearer {token}"))
    }

    pub fn json_body(mut self, value: &serde_json::Value) -> Result<Self> {
        self.body = Some(serde_json::to_vec(value)?);
        Ok(self)
    }

    /// 直接塞原始 body（用于构造非法 JSON 之类）。
    pub fn raw_body(mut self, body: &[u8]) -> Self {
        self.body = Some(body.to_vec());
        self
    }

    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    fn head(&self) -> Vec<u8> {
        let mut req = format!(
            "{} {} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n",
            self.method, self.path
        );
        for (k, v) in &self.headers {
            req.push_str(&format!("{k}: {v}\r\n"));
        }
        if let Some(body) = &self.body {
            req.push_str(&format!(
                "Content-Type: application/json\r\nContent-Length: {}\r\n",
                body.len()
            ));
        }
        req.push_str("\r\n");
        req.into_bytes()
    }

    pub async fn send(self, addr: SocketAddr) -> Result<HttpResponse> {
        let mut stream = TcpStream::connect(addr)
            .await
            .with_context(|| format!("error connecting to {addr}"))?;
        stream.write_all(&self.head()).await?;
        if let Some(body) = &self.body {
            stream.write_all(body).await?;
        }
        stream.flush().await?;

        let mut raw = Vec::new();
        tokio::time::timeout(self.timeout, stream.read_to_end(&mut raw))
            .await
            .context("timed out reading response")??;
        parse_response(&raw)
    }

    /// 打开流式请求（SSE 用），返回已写入请求的连接。
    pub async fn open(self, addr: SocketAddr) -> Result<TcpStream> {
        let mut stream = TcpStream::connect(addr).await?;
        stream.write_all(&self.head()).await?;
        if let Some(body) = &self.body {
            stream.write_all(body).await?;
        }
        stream.flush().await?;
        Ok(stream)
    }
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

pub fn parse_response(raw: &[u8]) -> Result<HttpResponse> {
    let head_end = find_subslice(raw, b"\r\n\r\n").context("malformed response: no header end")?;
    let head = String::from_utf8_lossy(&raw[..head_end]).into_owned();
    let mut lines = head.split("\r\n");
    let status_line = lines.next().context("malformed response: no status line")?;
    let status: u16 = status_line
        .split_whitespace()
        .nth(1)
        .context("malformed response: no status code")?
        .parse()
        .context("malformed response: bad status code")?;
    let headers: Vec<(String, String)> = lines
        .filter_map(|l| l.split_once(':'))
        .map(|(k, v)| (k.trim().to_owned(), v.trim().to_owned()))
        .collect();
    let mut body = raw[head_end + 4..].to_vec();

    let chunked = headers
        .iter()
        .any(|(k, v)| k.eq_ignore_ascii_case("transfer-encoding") && v.contains("chunked"));
    if chunked {
        body = decode_chunked(&body).context("error decoding chunked body")?;
    }

    Ok(HttpResponse {
        status,
        headers,
        body,
    })
}

fn decode_chunked(raw: &[u8]) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    let mut pos = 0usize;
    loop {
        let line_end = find_subslice(&raw[pos..], b"\r\n").context("chunked: no size line")? + pos;
        let size_line = String::from_utf8_lossy(&raw[pos..line_end]).into_owned();
        let size = usize::from_str_radix(size_line.split(';').next().unwrap_or("").trim(), 16)
            .context("chunked: bad size")?;
        pos = line_end + 2;
        if size == 0 {
            break;
        }
        if pos + size > raw.len() {
            bail!("chunked: truncated body");
        }
        out.extend_from_slice(&raw[pos..pos + size]);
        pos += size + 2;
    }
    Ok(out)
}

/// 读 SSE：累积到 `needles` 全部出现或超时，返回已解码的文本。
pub async fn read_until(
    stream: &mut TcpStream,
    needles: &[&str],
    timeout: Duration,
) -> Result<String> {
    let deadline = Instant::now() + timeout;
    let mut buf = Vec::new();
    loop {
        let text = String::from_utf8_lossy(&buf).into_owned();
        if needles.iter().all(|n| text.contains(n)) {
            return Ok(text);
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            bail!("timed out waiting for {needles:?}; got:\n{text}",);
        }
        let mut chunk = [0u8; 8192];
        match tokio::time::timeout(remaining, stream.read(&mut chunk)).await {
            Ok(Ok(0)) => bail!("stream closed while waiting for {needles:?}; got:\n{text}"),
            Ok(Ok(n)) => buf.extend_from_slice(&chunk[..n]),
            Ok(Err(e)) => return Err(e).context("error reading stream"),
            Err(_) => bail!("timed out waiting for {needles:?}; got:\n{text}"),
        }
    }
}

/// 轮询直到 `cond` 为真。
pub async fn wait_until<F>(mut cond: F, timeout: Duration, what: &str) -> Result<()>
where
    F: FnMut() -> bool,
{
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if cond() {
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    bail!("timed out waiting for {what}")
}

/// 「只 accept、永不回话」的假 peer：BT 握手永远等不到响应。
/// 用来确定性地制造「元数据拿不到」或「一个字节都下不来」的场景。
pub async fn silent_peer() -> Result<SocketAddr> {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await?;
    let addr = listener.local_addr()?;
    tokio::spawn(async move {
        let mut held = Vec::new();
        while let Ok((socket, _)) = listener.accept().await {
            held.push(socket);
        }
    });
    Ok(addr)
}

/// 读响应头 + 尽量读 body，直到 `window` 用完；返回 (原始字节, 是否读到 EOF)。
/// 用于断言「请求挂起」这类不能等它结束的场景。
pub async fn read_for(stream: &mut TcpStream, window: Duration) -> Result<(Vec<u8>, bool)> {
    let deadline = Instant::now() + window;
    let mut buf = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Ok((buf, false));
        }
        match tokio::time::timeout(
            remaining.min(Duration::from_millis(200)),
            stream.read(&mut chunk),
        )
        .await
        {
            Ok(Ok(0)) => return Ok((buf, true)),
            Ok(Ok(n)) => buf.extend_from_slice(&chunk[..n]),
            Ok(Err(e)) => return Err(e).context("error reading stream"),
            Err(_) => {}
        }
    }
}

/// HTTP 响应里 body 的起始偏移（没有 `\r\n\r\n` 时返回 None）。
pub fn body_offset(raw: &[u8]) -> Option<usize> {
    find_subslice(raw, b"\r\n\r\n").map(|i| i + 4)
}
