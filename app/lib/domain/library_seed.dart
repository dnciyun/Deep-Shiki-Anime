/// 动漫库「种子」块的**领域**部分（第四十五轮起，第四十八轮换过引擎）。
///
/// 用户原话（第四十五轮）：「能实现动漫库中直接显示种子吗，就像主页那样」——主页卡片点
/// 进去那页（`ui/bangumi_detail.dart`）就是"按字幕组列剧集 + 每集磁力"，所以这里要复刻的
/// 是**那一页的数据**，不是它的版式。
///
/// ── 第四十八轮：引擎从「mikan 番剧页绑定」换成「主流站点关键字搜索」 ────────────────
/// 用户原话：
/// > 「我自己去 mikan 搜都搜索得到，这里就搜不到了，修复一下，然后改为主流搜索当引擎，
/// >   按字幕组分隔，不同搜索引擎同名字就按合并」
///
/// 为什么原来那条路必须退场（第四十八轮真机实测，`build/round48/`）：
/// mikan 的**搜索页是好的**（「命运石之门」一页 841 行、841 行都带磁力），坏的是**下一步**
/// ——宿主拿搜索行去**单集页**换番剧 id（`/Home/Bangumi/<id>`）。实测：
/// * 最新那几行是 `7³ACG` 用 API 直发的合集/剧场版，那些页面**根本没有番剧链接**；
/// * 抽样 28 行只有 **7 行**能绑上，而且那 7 行全是**另一部番**（「命运石之门 0」⇒ 番剧页
///   1610）—— 老版 TV 的每一集都绑不到番剧页。
/// 预算是 3 次详情，全烧在绑不上的最新行上 ⇒ 每部这样的番都报「mikan 上没找到」。
///
/// 所以这一轮：**引擎 = 主流站点的关键字搜索**（用户勾选的那些源，聚合搜番名），
/// 结果**按字幕组归组**、**跨站同名合并**（见 [groupSeedItems] / [mergeSeedDuplicates]）。
/// 番剧页那条路没有消失，但降级成**手动**的（粘 mikan 番剧页地址或 id，见
/// `LibrarySeedController.bindRaw`）—— 它有它的价值（一整部的完整剧集表 + 每组自己的
/// RSS 订阅），只是不该再当主力。
///
/// [librarySeedQueries] 那条"逐级退让"的阶梯仍然要：mikan 的搜索是**整串匹配、不分词**
/// （实测：`间谍过家家 第2部分` 与 `SPY×FAMILY 第2クール` 都是 0 行，靠别名
/// `SPY×FAMILY Part 2` 才有结果）。
library;

import 'package:flutter/foundation.dart';

import 'aggregate.dart' show richerItem;
import 'bangumi.dart' show BangumiSubject, BangumiInfoboxItem;
import 'models.dart';
import 'subtitle_groups.dart';

/// 一次解析最多试几个查询词（用户第四十五轮定的阶梯正好四级）。
const int kMaxLibrarySeedQueries = 4;

/// 种子块**不问**的源 id（第四十八轮·补，用户原话：「去除 acg.rip 源」）。
///
/// 为什么只在这一块里删、搜索页照旧留着它：ACG.RIP 全站**不提供 magnet**（见
/// `core/lib/sources/bencode.dart` 头部的实测），列表里给的是 `.torrent` 直链 —— 于是
/// 每一条都要**先多打一次请求**、把种子文件下回来算 infohash 才拿得到磁力。
/// 种子块是"进页面就自动搜一遍、一次问好几个站"，把它算进去等于多搭几条会超时的腿；
/// 搜索页是用户自己点着搜的，愿意等就留着（`host_data_test` 那套注册表一字没动）。
///
/// 判定按 id 白名单做减法，不按域名：自定义 RSS（`rss:<hash>`）是用户自己加的，
/// 哪怕它指向 acg.rip 也照问 —— 那一份勾选是用户的意图，不该被这里悄悄吃掉。
const Set<String> kSeedSkippedSourceIds = <String>{'acgrip', 'acgrip-batch'};

