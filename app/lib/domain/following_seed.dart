/// 「正在追」点开层（订阅详细页）里那块「种子」的**主体**（第四十九轮）。
///
/// 用户原话（第四十九轮）：
/// > 「优化下订阅，详细页订阅的也带有种子」
///
/// 也就是：从「正在追」点开一部番时，除了订阅字幕组的 RSS 剧集，也要能像「动漫库详细页」
/// 那样直接看全站种子（按字幕组分段、合集单独一页、别的版本折在底部、语言过滤）。
///
/// 种子块（`ui/widgets/library_seed_block.dart`）内部只认 [BangumiSubject]：
/// * 搜什么词 —— `librarySeedQueries` 的「中文名 → 原名 → 别名 → 短名」阶梯；
/// * 怎么判版本 —— `seedSignatureOf` 要的 `platform` / `date` / `eps`；
/// * 状态与手动锚点按什么键存 —— `LibrarySeedState.subjectId`、`LibrarySeedService` 的落盘键。
///
/// 而一条追番记录（[FollowingEntry]）**不一定是** Bangumi 条目：从主页海报卡追的只有
/// mikan 番剧 id 与番名。所以这里造一条**最小**的主体 —— 不联网、不猜：
/// 缺 `date` / `eps` 只是让版本判定少一条"放送时间窗"（宁多勿少，不丢条目），
/// 缺别名就只按番名那一级搜（换词能力仍在种子块的「改搜索词」里）。
library;

import 'bangumi.dart';
import 'following_store.dart';

/// 「只有番名」的那一段 id 的地基：`-(1 << 30)` 以下（见 [seedSubjectIdFromFollowing]）。
const int _kTitleBandBase = 1 << 30;

/// mikan 番剧 id 那一段的上限：超过它就当作"没有可用 id"，退回标题哈希。
///
/// mikan 的番剧 id 是四位数上下（实测 2xx–4xxx）；留到 2^30 是"够用且不会溢进标题段"。
const int _kMikanBandLimit = 1 << 30;

/// 追番记录对应的**种子块主体 id**（稳定：重启后仍指向同一部）。
///
/// 三条规则（真实 Bangumi 条目 id 恒为正，所以负数段永不与它相撞）：
/// * Bangumi 来的记录（`bgmId`）→ **直接用 Bangumi 条目 id**：和「动漫库详细页」共用同一份
///   种子状态与同一个手动锚点 —— 同一部番不该因为从哪个入口点进来就重搜一遍；
/// * 只有 mikan 番剧 id（主页海报卡进来的）→ `-(id + 1)`（落在 `[-10^9, -1]`）：
///   重启后还是同一个数，所以用户粘过的 mikan 番剧页也还记着；
/// * 只有番名（搜索页 / 别处追的）→ `-(1 << 30) - (FNV-1a 32 位 & 0x3FFFFFFF)`：
///   落在 `[-2^31, -2^30-1]`，与上面那一段分开，**同一个追番 id 每次都算出同一个数**。
int seedSubjectIdFromFollowing(FollowingEntry entry) {
  final int? bgm = entry.bgmId;
  if (bgm != null && bgm > 0) return bgm;
  final int? mikanId = int.tryParse((entry.mikanBangumiId ?? '').trim());
  if (mikanId != null && mikanId > 0 && mikanId < _kMikanBandLimit) {
    return -(mikanId + 1);
  }
  return -_kTitleBandBase - (_fnv1a32(entry.id) & 0x3FFFFFFF);
}

/// 追番记录 → 种子块的主体（最小形态；字段为什么这么填见本文件头部）。
///
/// * `nameCn` = 番名（种子块显示标题、第一级搜索词都用它）；
/// * `name` = 英文/原名（追番记录里有且**跟番名不一样**时才给 —— 第二级搜索词）；
/// * `date` / `eps` 有就带（版本判定的时间窗与话数），没有就不猜；
/// * `coverUrl` 跟着带：种子块里点播时播放窗口与观看记录用它。
BangumiSubject seedSubjectFromFollowing(FollowingEntry entry) {
  final String title = entry.title.trim();
  final String en = (entry.titleEn ?? '').trim();
  final String date = (entry.airDate ?? '').trim();
  return BangumiSubject(
    id: seedSubjectIdFromFollowing(entry),
    nameCn: title.isEmpty ? null : title,
    // 英文名与番名一样时不重复占一个搜索阶梯（`librarySeedQueries` 会去重，但这里更省事）。
    name: en.isEmpty || en == title ? null : en,
    date: date.isEmpty ? null : date,
    eps: entry.totalEpisodes,
    coverUrl: entry.coverUrl,
  );
}

/// FNV-1a 32 位（只用来把"只有番名的追番 id"稳定地折进负数段；不是加密哈希）。
int _fnv1a32(String text) {
  int hash = 0x811C9DC5;
  for (final int unit in text.codeUnits) {
    hash ^= unit;
    // Dart 的 int 是 64 位：每步都截回 32 位，结果才与平台/宽度无关。
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}
