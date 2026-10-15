//! 命令行参数、运行时配置与 `runtime.json` 的原子写入。
//!
//! 对应设计契约 §3.1（构建与命名）、§3.2（命令行 / runtime.json）、§3.7（默认 tracker）。

use std::ffi::OsString;
use std::io::Write;
use std::num::NonZeroU32;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use clap::Parser;
use serde::Serialize;

/// 内置默认 tracker 列表（契约 §3.7）。磁力链常常不带 tracker，这里是兜底。
pub const DEFAULT_TRACKERS: &[&str] = &[
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://open.stealth.si:80/announce",
    "udp://tracker.torrent.eu.org:451/announce",
    "udp://exodus.desync.com:6969/announce",
    "http://tracker.anirena.com:80/announce",
    "udp://tracker.dler.org:6969/announce",
];

/// `runtime.json` 的 schema 版本。
pub const RUNTIME_SCHEMA: u32 = 1;

#[derive(Parser, Debug, Clone)]
#[command(
    name = "rqbit-engine",
    version,
    about = "DSAnima torrent sidecar engine (librqbit + axum)"
)]
pub struct Args {
    /// HTTP 监听端口；0 = 由系统分配
    #[arg(long, default_value_t = 0)]
    pub port: u16,

    /// runtime.json 落盘路径
    #[arg(long = "runtime-file")]
    pub runtime_file: PathBuf,

    /// 下载目录（session 默认输出目录）
    #[arg(long = "download-dir")]
    pub download_dir: PathBuf,

    /// 状态目录（会话持久化，用于重启后续下）
    #[arg(long = "state-dir")]
    pub state_dir: PathBuf,

    /// 做种比例；0（默认）= 不做种比例限制，>0 = 达到比例后暂停该 torrent
    #[arg(long = "seed-ratio", default_value_t = 0.0)]
    pub seed_ratio: f64,

    /// 上传限速，单位 KiB/s；0 = 不限（产品默认 100 KiB/s）
    #[arg(long = "upload-limit-kbps", default_value_t = 100)]
    pub upload_limit_kbps: u32,

    /// 下载限速，单位 KiB/s；0 = 不限
    #[arg(long = "download-limit-kbps", default_value_t = 0)]
    pub download_limit_kbps: u32,

    /// 追加公共 tracker，逗号分隔（追加在内置列表之后，去重）
    #[arg(long = "trackers", default_value = "")]
    pub trackers: String,

    /// tracing 落盘路径（可选；同时仍然写 stderr）
    #[arg(long = "log-file")]
    pub log_file: Option<PathBuf>,
}

impl Args {
    /// 内置默认 tracker + `--trackers` 追加，按出现顺序去重。
    pub fn tracker_urls(&self) -> Vec<String> {
        merge_trackers(DEFAULT_TRACKERS, &self.trackers)
    }

    pub fn upload_bps(&self) -> Option<NonZeroU32> {
        kbps_to_bps(self.upload_limit_kbps)
    }

    pub fn download_bps(&self) -> Option<NonZeroU32> {
        kbps_to_bps(self.download_limit_kbps)
    }
}

/// 单位换算：`--*-limit-kbps` 按 KiB/s 解释（librqbit 的 `*_bps` 是字节/秒）。
pub fn kbps_to_bps(kbps: u32) -> Option<NonZeroU32> {
    NonZeroU32::new(kbps.saturating_mul(1024))
}

/// `defaults` + 逗号分隔的 `extra`，去重并保留顺序。
pub fn merge_trackers(defaults: &[&str], extra: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::with_capacity(defaults.len() + 4);
    for t in defaults.iter().copied().chain(extra.split(',')) {
        let t = t.trim();
        if t.is_empty() || out.iter().any(|e| e == t) {
            continue;
        }
        out.push(t.to_owned());
    }
    out
}

/// `runtime.json`（契约 §3.2）。Dart 侧只认这个文件，因此必须整体原子替换。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeFile {
    pub schema: u32,
    pub pid: u32,
    pub port: u16,
    pub token: String,
    pub base_url: String,
    pub download_dir: String,
    pub state_dir: String,
    pub started_at: String,
}

impl RuntimeFile {
    pub fn new(port: u16, token: impl Into<String>, download_dir: &Path, state_dir: &Path) -> Self {
        Self {
            schema: RUNTIME_SCHEMA,
            pid: std::process::id(),
            port,
            token: token.into(),
            base_url: format!("http://127.0.0.1:{port}"),
            download_dir: download_dir.to_string_lossy().into_owned(),
            state_dir: state_dir.to_string_lossy().into_owned(),
            started_at: iso8601_utc(SystemTime::now()),
        }
    }

