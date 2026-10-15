//! DSAnima 引擎边车（crate `rqbit-engine`）的库入口。
//!
//! 契约见 `docs/specs/2026-10-09-dsanima-design.md` §3。
//!
//! * [`cfg`]：命令行参数、`runtime.json` 原子写入。
//! * [`state`]：`AppState`、`TorrentView` 构建、SSE 事件与进度轮询任务。
//! * [`http`]：axum 路由、鉴权与全部端点。
//! * [`server`]：进程装配（建 session → 绑端口 → 写 runtime.json → ready → serve）。
//!
//! 二进制入口在 `src/main.rs`，只是一个薄壳；装配逻辑放在 lib 里是为了让 `tests/`
//! 下的集成测试能够直接装配引擎（自建本地 session + `router()` + `TcpListener`），
//! 而不必启动子进程，同时保证测试与真实二进制共用同一套代码。

pub mod cfg;
pub mod http;
pub mod server;
pub mod state;

pub use cfg::{iso8601_utc, Args, RuntimeFile, DEFAULT_TRACKERS};
pub use http::{parse_range, router, ApiError, ApiResult, RangeSpec, DEFAULT_METADATA_TIMEOUT_MS};
pub use server::{build_session, init_tracing, run};
pub use state::{AppState, ProgressView, TorrentFileView, TorrentSnapshot, TorrentView};
