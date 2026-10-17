/// 种子块的「版本判定」（第四十八轮·补六）：这一条种子属于**哪一版**。
///
/// 用户原话（补六）：
/// > 「详细页会搜到其他版本的，比如第二季 剧场版 番外等等，应该怎么解决好」
///
/// 为什么必须判：番名阶梯为了"能搜到"，最后一档一定退到**基础名**（`dropSeasonSuffix`）。
/// 实测（`build/round48c/uw_*.txt`）：
/// * `無職転生 ～異世界行ったら本気だす～ 第2クール` 这个官方名去 mikan 搜是 **0 条**；
/// * 退到基础名 `无职转生 ～到了异世界就拿出真本事～` 一搜 = **1666 条**（S1 / S1后半 / S2 /
///   S2后半 / S3 全混在一起）；
/// * 而回来之后只过一道 [seedTitleMentions]（"标题里有没有这个名字"），没有"这是哪一版"。
///
/// 所以这里补一层：把**本条目**和**每条种子标题**都解成一个 [SeedVersion]（形态 / 季 / 部），
/// 比签名，而不是拿关键词黑名单去删 —— 删不准，也删不回来（判错的那些由界面收在
/// 「其他版本」里，见 `library_seed_block.dart` 的 `_otherVersions`）。
///
/// 判定顺序（从确定到猜）：
/// 1. **形态冲突**：TV 页面上出现「剧场版 / OVA / 番外」；反过来剧场版页面上出现带季号的 TV 行
///    ⇒ 别的版本；
/// 2. **最终季**：「最终季 / Final Season / 完結編」与本条目不一致 ⇒ 别的版本；
/// 3. **季号冲突**：两边都解出来且不等 ⇒ 别的版本（`第二季` vs `第三季`）；
/// 4. **标题里没有任何决定性标记** ⇒ 看**放送时间窗**（早于放送前 8 个月 / 晚于播完后 2 年
///    ⇒ 别的版本）—— 这一层专门抓"老季没标季号"的条目；
/// 5. 判不出来 ⇒ **算本作**（宁多勿少；别的版本区随时翻得到）。
///
/// ⚠️ 两条钉死的取舍：
/// * **「第N部分 / 第Nクール / 后半」不算另一个版本**：Bangumi 把 S2 前半/后半拆成两个条目，
///   但下载时它就是同一季的后半（用户要的是整季）——所以「部」只解出来、不参与排除；
/// * **「第Nクール」不能当季号**：S1 后半的官方名是 `無職転生 … 第2クール`（**没有 Ⅱ**）。
///   当成季 2 的话，它在 S1 的页面上会被判成"第二季"。
///
/// ── 第四十八轮·补七 / 补八：分页上只留「合集」一页 ─────────────────────────────
/// 补七用户原话：「在字幕组上面加入分页，把合集分进去」；补八又补一句
/// 「只给合集最分页，其他的不要」——所以组名列表**上面**那一排分页只有 `本作 / 合集`：
/// **本作里的合集**（整季一次发的批量种，[isSeedBatch]）从本作里切出去单独一页；
/// 判成别的版本的条目**不做页**，仍回到结果下面那行「其他版本（N 条）」折区
/// （补六的形态，一条不丢）。界面在 `library_seed_block.dart` 的
/// `_categoryTabs` / `_otherVersions`。
///
/// 补八同一条用户消息还问：「为什么会有第五季，命运石之门没有第五季」——
/// 根因是 [parseSeedVersion] 的罗马数字季号规则把 `[V2]`（发布者的"修正版第 2 版"标签）
/// 当成了 Ⅴ = 第五季。现在罗马数字两侧都不许挨着数字；实测
/// `build/round48c/sg_titles.txt` 的 841 条真标题里正好 6 条这种
/// （修前 6 条落进「第五季」，修后 0 条）。
///
/// ── 第五十四轮：Code Geass 的 `R2` 就是第二季 ─────────────────────────────────
/// 用户原话：「详细页的 CodeGeass 反叛的鲁路修，依旧会把第二季当第一季」。
/// 根因：Code Geass 第二季在发布标题里几乎只写 `R2`（`[反叛的鲁路修][R2][12]`、
/// `[Code_Geass_反叛的鲁路修_R2]`、`Lelouch of the Rebellion R2`），旧词表里没有这个
/// 写法，于是第二季的单集/合集在 S1 页面上全部落进「本作」—— 直接当第一季显示。
/// 真标题取证（`build/round54/titles.tsv`：DMHY 两个分区 + mikan 搜索页真抓，
/// 回放探针 `test/round54_cg_probe.dart`）：S1 页面 45 条里有 **6 条 R2** 在「本作」
/// （含 R2 的 11/15/16/18 话与两条 `01-25` 合集）。现在 [parseSeedVersion] 把 `R2`
/// 解成季 2（见 `_kSeasonR2`）：S1 页面把它们收进「其他版本 / 第二季」；R2 页面
/// **自己**的签名也从「季 1」变成「季 2」（否则它页面上的 2nd Season 会被判成别的版本）。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'library_seed.dart' show SeedGroup, groupSeedItems;
import 'models.dart' show SourceItemView;