/// 番剧页结果的宿主侧缓存时长（第四十五轮用户选定「30 分钟」）。
///
/// 为什么必须自己缓存：`core` 的 `MikanSource.bangumi()` **不走缓存**（裸 `http.getText`），
/// 而它每次要下 400KB 左右、并且受同站 ≥1.2s 的限速约束 —— 反复进出同一部番会把自己
/// 限速住。搜索那一步走的是 core 的 300 秒搜索缓存，所以只有番剧页这一层需要宿主兜。
const Duration kLibrarySeedTtl = Duration(minutes: 30);

/// 「这一条 Bangumi 条目对应哪个 mikan 番剧页」——落盘记住的那份映射。
///
/// 为什么落盘：解析一次要打 2~5 次网络（搜索 → 单集详情 → 番剧页），而这条对应关系
/// 是**稳定**的（除非站点改名）。落盘之后第二次进这一部番直接命中缓存。
class MikanSeedBinding {
  const MikanSeedBinding({
    required this.bangumiId,
    required this.title,
    required this.query,
  });

  /// mikan 的数字番剧 id（`/Home/Bangumi/<id>` 里那个）。
  final String bangumiId;

  /// 绑定当时那一页的标题（用来给用户看"绑到的是哪一部"）。
  final String title;

  /// 当时用的是哪个查询词（进设置面板/手动改词时要显示"实际用的词"）。
  final String query;

  Map<String, Object?> toJson() => <String, Object?>{
    'bangumiId': bangumiId,
    'title': title,
    'query': query,
  };

  static MikanSeedBinding? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Map<Object?, Object?> map = raw.cast<Object?, Object?>();
    final String id = (map['bangumiId'] ?? '').toString().trim();
    if (id.isEmpty) return null;
    return MikanSeedBinding(
      bangumiId: id,
      title: (map['title'] ?? '').toString(),
      query: (map['query'] ?? '').toString(),
    );
  }
}

/// 从一条 Bangumi 条目能试的搜索词，**按命中率从高到低**（第四十五轮用户选定：
/// 「中文名 → 原名（日文）→ 罗马字/英文别名 → 去季/部后缀的短名」）。
///
/// 实测命中率（24 部番，mikan 搜索页能搜出结果的比例）：中文名 83% / 原名 71% /
/// 罗马字别名 80%。所以中文名永远第一位；`name_cn` 为空或等于原名时（实测占条目池的
/// 8%，且集中在"名字本来就是英文"的热门番）第七步开始就靠别名与短名。
List<String> librarySeedQueries(BangumiSubject subject) {
  final List<String> aliases = librarySeedAliases(subject);
  final List<String> latin = aliases.where(_looksLatin).toList(growable: false);
  final String? shortCn = dropSeasonSuffix(subject.nameCn);
  final String? shortName = dropSeasonSuffix(subject.name);

  final List<String> ordered = <String>[
    subject.nameCn ?? '',
    subject.name ?? '',
    ...latin,
    shortCn ?? '',
    shortName ?? '',
    ...aliases,
    ...latin.map((String a) => dropSeasonSuffix(a) ?? ''),
    ...aliases.map((String a) => dropSeasonSuffix(a) ?? ''),
  ];

  final List<String> out = <String>[];
  for (final String raw in ordered) {
    final String text = raw.trim();
    if (text.isEmpty || out.contains(text)) continue;
    out.add(text);
    if (out.length >= kMaxLibrarySeedQueries) break;
  }
  return out;
}

/// 条目资料表里的**别名**（Bangumi 的 infobox `别名` 那一行，可能有多条）。
List<String> librarySeedAliases(BangumiSubject subject) {
  final List<String> out = <String>[];
  for (final BangumiInfoboxItem item in subject.infobox) {
    if (!item.key.contains('别名') && !item.key.toLowerCase().contains('alias')) {
      continue;
    }
    for (final String value in item.values) {
      final String text = value.trim();
      if (text.isNotEmpty && !out.contains(text)) out.add(text);
    }
  }
  return out;
}

