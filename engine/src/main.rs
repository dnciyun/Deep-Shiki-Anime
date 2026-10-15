//! `rqbit-engine.exe` 入口 —— **薄壳**：
//! 解析 CLI → 初始化日志 → 调 `rqbit_engine::server::run`。
//!
//! 真正的装配逻辑全在 lib 里（`server.rs` / `state.rs` / `http.rs`），
//! 这样集成测试和真实二进制走的是同一条装配路径。

use clap::Parser;
use rqbit_engine::cfg::Args;

#[tokio::main]
async fn main() {
    let args = Args::parse();
    if let Err(e) = rqbit_engine::server::init_tracing(args.log_file.as_deref()) {
        eprintln!("error initializing logging: {e:#}");
        std::process::exit(2);
    }
    if let Err(e) = rqbit_engine::server::run(args).await {
        tracing::error!("fatal: {e:#}");
        std::process::exit(1);
    }
}
