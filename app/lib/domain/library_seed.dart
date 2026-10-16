/// 动漫库「种子」块的**领域**部分（第四十五轮）。
///
/// 用户原话：「能实现动漫库中直接显示种子吗，就像主页那样」——主页卡片点进去那页
/// （`ui/bangumi_detail.dart`）就是"按字幕组列剧集 + 每集磁力"，所以这里要复刻的是
/// **那一页的数据**，不是它的版式。
///
/// 这条链上有个绕不开的事实：**Bangumi 的条目 id 与 mikan 的番剧 id 是两套 id**
/// （`following_store.dart` 把 `mikan:<id>` 与 `bgm:<id>` 并列成两个键，正说明是两回事），
/// 仓库里没有任何映射表。所以"这一条 Bangumi 条目 ↔ 哪个 mikan 番剧页"只能**按番名搜出来**，
/// 而 mikan 的搜索是**整串匹配、不分词**（实测：`间谍过家家 第2部分` 与
/// `SPY×FAMILY 第2クール` 都是 0 行，靠别名 `SPY×FAMILY Part 2` 才有结果）
/// —— 这就是 [librarySeedQueries] 那条"逐级退让"的阶梯存在的理由。
///
/// 另一个实测事实（见 `build/round45/report.md`）：mikan 搜索页的行里**没有**
/// `/Home/Bangumi/<id>` 链接（1000 行里 0 条），番剧 id 只在**单集页**里
/// （`MikanEpisodeParser` 的 `extra['bangumiId']`）。所以每试一个候选要多打一枪详情页
/// —— [kMaxLibrarySeedDetails] 是这件事的预算上限。
library;

import 'bangumi.dart' show BangumiSubject, BangumiInfoboxItem;

/// 一次解析最多试几个查询词（用户第四十五轮定的阶梯正好四级）。
const int kMaxLibrarySeedQueries = 4;

/// 一次解析最多打几次"单集详情页"（每次 = 1 个候选番剧页）。
///
/// 为什么要有全局预算：每个候选 = 一次网络（同站 ≥1.2s），而阶梯有四级；不设预算时
/// 最坏情况是 4×2 次详情 + 4 次搜索 ≈ 20 秒。3 次是把"冷门番也要能查到"和"别让用户
/// 干等"之间取的中间值（典型路径只花 1 次：第一个候选的标题就对得上）。
const int kMaxLibrarySeedDetails = 3;

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

/// 解析过程中撞见的一个候选番剧页（拿不准时列出来让用户点）。
class MikanSeedCandidate {
  const MikanSeedCandidate({
    required this.bangumiId,
    required this.title,
    required this.query,
    required this.score,
  });

  final String bangumiId;
  final String title;
  final String query;

  /// [seedTitleScore] 的分数：100 = 名字完全一样，60 = 一边包含另一边，40 = 去掉
  /// 季/部后缀后一样，0 = 不像。
  final int score;
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
  int best = 0;
  for (final String raw in names) {
    final String name = normalizeSeedTitle(raw);
    if (name.isEmpty) continue;
    final int? candidateSeason = _seasonOf(candidateTitle);
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
    final String cs = normalizeSeedTitle(dropSeasonSuffix(candidateTitle) ?? '');
    final String ns = normalizeSeedTitle(dropSeasonSuffix(raw) ?? '');
    if (cs.isNotEmpty && cs == ns && best < 40) best = 40;
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