/// 去掉「第 N 季 / 第 N 部分 / Season N / Part N / S2 / 后半部分 / 最终季」这类尾缀。
///
/// 为什么要它：mikan 是**整串匹配**，多一个字就 0 行 —— 实测
/// `Re：从零开始的异世界生活 第二季 后半部分` 直接 0 行，而去掉尾缀的基础名能搜到。
/// 循环剥（`第二季 后半部分` 要剥两次）；剥空了就返回 null（不返回空串去搜）。
String? dropSeasonSuffix(String? raw) {
  String text = (raw ?? '').trim();
  if (text.isEmpty) return null;
  for (int i = 0; i < 4; i++) {
    final String next = text.replaceFirst(_kSeasonSuffix, '').trim();
    if (next == text) break;
    text = next;
  }
  final String cleaned = text.replaceAll(RegExp(r'[\s\-–—:：·]+$'), '').trim();
  if (cleaned.isEmpty || cleaned == (raw ?? '').trim()) {
    return cleaned.isEmpty ? null : cleaned;
  }
  return cleaned;
}

final RegExp _kSeasonSuffix = RegExp(
  r'[\s\-–—:：·]*('
  r'第\s*[0-9０-９一二三四五六七八九十]+\s*(季|期|部|部分|章|クール|话|話)'
  r'|(season|part|cour|s)\s*[0-9０-９]+'
  r'|[0-9０-９]+\s*(st|nd|rd|th)\s+season'
  r'|final\s+season|最终季|最終季'
  r'|后半(部分)?|後半(部分)?|下半(部分)?'
  r')\s*$',
  caseSensitive: false,
);

/// 把名字/标题归一化成"可以互相比"的形态。
///
/// 规则：全角→半角 → 小写 → 去掉方括号/圆括号里的整段（技术标签、字幕组）→
/// 去掉集号尾标（`- 01`、`第01话`）→ 只留下中日英数字，其余折成空格。
/// 对**两边都做**，所以对标点/全角不敏感。
String normalizeSeedTitle(String raw) {
  final String stripped = _normalizeSeedTitle(raw, dropBrackets: true);
  // 整个名字都在括号里时（`【葬送的芙莉莲】`）剥完就没东西了 —— 那种情况下**保住
  // 括号里的内容**再归一化一次，而不是返回空串（返回空串等于"完全不像"）。
  if (stripped.isNotEmpty) return stripped;
  return _normalizeSeedTitle(raw, dropBrackets: false);
}