// ─────────────────────────────────────────────────────────────────────────────
// 签名
// ─────────────────────────────────────────────────────────────────────────────

/// 放送形态。种子侧只能从标题里的词看出来（`TV` 看不出来 —— 没标形态的按"不知道"算）。
enum SeedForm {
  unknown,
  tv,
  movie,
  ova,
  sp,
}

/// 一条标题 / 一个条目的「版本签名」。
@immutable
class SeedVersion {
  const SeedVersion({
    this.form = SeedForm.unknown,
    this.season,
    this.part,
    this.finalSeason = false,
    this.seasonConflict = false,
  });

  /// 形态（剧场版 / OVA / 番外…；没标就是 [SeedForm.unknown]）。
  final SeedForm form;

  /// 季号（`第二季` / `第2期` / `Season 2` / `S3` / `Ⅱ` / `3期`）。
  final int? season;

  /// 部 / クール（`第2部分` / `第2クール` / `Part 2` / `后半`）。**不参与排除**，只做签名。
  final int? part;

  /// 最终季（`最终季` / `Final Season` / `完結編`）。
  final bool finalSeason;

  /// 同一标题里出现了互相矛盾的季号（`第二季 … 第三季`）= 多半是跨季合集。
  final bool seasonConflict;

  bool get isEmpty =>
      form == SeedForm.unknown &&
      season == null &&
      part == null &&
      !finalSeason &&
      !seasonConflict;
}

/// 本条目的签名 + 时间窗要用的两样东西。
@immutable
class SeedSubjectSignature {
  const SeedSubjectSignature({required this.version, this.date, this.eps});

  final SeedVersion version;

  /// 放送开始（`YYYY-MM-DD`；可能没有）。
  final DateTime? date;

  /// 话数（时间窗用它算"播完"；没有就按 12 话估）。
  final int? eps;
}

