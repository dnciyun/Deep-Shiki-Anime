/// 边下边播要用的 libmpv 网络调优 —— **纯命令表，离线可测**。
///
/// 背景（2026-10-19 真机日志 + 探针）：media_kit 初始化时把 `network-timeout`
/// 硬设为 **5 秒**（`media_kit/lib/src/player/native/player/real.dart` 的
/// `properties` 表）。边下边播时，mpv 要的那段分片常常 5 秒内拿不到 ——
/// rqbit 那边是按需下、单片可能要等做种者；5 秒一到 mpv 就把这条流当断流放弃，
/// 于是表现为「正在下载时点播放，一直不出画面，等下完就能播」。
///
/// 探针（`tool/spike_mpv_stream_cache.py` 同类做法）：同一份「先停 8 秒再给数据」的
/// HTTP 流，`--network-timeout=5` 失败（rc=2），`60` 正常出帧（rc=0）。
///
/// 另一条 `cache-on-disk=no`：media_kit 也把它硬设为 yes，而真机日志里出现过
/// `[mkv] Failed to create file cache.`（mpv 在磁盘上建缓存文件失败）。对串流来说
/// 内存缓存就够，磁盘缓存只多一个失败点。
library;

/// 网络读超时（秒）。给足「等分片」的余量；不是播放器自己的缓冲上限。
const int kMpvNetworkTimeoutSeconds = 60;

/// 要在**打开文件之前**下发的设置（`set <option> <value>`）。
///
/// 返回 `List<List<String>>` 而不是一条拼好的字符串：每一步都能进单测，
/// 也方便调用方逐条 `runMpvCommand` 记日志。
List<List<String>> mpvStreamTuningCommands() => <List<String>>[
      <String>['set', 'network-timeout', '$kMpvNetworkTimeoutSeconds'],
      <String>['set', 'cache-on-disk', 'no'],
    ];