String _normalizeSeedTitle(String raw, {required bool dropBrackets}) {
  String s = _toHalfWidth(raw).toLowerCase();
  if (dropBrackets) {
    s = s.replaceAll(RegExp(r'[\[\(【（][^\]\)】）]*[\]\)】）]'), ' ');
  }
  s = s.replaceAll(RegExp(r'[-–—_]\s*\d{1,4}(\.\d+)?(v\d+)?\b'), ' ');
  s = s.replaceAll(RegExp(r'第\s*\d{1,4}\s*[话話集]'), ' ');
  s = s.replaceAll(RegExp(r'[^0-9a-z\u3040-\u30ff\u4e00-\u9fff]+'), ' ');
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 这一条候选标题有多像"用户要找的那部番"。[names] 是条目的全部名字变体。
///
/// 100 = 归一化后完全一样；60 = 一边包含另一边；40 = 剥掉季/部后缀后一样；0 = 不像。
///
/// ⚠️ **季节必须对齐**：实测 mikan 的候选顺序不保证是目标那一季（进击的巨人给的是
/// 第二季、东京喰种给的是 `:re`），所以"基础名一样但季号不同"**不能**算 60 分，
/// 直接判 0 —— 否则会出现"绑到了第二季，用户看着第三季的剧集列表"。
int seedTitleScore(String candidateTitle, Iterable<String> names) {
  final String candidate = normalizeSeedTitle(candidateTitle);
  if (candidate.isEmpty) return 0;
  // ⚠️ 这两个只跟"候选"有关，**必须在循环外算**（第四十七轮）：它们各含一次正则归一化，
  // 放在循环里就是每个名字重算一遍 —— 1000 条候选 × 3~4 个名字，白烧几十毫秒。
  final int? candidateSeason = _seasonOf(candidateTitle);
  final String candidateShort = normalizeSeedTitle(dropSeasonSuffix(candidateTitle) ?? '');
  int best = 0;
  for (final String raw in names) {
    final String name = normalizeSeedTitle(raw);
    if (name.isEmpty) continue;
    final int? nameSeason = _seasonOf(raw);
    if (candidateSeason != null && nameSeason != null && candidateSeason != nameSeason) {
      continue; // 同一部番的不同季：不算命中
    }
    if (candidate == name) {
      if (best < 100) best = 100;
      continue;
    }
    if (candidate.contains(name) || name.contains(candidate)) {
      if (best < 60) best = 60;
      continue;
    }
    final String nameShort = normalizeSeedTitle(dropSeasonSuffix(raw) ?? '');
    if (candidateShort.isNotEmpty && candidateShort == nameShort && best < 40) best = 40;
  }
  return best;
}

/// 便捷判据：像同一部番吗（自动绑定的门槛）。
bool looksLikeSameAnime(String candidateTitle, Iterable<String> names) =>
    seedTitleScore(candidateTitle, names) >= 60;

/// 从 `第2季` / `Season 2` / `S2` / `Part 2` / `第二季` 里取出季号（没有就是 null）。
int? _seasonOf(String raw) {
  final String text = _toHalfWidth(raw).toLowerCase();
  final Match? zh = RegExp(
    r'第\s*([0-9]+|[一二三四五六七八九十]+)\s*(季|期|部|部分|クール)',
  ).firstMatch(text);
  if (zh != null) return _parseSeasonNumber(zh.group(1));
  final Match? en = RegExp(
    r'(?:season|part|cour)\s*([0-9]+)|([0-9]+)\s*(?:st|nd|rd|th)\s+season|(?:^|\s)s([0-9]+)\b',
  ).firstMatch(text);
  if (en != null) {
    return _parseSeasonNumber(en.group(1) ?? en.group(2) ?? en.group(3));
  }
  if (text.contains('后半') || text.contains('後半') || text.contains('下半')) {
    return null; // 「后半部分」是同一季的下半段，不是另一个季号
  }
  return null;
}

int? _parseSeasonNumber(String? raw) {
  final String text = (raw ?? '').trim();
  if (text.isEmpty) return null;
  final int? digit = int.tryParse(text);
  if (digit != null) return digit;
  const List<String> zh = <String>['零', '一', '二', '三', '四', '五', '六', '七', '八', '九', '十'];
  final int at = zh.indexOf(text);
  return at < 0 ? null : at;
}

/// 用户粘进来的那一串是不是一个 mikan 番剧页 / id。
///
/// 三种形态都收（用户第四十五轮选定「直接粘 mikan 链接或 id」）：
/// `2833`、`/Home/Bangumi/2833`、`https://mikanani.me/Home/Bangumi/2833`。
String? parseMikanBangumiId(String raw) {
  final String text = raw.trim();
  if (text.isEmpty) return null;
  final Match? url = RegExp(r'/Home/Bangumi/(\d+)').firstMatch(text);
  if (url != null) return url.group(1);
  final Match? plain = RegExp(r'^(\d{1,8})$').firstMatch(text);
  return plain?.group(1);
}

/// 番剧页的展示地址（种子块里给一个"在 mikan 打开"的链接）。
String mikanBangumiUrl(String bangumiId) =>
    'https://mikanani.me/Home/Bangumi/${bangumiId.trim()}';

/// 这个名字是不是"罗马字/英文"那一路（用来把别名里的英文写法排到中文别名前面）。
///
/// ⚠️ 判据是"**不含**中日文字符"，不是"全是 ASCII"：实测里最好用的别名常带排版符号
/// （`SPY×FAMILY Part 2` 里的 `×` 是 U+00D7，不是 ASCII），按"全 ASCII"判会把它当成
/// 中文别名排到最后，而那恰恰是这一部番唯一能搜到结果的词。
bool _looksLatin(String text) =>
    !RegExp(r'[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af]').hasMatch(text);

/// 全角 → 半角（ASCII 段 + 全角空格）。
///
/// 与 `domain/subtitle_groups.dart` 里那份是同一件事的两个副本 —— 刻意重复：
/// 那边是"组名"的归一化（要剥尾缀、要去括号），这边是"标题"的归一化（要砍集号），
/// 语义不同；共用一个 6 行的字符映射不值得把两个领域绑在一起。
String _toHalfWidth(String text) {
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

// ─────────────────────────────────────────────────────────────────────────────
// 归组与合并（第四十八轮：引擎换成主流站点搜索之后）
// ─────────────────────────────────────────────────────────────────────────────

/// "这一条在别的站也有"记在 `extra` 的这个键上（值 = 源 id 列表）。
const String kSeedAlsoOnKey = 'alsoOn';

/// [item] 在别的站也叫这个名字（同名合并记下来的）；没有就是空表。
List<String> seedAlsoOn(SourceItemView item) {
  final Object? raw = item.extra[kSeedAlsoOnKey];
  if (raw is! List) return const <String>[];
  return <String>[
    for (final Object? value in raw)
      if (value is String && value.isNotEmpty) value,
  ];
}

/// 同名合并用的「标题键」。
///
/// ⚠️ **刻意不用 [normalizeSeedTitle]**：那个要剥掉整段方括号（服务的是"像不像这一部番"），
/// 而方括号里装的正是**区分两条资源**的东西 —— `[1080p]` / `[720p]`、`[简繁字幕]` /
/// `[繁日双语]`。按它归并会把两个版本合成一条，用户就再也选不到另一个版本了。
/// 这里只做"同一串标题的不同排版"级别的归一化：全角→半角、小写、空白收敛、去首尾标点。
String seedTitleMergeKey(String? raw) {
  String text = _toHalfWidth((raw ?? '').trim()).toLowerCase();
  text = text.replaceAll(RegExp(r'\s+'), ' ');
  return text.replaceAll(RegExp(r'^[\s\-–—_.,;:|/\\·]+|[\s\-–—_.,;:|/\\·]+$'), '');
}

/// 一条条目归到哪一段（归一化组名；解析不出组名就是 [kUnknownSubtitleGroupKey]）。
///
/// ⚠️ 与搜索页「字幕组筛选」的**并集语义**故意不同：那里勾「喵萌奶茶屋」也要命中
/// `喵萌奶茶屋&LoliHouse`（协作署名两边都算）；这里一条只能落在**一段**里 —— 否则
/// "这一段有 N 条"和「这一组都入队（N 条）」都会把同一条数两次、下两次。协作署名因此
/// 自成一段（`喵萌奶茶屋&LoliHouse`），名字照原样显示，没被藏起来。
String seedGroupKeyOf(SourceItemView item) =>
    normalizeGroupKey(item.group) ?? kUnknownSubtitleGroupKey;

/// 「同名合并」：**同一段 + 同一标题**的条目并成一条（第四十八轮）。
///
/// 为什么是"同一段 + 同一标题"而不是只按标题：标题相同但**字幕组不同**的两条是
/// **两份不同的文件**（不同字幕/不同压制的版本），合并会真的吃掉用户的选择；
/// 而"同一个组把同一集同时发到 mikan 与动漫花园"才是同一条东西，那才是要合掉的重复。
/// 完全同一条（同 infoHash）在更前面的 [aggregateMerge] 就并掉了，这里管的是
/// "两个站的标题写法不同、hash 也没抽到"那一档。
///
/// 留下的那条：信息更全的（[richerItem]，与聚合搜索同一把尺子）；平手保持先到的。
/// 被合掉的站记进 `extra[kSeedAlsoOnKey]`（界面上给一个小标记，别让用户以为少看了一个站）。
List<SourceItemView> mergeSeedDuplicates(List<SourceItemView> items) {
  final List<SourceItemView> out = <SourceItemView>[];
  final Map<String, int> at = <String, int>{};
  for (final SourceItemView item in items) {
    final String title = seedTitleMergeKey(item.title);
    // 没有标题的**不合并**：同一个组里所有"无标题"会被并成一条，等于凭空丢条目。
    final String key = title.isEmpty
        ? '\u0000id\u0000${item.dedupeKey}'
        : '${seedGroupKeyOf(item)}\u0000$title';
    final int? existing = at[key];
    if (existing == null) {
      at[key] = out.length;
      out.add(item);
      continue;
    }
    final SourceItemView kept = out[existing];
    final bool takeNew = richerItem(item, kept);
    final SourceItemView winner = takeNew ? item : kept;
    final SourceItemView loser = takeNew ? kept : item;
    final List<String> also = <String>{
      ...seedAlsoOn(kept),
      ...seedAlsoOn(item),
      loser.sourceId,
    }.where((String id) => id != winner.sourceId).toList()..sort();
    out[existing] = _withSeedAlsoOn(winner, also);
  }
  return out;
}

/// 复制一条并把"别的站也有"写进 `extra`（[SourceItemView] 是不可变的，只能重建）。
SourceItemView _withSeedAlsoOn(SourceItemView item, List<String> also) {
  if (also.isEmpty) return item;
  return SourceItemView(
    id: item.id,
    sourceId: item.sourceId,
    title: item.title,
    detailUrl: item.detailUrl,
    torrentUrl: item.torrentUrl,
    magnet: item.magnet,
    infoHash: item.infoHash,
    sizeBytes: item.sizeBytes,
    seeders: item.seeders,
    leechers: item.leechers,
    downloads: item.downloads,
    publishedAt: item.publishedAt,
    category: item.category,
    group: item.group,
    episodeHints: item.episodeHints,
    extra: <String, Object?>{
      ...item.extra,
      kSeedAlsoOnKey: List<String>.unmodifiable(also),
    },
  );
}

/// 名字在标题里出现过的那些条目（**可能为空表**）。
///
/// 为什么要有"可能为空"这一版、而不是直接"空了就原样给全部"：同一个判据有两个用法，
/// 语义相反 ——
/// * 逐级退让的阶梯拿它判**这一级算不算中**（空了就该去试下一级写法）；
/// * 定稿时它决定**给用户看什么**，那里才需要"宁可多给几条也别空着"那层兜底
///   （见 `LibrarySeedController._searchNames` 的 `fallback`）。
List<SourceItemView> seedItemsMentioning(
  List<SourceItemView> items,
  List<String> names,
) => <SourceItemView>[
  for (final SourceItemView item in items)
    if (seedTitleMentions(item.title, names)) item,
];

/// [title] 里出现过 [names] 里的任何一个名字吗。
///
/// ⚠️ **不要拿 [seedTitleScore] 代替它**（第四十八轮真机实测）：那个打分函数服务的是
/// "这一条像不像那一部番"（要剥括号、要比季号），而 mikan 上大量标题把番名装在方括号里
/// —— `[KissSub][Steins;Gate][命运石之门][12][GB_BIG5_JP][...]` 剥完括号名字就没了。
/// 「命运石之门」841 行里有 **246 行（29%）**会被它判成无关，其中还有 KissSub 的一整套 01–12。
///
/// 判据本身很朴素：两边都折成「只留字母/数字/假名/汉字」的骨架再比子串 —— 这样
/// `Steins;Gate` / `STEINS;GATE` / `Steins Gate` 是同一条，方括号、全角、`;` `·`
/// 这些排版差异也不再影响。
bool seedTitleMentions(String? title, Iterable<String> names) {
  final String hay = _seedSkeleton(title);
  if (hay.isEmpty) return false;
  for (final String raw in names) {
    final String needle = _seedSkeleton(raw);
    // 一个字的名字不算命中（`零`、`Z` 这种会捞回半个站的东西）——与
    // `series_search.dart` 的 kMinSeriesKeywordLength 同一考量。
    if (needle.length < 2) continue;
    if (hay.contains(needle)) return true;
  }
  return false;
}

/// 「骨架」：全角→半角、小写、只留字母/数字/假名/汉字。
String _seedSkeleton(String? raw) => _toHalfWidth((raw ?? '').trim())
    .toLowerCase()
    .replaceAll(RegExp(r'[^0-9a-z\u3040-\u30ff\u4e00-\u9fff]+'), '');

/// 一个字幕组 = 种子块里的一段。
@immutable
class SeedGroup {
  const SeedGroup({required this.key, required this.label, required this.items});

  /// 归一化组名（[seedGroupKeyOf]）；[kUnknownSubtitleGroupKey] = 解析不出组名的那些。
  final String key;

  /// 给人看的组名（预置名单优先，其次取本批里最常见的原始写法）。
  final String label;

  /// 这一段里的条目（顺序 = 传进来那个池子的顺序 = 发布时间新→旧）。
  final List<SourceItemView> items;

  int get count => items.length;

  bool get isUnknown => key == kUnknownSubtitleGroupKey;
}

/// 按字幕组把池子切成一段一段；**条数多的组在前**（平手按最新那条的时间，再按组名），
/// 而「未知组」**永远排最后**（第四十八轮·补三，用户「未知组默认在最下面」）。
///
/// 为什么不是"最新发过东西的组在前"（第四十八轮用真数据试过）：「命运石之门」的 841 行
/// 分成 48 段，每组条数中位数 **3**、只有 1 条的 **13 段**，而真正成套的是
/// `澄空学园&华盟`（93 条）、`爱恋字幕社`（67 条）、`动漫花园`（56 条）。
/// 按"最新一条"排会让 4 条 / 2 条 / 2 条的小段占满首屏（默认露 3 段时首屏只有 8 行），
/// 用户还得点十几次「显示更多字幕组」才看得到成套的那几家。
/// 种子是**拿来下的**，所以"哪一家有整部"比"谁上个月又发了一条"重要。
List<SeedGroup> groupSeedItems(List<SourceItemView> items) {
  final List<String> order = <String>[];
  final Map<String, List<SourceItemView>> byKey =
      <String, List<SourceItemView>>{};
  for (final SourceItemView item in items) {
    final String key = seedGroupKeyOf(item);
    List<SourceItemView>? bucket = byKey[key];
    if (bucket == null) {
      bucket = <SourceItemView>[];
      byKey[key] = bucket;
      order.add(key);
    }
    bucket.add(item);
  }
  final List<SeedGroup> groups = <SeedGroup>[
    for (final String key in order)
      SeedGroup(
        key: key,
        // 展示名只在**这一段自己的条目**里找（不扫整个池子）：`subtitleGroupLabel`
        // 要遍历池子找原始写法，54 段 × 841 条就是四万多次归一化，纯白烧的 CPU。
        label: subtitleGroupLabel(key, byKey[key]!),
        items: List<SourceItemView>.unmodifiable(byKey[key]!),
      ),
  ];
  groups.sort((SeedGroup a, SeedGroup b) {
    // 「未知组」**永远排最后**（第四十八轮·补三，用户「未知组默认在最下面」）：
    // 解析不出组名的那些是个人发布 / 命名怪的杂项，不是"一家字幕组" —— 按条数排的话
    // 它们很容易挤进首屏，把真正成套的那几家顶下去。用户是要挑一家来下，
    // 所以"谁有整部"先摆出来，杂项留到最后需要时再翻。
    if (a.isUnknown != b.isUnknown) return a.isUnknown ? 1 : -1;
    final int byCount = b.count.compareTo(a.count);
    if (byCount != 0) return byCount;
    final DateTime? at = a.items.first.publishedAt;
    final DateTime? bt = b.items.first.publishedAt;
    if (at != null && bt != null && at != bt) return bt.compareTo(at);
    if (at == null && bt != null) return 1;
    if (at != null && bt == null) return -1;
    return a.label.compareTo(b.label);
  });
  return groups;
}