/// 从一条条目的字段拼出它的版本签名。
///
/// [names] 按"优先级从高到低"给（中文名 → 原名 → 别名），逐个解，先解出来的那个算数。
/// [platform] 是 Bangumi 的放送形态（`TV` / `剧场版` / `OVA` / `WEB`），它比名字里的词可靠。
SeedSubjectSignature seedSignatureOf({
  required Iterable<String> names,
  String? platform,
  String? date,
  int? eps,
}) {
  final SeedForm platformForm = _formOfPlatform(platform);
  SeedForm form = platformForm;
  int? season;
  int? part;
  bool finalSeason = false;
  for (final String raw in names) {
    final SeedVersion v = parseSeedVersion(raw);
    if (form == SeedForm.unknown && v.form != SeedForm.unknown) form = v.form;
    if (season == null && v.season != null) season = v.season;
    if (part == null && v.part != null) part = v.part;
    if (v.finalSeason) finalSeason = true;
  }
  // 名字里没有季号时：TV 按第一季算（保守）。
  // ⚠️ 只有 platform 明确是 TV/WEB 才这么默认 —— 形态都不知道时别乱假设，
  // 否则"别名/剧场版"那些条目会被无端判成"第二季"。
  if (season == null && form == SeedForm.tv) season = 1;
  return SeedSubjectSignature(
    version: SeedVersion(
      form: form,
      season: season,
      part: part,
      finalSeason: finalSeason,
    ),
    date: _parseDate(date),
    eps: eps,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// 判定
// ─────────────────────────────────────────────────────────────────────────────

/// 判定结果：本作 / 别的版本（带一个给人看的标签，如「第三季」「剧场版」「更早的版本（2021）」）。
@immutable
class SeedVersionVerdict {
  const SeedVersionVerdict.current()
      : other = false,
        label = null;

  const SeedVersionVerdict.other(String this.label) : other = true;

  final bool other;

  /// 只有 [other] 时有值：这一桶叫什么。
  final String? label;
}

/// 这一条种子属于本作吗。
SeedVersionVerdict judgeSeedVersion({
  required String title,
  required DateTime? publishedAt,
  required SeedSubjectSignature subject,
}) {
  final SeedVersion item = parseSeedVersion(title);
  final SeedVersion own = subject.version;

  // ① 形态冲突（TV 页面上出现剧场版 / OVA / 番外；或者反过来）。
  if (item.form != SeedForm.unknown &&
      own.form != SeedForm.unknown &&
      item.form != own.form) {
    return SeedVersionVerdict.other(_formLabel(item.form));
  }
  // ①b 本作不是 TV（剧场版 / OVA），却来了一条带季号的没标形态的行 ⇒ 那是 TV 版。
  if (own.form != SeedForm.unknown &&
      own.form != SeedForm.tv &&
      item.form == SeedForm.unknown &&
      (item.season != null || item.finalSeason)) {
    return const SeedVersionVerdict.other('TV 版');
  }

  // ② 最终季。
  if (item.finalSeason && !own.finalSeason) {
    return const SeedVersionVerdict.other('最终季');
  }
  if (own.finalSeason && item.season != null && !item.finalSeason) {
    return SeedVersionVerdict.other(_seasonLabel(item.season!));
  }

  // ③ 季号冲突。⚠️「部 / クール」在这里**不算冲突**（见文件头那两条取舍）。
  if (item.seasonConflict) return const SeedVersionVerdict.other('多季合集');
  if (item.season != null && own.season != null && item.season != own.season) {
    return SeedVersionVerdict.other(_seasonLabel(item.season!));
  }

  // ④ 标题里没有任何决定性标记 ⇒ 放送时间窗（抓"老季没标季号"的那些）。
  final bool decisive =
      item.form != SeedForm.unknown || item.season != null || item.finalSeason;
  if (!decisive) {
    final String? beyond = _timeWindowVerdict(publishedAt, subject);
    if (beyond != null) return SeedVersionVerdict.other(beyond);
  }
  return const SeedVersionVerdict.current();
}

/// 标题没有任何版本标记时，按发布时间猜它是不是"别的一季"。
///
/// 窗口：放送开始前 8 个月 → 播完（`eps`×7 天，至少 13 周）+ 2 年。
/// 前一条抓"上一季"（它的行发布时间远早于本季）；后一条抓"好几季之前的行 / 旧合集"。
/// ⚠️ 这是**猜**：窗口外判错的那些会进「其他版本」区（不丢，翻得到），窗口内一律算本作。
///
/// 标签**不带年份**：同一季的行可能跨好几个年头（正片 + 后来的 BDRip），
/// 带上年份会把"第一季"拆成「更早的版本（2021）」「更早的版本（2022）」两个桶；
/// 年份改由 [SeedOtherBlock.hint] 显示成区间。
String? _timeWindowVerdict(
  DateTime? publishedAt,
  SeedSubjectSignature subject,
) {
  final DateTime? start = subject.date;
  if (start == null || publishedAt == null) return null;
  final DateTime at = publishedAt.toUtc();
  final DateTime startUtc = start.toUtc();
  final DateTime early = startUtc.subtract(const Duration(days: 240));
  final int eps = subject.eps ?? 12;
  final DateTime late = startUtc.add(
    Duration(days: math.max(eps, 13) * 7 + 730),
  );
  if (at.isBefore(early)) return kEarlierVersionLabel;
  if (at.isAfter(late)) return kLaterVersionLabel;
  return null;
}

/// 时间窗判出来的两个桶名（界面 + 用例都用这两个常量）。
const String kEarlierVersionLabel = '更早的版本';
const String kLaterVersionLabel = '更晚的版本';

// ─────────────────────────────────────────────────────────────────────────────
// 整池分开
// ─────────────────────────────────────────────────────────────────────────────

/// 时间窗那两桶的年份区间（`2021` / `2021–2022`）；别的桶不给。
///
/// 为什么单独算：同一季的行会跨年头（正片在 2021、后来的 BDRip 在 2022），
/// 按"年份"进标签会把它拆成两个桶 —— 桶名固定、年份只当补充说明。
String? _yearsHint(String label, List<SourceItemView> items) {
  if (label != kEarlierVersionLabel && label != kLaterVersionLabel) return null;
  final List<int> years = <int>[
    for (final SourceItemView item in items)
      if (item.publishedAt != null) item.publishedAt!.toUtc().year,
  ]..sort();
  if (years.isEmpty) return null;
  final int first = years.first;
  final int last = years.last;
  return first == last ? '$first' : '$first–$last';
}

/// 「其他版本」里的一桶（一个标签 + 这一桶的条目 + 分好的字幕组段）。
@immutable
class SeedOtherBlock {
  const SeedOtherBlock({
    required this.label,
    required this.items,
    required this.groups,
    this.hint,
  });

  /// 给人看的版本名（`第三季` / `剧场版` / `更早的版本` …）。
  final String label;

  /// 补充说明。现在只有时间窗那两桶用：`2021` 或 `2021–2022`（同一季的行会跨年头）。
  final String? hint;

  /// 这一桶的条目（新→旧，与池子同序）。
  final List<SourceItemView> items;

  /// 这一桶按字幕组分好的段（界面按它画，和本作区一样的形状）。
  final List<SeedGroup> groups;

  int get count => items.length;
}

/// 分开之后的两半。
@immutable
class SeedVersionSplit {
  const SeedVersionSplit({
    required this.current,
    required this.others,
    this.batch = const <SourceItemView>[],
  });

  /// 本作**单集**那些条目（**已经**是原来那个顺序）。
  final List<SourceItemView> current;

  /// 本作里的**合集**（整季/整部一次发的批量种）—— 界面上单独一页（第四十八轮·补七）。
  final List<SourceItemView> batch;

  /// 别的版本（按条数从多到少）。
  final List<SeedOtherBlock> others;

  int get otherCount {
    int total = 0;
    for (final SeedOtherBlock block in others) {
      total += block.count;
    }
    return total;
  }
}

/// 「合集」那一页的页名（界面 + 用例共用）。
const String kSeedBatchLabel = '合集';

/// 把一池子条目分成"本作单集 / 本作合集 / 别的版本"。
///
/// ⚠️ 兜底：**如果一条都不剩本作，就不分了**（整池原样当本作）—— 判错方向宁可"多给"，
/// 也不能让用户打开这一页看见个空列表。
///
/// 合集再单独切一层（第四十八轮·补七，用户「在字幕组上面加入分页，把合集分进去」）：
/// 整季一次发的批量种混在单集里，会让「这一组都入队」把一整季当一个文件下、也让单集列表
/// 被几条全集顶长。切出去之后「合集」是分页条上的一页 —— **不丢**，翻得到、也下得动。
/// ⚠️ 同样兜底：本作单集一条都不剩时，合集并回本作（不许出现空的第一页）。
SeedVersionSplit splitSeedVersions(
  List<SourceItemView> items,
  SeedSubjectSignature subject,
) {
  if (items.isEmpty) {
    return SeedVersionSplit(
      current: items,
      others: const <SeedOtherBlock>[],
    );
  }
  final List<SourceItemView> current = <SourceItemView>[];
  final Map<String, List<SourceItemView>> buckets =
      <String, List<SourceItemView>>{};
  for (final SourceItemView item in items) {
    final SeedVersionVerdict verdict = judgeSeedVersion(
      title: item.title ?? '',
      publishedAt: item.publishedAt,
      subject: subject,
    );
    if (verdict.other) {
      (buckets[verdict.label!] ??= <SourceItemView>[]).add(item);
    } else {
      current.add(item);
    }
  }
  if (current.isEmpty) {
    return SeedVersionSplit(
      current: items,
      others: const <SeedOtherBlock>[],
    );
  }
  // 本作里再分出"合集"。
  final List<SourceItemView> plain = <SourceItemView>[];
  final List<SourceItemView> batch = <SourceItemView>[];
  for (final SourceItemView item in current) {
    (isSeedBatch(item.title ?? '') ? batch : plain).add(item);
  }
  if (plain.isEmpty) batch.clear();
  if (plain.isEmpty) plain.addAll(current);
  final List<SeedOtherBlock> others = <SeedOtherBlock>[
    for (final MapEntry<String, List<SourceItemView>> e in buckets.entries)
      SeedOtherBlock(
        label: e.key,
        hint: _yearsHint(e.key, e.value),
        items: List<SourceItemView>.unmodifiable(e.value),
        groups: groupSeedItems(e.value),
      ),
  ]..sort((SeedOtherBlock a, SeedOtherBlock b) {
    // 先按条数（多的在前）；平手按标签（`List.sort` 不保证稳定，不写第二键会出现
    // "同一批数据两次跑出不同顺序"）。
    final int byCount = b.count.compareTo(a.count);
    return byCount != 0 ? byCount : a.label.compareTo(b.label);
  });
  return SeedVersionSplit(
    current: List<SourceItemView>.unmodifiable(plain),
    batch: List<SourceItemView>.unmodifiable(
      plain.isEmpty ? const <SourceItemView>[] : batch,
    ),
    others: List<SeedOtherBlock>.unmodifiable(others),
  );
}

/// 这一条标题是不是**合集**（整季/整部一次发的批量种）。
///
/// 判据（都有真标题作证，见 `build/round48c/uw_titles_833.txt`）：
/// * 明说：`合集` / `全集` / `合辑` / `全话` / `batch`（`[01-14 合集]`、`[00-24TV全集+特典映像]`；
/// * 集号区间：`[01-26]`、`[12-23]` 这种一行就是一季的（`[VCB-Studio] … [01-12][BDRip]`）——
///   单集不会有区间；
/// * **BD 整季**：标了 `BDRip / BDMV / BD-box / 蓝光` 但标题里**没有集号**
///   （`[H-Enc] … (BDRip 1080p HEVC FLAC)`、`[VCB-Studio] … BDRip [S2 Fin]`）；
///   单集的 BDRip 一定带集号（`- 05` / `[05]` / `第5话`），所以这条不会误伤。
///
/// ⚠️ 只认"区间在方括号里、数字 1~3 位"：`[1080p]`、`[HEVC-10bit]`、`[简日双语内嵌]` 都不会命中。
bool isSeedBatch(String title) {
  if (title.trim().isEmpty) return false;
  final String text = _halfWidth(title);
  final String lower = text.toLowerCase();
  if (_kBatchWords.hasMatch(lower)) return true;
  if (_kEpisodeRange.hasMatch(text)) return true;
  if (_kDiscBatchWords.hasMatch(lower) && !_kEpisodeNumber.hasMatch(text)) {
    return true;
  }
  return false;
}

/// 合集词表（小写文本上匹配）。
final RegExp _kBatchWords = RegExp(
  r'合集|全集|合辑|合輯|全話|全话|全劇|全剧|batch|全\s*[0-9]{1,3}\s*[话話集]',
);

/// 方括号里的集号区间：`[01-26]` / `[1~12]`。
final RegExp _kEpisodeRange = RegExp(
  r'\[\s*[0-9]{1,3}\s*[-~–—]\s*[0-9]{1,3}\s*\]',
);

/// 整季盘的标记（`BDRip` / `BDMV` / `BD-box` / 蓝光）—— 要配合"没有集号"才当合集。
final RegExp _kDiscBatchWords = RegExp(
  r'bdr|bdmv|bd[\s_-]?box|blu-ray|蓝光|藍光',
);

/// 标题里"这一行是第几集"的痕迹：`- 05` / `[05]` / `第5话`。
final RegExp _kEpisodeNumber = RegExp(
  r'[-–—]\s*[0-9]{1,3}(?![0-9])|\[\s*[0-9]{1,3}\s*\]|第\s*[0-9]{1,3}\s*[话話集]',
);

// ─────────────────────────────────────────────────────────────────────────────
// 解析（词表）
// ─────────────────────────────────────────────────────────────────────────────

/// 解一条标题的版本签名（不知道的字段留 null / [SeedForm.unknown]）。
///
/// 整条标题都要扫：实测同一条里可能同时有中文名与日文名
/// （`无职转生 第三季 ～…～ / Mushoku Tensei S3`），也可能季号写在**副标题后面**
/// （`无职转生～到了异世界就拿出真本事～ 第二季`）。
SeedVersion parseSeedVersion(String title) {
  final String text = _halfWidth(title);
  final String lower = text.toLowerCase();

  // 形态：movie > ova > sp（同一条里出现多个标记时按"最重"的算）。
  final SeedForm form = _kMovie.hasMatch(lower)
      ? SeedForm.movie
      : _kOva.hasMatch(lower)
      ? SeedForm.ova
      : _kSp.hasMatch(lower)
      ? SeedForm.sp
      : SeedForm.unknown;

  // 季号：中文「第二季/第2期/3期」、英文「Season 2/2nd Season/S03」、
  // 罗马数字「Ⅱ / III」（日文名常见：`無職転生Ⅲ ～…～`）、
  // Code Geass 系的「R2」（第五十四轮补，见 `_kSeasonR2`）。
  final Set<int> seasons = <int>{};
  for (final Match m in _kSeasonZh.allMatches(lower)) {
    _addNum(seasons, _num(m.group(1)));
  }
  for (final Match m in _kSeasonBarePeriod.allMatches(lower)) {
    _addNum(seasons, _num(m.group(1)));
  }
  for (final Match m in _kSeasonEn.allMatches(lower)) {
    _addNum(seasons, _num(m.group(1)));
  }
  for (final Match m in _kSeasonOrdinal.allMatches(lower)) {
    _addNum(seasons, _num(m.group(1)));
  }
  if (_kSeasonR2.hasMatch(lower)) _addNum(seasons, 2);
  for (final Match m in _kRoman.allMatches(text)) {
    _addNum(seasons, _romanValue(m.group(1)));
  }
  for (final Match m in _kFullWidthRoman.allMatches(text)) {
    _addNum(seasons, _fullWidthRomanValue(m.group(0)!));
  }

  // 部 / クール：「第2部分」「第2クール」「Part 2」「后半」。
  // ⚠️ 只记进签名，**不参与排除**（见文件头）。
  final Set<int> parts = <int>{};
  for (final Match m in _kPartZh.allMatches(lower)) {
    _addNum(parts, _num(m.group(1)));
  }
  for (final Match m in _kPartEn.allMatches(lower)) {
    _addNum(parts, _num(m.group(1)));
  }
  if (_kSecondHalf.hasMatch(lower)) parts.add(2);
  if (_kFirstHalf.hasMatch(lower)) parts.add(1);

  return SeedVersion(
    form: form,
    season: seasons.length == 1 ? seasons.first : null,
    part: parts.length == 1 ? parts.first : null,
    finalSeason: _kFinalSeason.hasMatch(lower),
    seasonConflict: seasons.length > 1,
  );
}

void _addNum(Set<int> into, int? value) {
  if (value != null && value > 0 && value <= 99) into.add(value);
}

// ── 词表（一条一条都有真实标题作证：`build/round48c/uw_mikan_versions.txt`）──

final RegExp _kSeasonZh = RegExp(
  r'第\s*([0-9]{1,2}|[一二三四五六七八九十]+)\s*(?:季|期|シーズン)',
);
// 「3期」这种不带「第」的写法（实测：`[LoliHouse] 无职转生 3期 / Mushoku Tensei S3`）。
// ⚠️ 故意不含「クール」—— 那是"部"不是"季"。
final RegExp _kSeasonBarePeriod = RegExp(
  r'(?<![0-9a-z])([0-9]{1,2}|[一二三四五六七八九十]+)\s*(?:季|期)',
);
final RegExp _kSeasonEn = RegExp(
  r'(?<![a-z])(?:season|s)\s*0?([0-9]{1,2})(?![0-9])',
);
final RegExp _kSeasonOrdinal = RegExp(r'([0-9]{1,2})\s*(?:st|nd|rd|th)\s+season');

/// `R2` = 第二季（Code Geass 的专用季号写法，第五十四轮补）。
///
/// 为什么必须单列：Code Geass 第二季在真标题里几乎只写 `R2` ——
/// `[WLGO][Code Geass R2 反叛的鲁路修 R2][BIG5][RMVB]`、
/// `[WLGO][反叛的鲁路修][R2][12][TW繁體][TVRIP][MP4]`、
/// `[Code_Geass_反叛的鲁路修_R2][BIG5][18][RMVB]`、
/// `Lelouch of the Rebellion R2 [01-25][Baha][WEB-DL]` —— 一条「第二季 / 2nd Season / Ⅱ」
/// 都没有，旧词表一条也解不出，于是它们全落进 S1 页面的「本作」（用户报障）。
/// 实测 `build/round54/titles.tsv` 的 160 条真标题里 **67 条**带独立 `R2`，
/// 全部是 `R2]` / `R2[` / ` R2 ` / `_R2]` 这几种边界。
///
/// 边界与 `[V2]` 同理：两侧都不许挨着字母/数字 —— `R2J`（R2 日版 DVD 源）/ `R2DVD` /
/// `R2D2` 不是季号；**后面紧跟 `-` 的也不算**（留给 `R2-Raws` 这类组名；
/// 真标题里 `R2` 后面只会是空格、`]`、`[`）。
final RegExp _kSeasonR2 = RegExp(r'(?<![a-z0-9])r2(?![a-z0-9-])');

final RegExp _kPartZh = RegExp(
  r'第\s*([0-9]{1,2}|[一二三四五六七八九十]+)\s*(?:部分|クール)',
);
final RegExp _kPartEn = RegExp(r'(?<![a-z])(?:part|cour)\s*([0-9]{1,2})(?![0-9])');
final RegExp _kFirstHalf = RegExp(r'前半|前篇');
final RegExp _kSecondHalf = RegExp(r'后半|後半|下半|後編|后篇');
final RegExp _kFinalSeason = RegExp(
  r'最终季|最終季|final\s+season|完結編|完结编|完结篇|終章|终章',
);
final RegExp _kMovie = RegExp(r'剧场版|劇場版|映画|(?<![a-z])the\s+movie(?![a-z])|(?<![a-z])movie(?![a-z])');
final RegExp _kOva = RegExp(r'(?<![a-z])ova(?![a-z])|(?<![a-z])oad(?![a-z])');
final RegExp _kSp = RegExp(
  r'特别篇|特別篇|特别编|特別編|番外|外传|外傳|总集篇|總集篇|総集編|回忆篇|recap',
);
// 罗马数字：只认 II 以上（单独的 `I` 太容易撞英文里的 "I"），长写在前。
// ⚠️ 两侧都**不许挨着数字**：`[V2]` / `[02V2]` / `[V3]` 是发布者的"修正版第 N 版"标签，
// 不是「第五季」—— 实测 `命运石之门` 841 条真标题里 6 条带 `V2`，旧规则把它们全推进
// 「第五季」（用户原话：「命运石之门没有第五季」）。真季号不会写成 `V2` 这种。
final RegExp _kRoman = RegExp(
  r'(?<![A-Za-z0-9])(VIII|VII|III|IX|IV|VI|II|V)(?![A-Za-z0-9])',
);
final RegExp _kFullWidthRoman = RegExp(r'[ⅡⅢⅣⅤⅥⅦⅧⅨⅩ]');

const Map<String, int> _kRomanValues = <String, int>{
  'II': 2,
  'III': 3,
  'IV': 4,
  'V': 5,
  'VI': 6,
  'VII': 7,
  'VIII': 8,
  'IX': 9,
};

int? _romanValue(String? raw) => _kRomanValues[(raw ?? '').trim()];

int? _fullWidthRomanValue(String raw) {
  const List<String> all = <String>['Ⅱ', 'Ⅲ', 'Ⅳ', 'Ⅴ', 'Ⅵ', 'Ⅶ', 'Ⅷ', 'Ⅸ', 'Ⅹ'];
  final int at = all.indexOf(raw);
  return at < 0 ? null : at + 2;
}

/// `第二季` / `2` / `十一` → int（认不出来就 null）。
int? _num(String? raw) {
  final String text = (raw ?? '').trim();
  if (text.isEmpty) return null;
  final int? digit = int.tryParse(text);
  if (digit != null) return digit;
  const Map<String, int> zh = <String, int>{
    '一': 1,
    '二': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
    '十': 10,
  };
  if (zh.containsKey(text)) return zh[text];
  // 十一 / 十二 / 二十 这类组合（少见，但别解错）。
  if (text.startsWith('十')) {
    final int? rest = zh[text.substring(1)];
    return rest == null ? null : 10 + rest;
  }
  if (text.endsWith('十')) {
    final int? lead = zh[text.substring(0, text.length - 1)];
    return lead == null ? null : lead * 10;
  }
  return null;
}

String _seasonLabel(int n) {
  const List<String> zh = <String>[
    '零', '一', '二', '三', '四', '五', '六', '七', '八', '九',
  ];
  if (n >= 1 && n <= 10) return '第${zh[n]}季';
  return '第$n季';
}

String _formLabel(SeedForm form) => switch (form) {
  SeedForm.movie => '剧场版',
  SeedForm.ova => 'OVA',
  SeedForm.sp => '番外 / 特别篇',
  SeedForm.tv => 'TV 版',
  SeedForm.unknown => '别的版本',
};

SeedForm _formOfPlatform(String? raw) {
  final String text = (raw ?? '').trim();
  if (text.isEmpty) return SeedForm.unknown;
  final String lower = text.toLowerCase();
  if (lower == 'tv' || lower == 'web' || text.contains('TV') || text.contains('WEB')) {
    return SeedForm.tv;
  }
  if (text.contains('剧场')) return SeedForm.movie;
  if (lower.contains('ova') || lower.contains('oad')) return SeedForm.ova;
  return SeedForm.unknown;
}

DateTime? _parseDate(String? raw) {
  final String text = (raw ?? '').trim();
  if (text.length < 10) return null;
  return DateTime.tryParse(text.substring(0, 10));
}

/// 全角 → 半角（ASCII 段 + 全角空格）。
///
/// ⚠️ 与 `library_seed.dart` 里那份是同一件事的第二个副本 —— 刻意重复：那边做的是
/// "标题归一化"（剥括号、砍集号），这边要保留原文只统一书写宽度；共用一个字符映射
/// 会把两个领域的意图绑在一起（`subtitle_groups.dart` 里还有第三个副本，同理）。
String _halfWidth(String text) {
  final StringBuffer out = StringBuffer();
  for (final int rune in text.runes) {
    if (rune == 0x3000) {
      out.write(' ');
    } else if (rune >= 0xFF01 && rune <= 0xFF5E) {
      out.writeCharCode(rune - 0xFEE0);
    } else {
      out.writeCharCode(rune);
    }
  }
  return out.toString();
}