    pub fn to_json_string(&self) -> Result<String> {
        Ok(serde_json::to_string_pretty(self)?)
    }

    /// 写 `<path>.tmp` → fsync → rename 覆盖 `<path>`（原子替换）。
    pub fn write_atomic(&self, path: &Path) -> Result<()> {
        let json = self.to_json_string()?;
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent)
                    .with_context(|| format!("error creating directory {parent:?}"))?;
            }
        }

        let mut tmp_name: OsString = path.as_os_str().to_owned();
        tmp_name.push(".tmp");
        let tmp_path = PathBuf::from(tmp_name);

        {
            let mut f = std::fs::OpenOptions::new()
                .create(true)
                .write(true)
                .truncate(true)
                .open(&tmp_path)
                .with_context(|| format!("error creating {tmp_path:?}"))?;
            f.write_all(json.as_bytes())
                .with_context(|| format!("error writing {tmp_path:?}"))?;
            f.flush()
                .with_context(|| format!("error flushing {tmp_path:?}"))?;
            f.sync_all()
                .with_context(|| format!("error syncing {tmp_path:?}"))?;
        }

        // Windows 上 std::fs::rename 走 MoveFileEx(MOVEFILE_REPLACE_EXISTING)，可覆盖已存在文件。
        std::fs::rename(&tmp_path, path)
            .with_context(|| format!("error renaming {tmp_path:?} to {path:?}"))?;
        Ok(())
    }
}

/// `SystemTime` → `2026-10-09T12:00:00Z`（UTC，秒级）。
pub fn iso8601_utc(t: SystemTime) -> String {
    let secs = match t.duration_since(UNIX_EPOCH) {
        Ok(d) => d.as_secs() as i64,
        Err(e) => -(e.duration().as_secs() as i64),
    };
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (y, mo, d) = civil_from_days(days);
    format!(
        "{y:04}-{mo:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

/// Howard Hinnant 的 civil_from_days：把「1970-01-01 起的天数」换算成年月日。
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let shifted = if z >= 0 { z } else { z - 146_096 };
    let era = shifted / 146_097;
    let doe = (z - era * 146_097) as u64; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as i64; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    let m = m as i64;
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn iso8601_known_values() {
        let at = |s: u64| iso8601_utc(UNIX_EPOCH + Duration::from_secs(s));
        assert_eq!(at(0), "1970-01-01T00:00:00Z");
        assert_eq!(at(86_399), "1970-01-01T23:59:59Z");
        assert_eq!(at(86_400), "1970-01-02T00:00:00Z");
        // 2000-02-29（闰日）
        assert_eq!(at(951_782_400), "2000-02-29T00:00:00Z");
        assert_eq!(at(1_000_000_000), "2001-09-09T01:46:40Z");
        assert_eq!(at(1_760_000_000), "2025-10-09T08:53:20Z");
    }

    #[test]
    fn runtime_json_shape_matches_spec() {
        let rt = RuntimeFile {
            schema: 1,
            pid: 12345,
            port: 45871,
            token: "ab".repeat(32),
            base_url: "http://127.0.0.1:45871".to_owned(),
            download_dir: "F:\\dl".to_owned(),
            state_dir: "F:\\st".to_owned(),
            started_at: "2026-10-09T12:00:00Z".to_owned(),
        };
        let v: serde_json::Value = serde_json::from_str(&rt.to_json_string().unwrap()).unwrap();
        let obj = v.as_object().unwrap();
        let mut keys: Vec<&str> = obj.keys().map(|s| s.as_str()).collect();
        keys.sort_unstable();
        assert_eq!(
            keys,
            vec![
                "baseUrl",
                "downloadDir",
                "pid",
                "port",
                "schema",
                "startedAt",
                "stateDir",
                "token"
            ]
        );
        assert_eq!(obj["schema"], 1);
        assert_eq!(obj["port"], 45871);
        assert_eq!(obj["token"].as_str().unwrap().len(), 64);
    }

    #[test]
    fn tracker_merge_appends_and_dedups() {
        let merged = merge_trackers(
            &["udp://a:1/announce", "udp://b:2/announce"],
            " udp://b:2/announce , udp://c:3/announce ,, ",
        );
        assert_eq!(
            merged,
            vec![
                "udp://a:1/announce",
                "udp://b:2/announce",
                "udp://c:3/announce"
            ]
        );
        assert_eq!(merge_trackers(DEFAULT_TRACKERS, "").len(), 6);
    }

    #[test]
    fn kbps_zero_means_unlimited() {
        assert!(kbps_to_bps(0).is_none());
        assert_eq!(kbps_to_bps(1).unwrap().get(), 1024);
        assert_eq!(kbps_to_bps(u32::MAX).unwrap().get(), u32::MAX);
    }
}
