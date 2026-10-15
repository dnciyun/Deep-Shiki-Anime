/// 队列行的**文案**（没有引擎快照时那两处）：进度列 + 引擎侧胶囊。
///
/// 为什么单独放一个纯函数文件（用户 2026-10-12 第二十三轮）：
/// 旧实现把「引擎里已经没有这个任务」直接挂在 `engineId == null` 上，而
/// `engineId` 为空**不等于**引擎里没有这条任务 —— 它还有两个完全正常的窗口：
///
/// * `queued`：并发上限满了，还没轮到它（用户连点下载时最先生成的那一批都在这里）；
/// * `downloading` 且 `engineId == null`：`_doStart` 已经把状态改成「下载中」，但
///   `addMagnet` 还没回来 —— 磁力链的元数据是边车**在 HTTP 请求里同步等**的
///   （最长 `kDefaultMetadataRequestTimeout` = 130s），等不到才回 504。
///
/// 于是"连点下载"时用户看到的是一屏「引擎里已经没有这个任务」，而真相是"还在等"。
/// 文案按真实状态分档，判据只有 `job.state` + `engineId`，纯函数、可单测。
library;

import 'models.dart';

/// 没有引擎快照（`torrent == null`）时，进度列右边那行小字该说什么。
///
/// 只处理"引擎里读不到这条任务的进度"这一种情况：`engineId` 已经有值但快照里查不到
/// ⇒ 引擎连不上/快照还没到；`engineId` 还是空 ⇒ 按队列状态说它是"在排队"还是在"等元数据"。
String queueProgressText(QueueJobView job) {
  if (job.engineId != null) return '进度不可用';
  return switch (job.state) {
    JobState.queued => '排队中',
    JobState.downloading => '等元数据…',
    JobState.paused => '已暂停',
    JobState.completed => '已完成',
    JobState.failed => '失败',
    JobState.cancelled => '已取消',
  };
}

/// 没有引擎快照时，那颗胶囊的文案与色调。
///
/// `warn == true` 表示"这条要用户处理"（用警示色）；排队/等元数据只是过程，不该报警。
({String label, bool warn}) queueEngineChip(QueueJobView job) {
  // 引擎连不上（有 engineId，只是快照里没有它）：这不是队列的问题，别让用户去动任务。
  if (job.engineId != null) return (label: '引擎未连接：进度不可用', warn: true);
  return switch (job.state) {
    // 排队中：并发上限满了，前面还有任务 —— 旧文案在这里撒谎（第二十三轮报的 bug）。
    JobState.queued => (label: '排队等待中：还没轮到它', warn: false),
    // 正在交给引擎：磁力链等元数据，`engineId` 这时候本来就该是空的。
    JobState.downloading => (label: '正在把任务交给引擎…', warn: false),
    // 失败：原因就写在下面那一行「错误：…」，这里不要再说"引擎里没有它"
    //（它可能压根没进过引擎）。
    JobState.failed => (label: '没交给引擎（见下方错误）', warn: true),
    // 重启后引擎里确实没有它（第十九轮为这条遗留任务写的原句，保留）。
    JobState.paused || JobState.completed || JobState.cancelled => (
      label: '引擎里已经没有这个任务',
      warn: true,
    ),
  };
}
