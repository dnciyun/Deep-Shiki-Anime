/// 字幕组（发布组）的名字归一化、预置名单、以及搜索页「字幕组」筛选的候选构建。
///
/// **第四十五轮**（用户：「在搜索中加入字幕组筛选」）。这一份是**唯一**的组名归一化
/// 实现：改造前仓库里有三份互不复用的副本 ——
/// * `core/lib/subs/title_parser.dart` 的 `extractGroup`（只 trim，管"从标题里取出组名"，
///   它的活是**抽取**不是**归并**，仍然留在 core）；
/// * `series_search.dart` 的 `normalizedGroupName`（折分隔符 + 小写，只服务同系列判定）；
/// * `playlist.dart` 的 `_normalizedGroup`（只 trim + 小写，只服务播放列表归组）。
///
/// 后两份的差别没有任何理由：同一部番在"播放列表要不要归到一起"和"翻页算不算同一系列"
/// 上必须用同一把尺子，否则会出现"判为同系列、翻页也翻了，最后却被归组丢掉"的白工
/// （`series_search.dart` 的注释早就点出过这个风险）。现在都走 [normalizeGroupKey]。
///
/// 归一化规则照实测口径（`build/round45/report.md`，24 部番 / 5586 条有组名的条目）：
/// 全角 → 半角 → 去首尾括号 → 小写 → 分隔符（空格/下划线/连字符/点）折成 `-` →
/// 剥一次「字幕组 / 字幕社 / 压制组 / 汉化组 / …」尾缀（剥完仍要 ≥2 字符）→ 去首尾 `-`。
/// 这样 `桜都字幕组` = `桜都字幕組`、`极影字幕社` = `极影`、`MingY` = `MingYSub`。
library;

import 'models.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 归一化
// ─────────────────────────────────────────────────────────────────────────────

/// 归一化时要剥掉的尾缀（**长的在前**，否则 `字幕组` 会被 `字幕` 先咬掉）。
const List<String> kGroupSuffixes = <String>[
  '字幕组',
  '字幕組',
  '字幕社',
  '字幕团',
  '字幕團',
  '压制组',
  '壓制組',
  '汉化组',
  '漢化組',
  '发布组',
  '發布組',
  'fansubs',
  'fansub',
  'subs',
  '字幕',
  'sub',
];

/// **不是组名**的词（归一化后的形态）。
///
/// 为什么必须有这份黑名单：`core` 的 `TitleParser.extractGroup` 只认「标题最前面的
/// 方括号」，而方括号里装的并不总是字幕组 —— 实测里 `搬运` 有 61 条、还有 `合集`、
/// `Baha`（巴哈姆特源）、`无修`、`简繁` 这类**发布标签**。把它们列进筛选面板会让用户
/// 看到「按搬运筛选」这种荒唐选项（用户第四十五轮选定：剔除「不是组」的词）。
///
/// 只做**整名**匹配：`NC-Raws`、`LoliHouse` 这类压制组照旧保留（它们确实回答
/// "这一版是谁做的"）。
const Set<String> kNonGroupTokens = <String>{
  '搬运',
  '合集',
  '全集',
  '无修',
  '無修',
  '简繁',
  '簡繁',
  '简体',
  '繁體',
  '繁体',
  '简日',
  '繁日',
  '中日',
  '招募',
  '招人',
  '发布',
  '首发',
  '字幕',
  '外挂',
  '内嵌',
  // 光秃秃的「字幕组」不是任何一家（`core` 的 title_parser 测试里就有 `【字幕组】`）。
  '字幕组',
  '字幕組',
  '字幕社',
  'baha',
  '巴哈姆特',
  'raw',
  'raws',
  'sub',
  'subs',
  'fansub',
  'unknown',
  '未知',
  '其他',
  '其它',
  'collection',
  'batch',
  'complete',
  'repack',
  'v2',
};

/// 「组名解析不出来」那一档的哨兵 key（见 [buildSubtitleGroupOptions]）。
///
/// 为什么用这个形状：归一化会把下划线折成 `-` 并去掉首尾 `-`，所以
/// `__unknown__` 这种串**永远不可能**由真实组名归一化得到，不会和真组名撞车。
const String kUnknownSubtitleGroupKey = '__unknown__';

/// 组名归一化：`Skymoon-Raws` / `skymoon raws` / `桜都字幕組` → `skymoon-raws` / `桜都`。
///
/// 返回 null = 空串、或者整名都是「不是组」的词（见 [kNonGroupTokens]）。
String? normalizeGroupKey(String? raw) {
  String text = _toHalfWidth((raw ?? '').trim());
  if (text.isEmpty) return null;
  // 首尾括号（`[Nix-Raws]`、`【桜都字幕组】`、`「…」`）只是包裹，不是名字的一部分。
  text = text.replaceAll(RegExp(r'^[\s\[\]【】「」〈〉<>()（）]+'), '');
  text = text.replaceAll(RegExp(r'[\s\[\]【】「」〈〉<>()（）]+$'), '');
  if (text.isEmpty) return null;
  text = text.toLowerCase();
  // 分隔符统一成 `-`（不删掉）：保住 `A-One` 与 `AOne` 的区别。
  text = text.replaceAll(RegExp(r'[\s_\-–—.·]+'), '-');
  text = text.replaceAll(RegExp(r'^-+|-+$'), '');
  if (text.isEmpty) return null;
  for (final String suffix in kGroupSuffixes) {
    if (!text.endsWith(suffix)) continue;
    final String stripped = text.substring(0, text.length - suffix.length);
    // 剥完太短就别剥（实测口径：剥完仍要 ≥2 字符），否则 `Sub` 会变成空串。
    if (stripped.replaceAll('-', '').length < 2) continue;
    text = stripped.replaceAll(RegExp(r'^-+|-+$'), '');
    break;
  }
  if (text.isEmpty || kNonGroupTokens.contains(text)) return null;
  return text;
}

/// 一条结果身上**所有**的组（协作署名会拆成多个）。
///
/// 为什么必须拆：实测里 `喵萌奶茶屋&LoliHouse`、`极影字幕+轻之国度`、
/// `悠哈璃羽字幕社&LoliHouse` 都是常态。不拆的话勾「喵萌奶茶屋」会筛不出
/// `喵萌奶茶屋&LoliHouse` 那批 —— 而用户勾这个组的本意恰恰包含那些。
///
/// 只在 `&`、`+`、`＋`、`、`、`,`、`，` 上拆；**不在 `-` / `/` 上拆**：
/// `NC-Raws`、`Up to 21°C` 里的符号是名字的一部分。
List<String> groupKeysOf(String? raw) {
  final String text = (raw ?? '').trim();
  if (text.isEmpty) return const <String>[];
  final List<String> out = <String>[];
  for (final String part in text.split(RegExp(r'[&+＋、,，]'))) {
    final String? key = normalizeGroupKey(part);
    if (key != null && !out.contains(key)) out.add(key);
  }
  return out;
}

/// 这一条命中用户勾的组吗。
///
/// * [keys] 为空 = **不限**（筛选没开，全部通过）；
/// * 条目没有可识别的组 → 只有勾了「未知组」那一档才算命中（用户第四十五轮选定：
///   未知组单列一项，而不是一开筛选就整批消失）；
/// * 协作署名的条目 → **任一**组命中即算（并集语义）。
bool itemMatchesSubtitleGroups(SourceItemView item, Set<String> keys) {
  if (keys.isEmpty) return true;
  final List<String> mine = groupKeysOf(item.group);
  if (mine.isEmpty) return keys.contains(kUnknownSubtitleGroupKey);
  for (final String key in mine) {
    if (keys.contains(key)) return true;
  }
  return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// 预置名单
// ─────────────────────────────────────────────────────────────────────────────

/// 预置的常见字幕组 / 压制组（33 家）。
///
/// **来源**：第四十五轮实测（热门 / 一般 / 冷门各 8 部番，24 部、5586 条有组名的条目，
/// 见 `build/round45/report.md` 与 `build/round45/groups_freq.json`）。
/// 前 26 家是实测高频（括号里是在本批结果里出现的条数）；后 7 家是**本次也真命中过**
/// 的老牌组 —— 实测 0 命中的 7 家（天使动漫论坛 / 银光 / 天香 / CASO / 流云 / KNA / 绿叶）
/// **故意不收**：面板里常驻一堆永远 0 条的选项只是噪声（用户第四十五轮选定这一版）。
///
/// 冷门番**不需要**单独扩列：实测里冷门番没有专属新组名，只有协作署名与搬运号。
///
/// 顺序 = 实测频次顺序（面板里 0 命中的项按这个顺序沉在后面）。
const List<String> kPresetSubtitleGroups = <String>[
  '桜都字幕组', // 292
  '极影字幕社', // 279
  '喵萌奶茶屋', // 218
  '悠哈璃羽字幕社', // 183
  '诸神字幕组', // 160
  '北宇治字幕组', // 121
  '❀拨雪寻春❀', // 119
  '动漫国字幕组', // 113
  'NC-Raws', // 112
  'Lilith-Raws', // 109
  '异域字幕组', // 97
  '离谱Sub', // 95
  'ANi', // 93
  '绿茶字幕组', // 86
  '黒ネズミたち', // 80
  'GJ.Y', // 78
  'SOSG字幕团', // 78
  '华盟字幕社', // 78（与下面那家是协作署名，拆开各算一家）
  '元古I.G部落', // 78
  'Up to 21°C', // 69
  'Dymy字幕组', // 67
  'SweetSub', // 66
  '圆环记录攻略组', // 66
  '千夏字幕组', // 61
  'LoliHouse', // 60
  '幻樱字幕组', // 55
  // ↓ 实测也命中过的老牌组（本条要求：「热门 冷门 一般的都跑几轮」后仍然保留）
  '轻之国度', // 34（多以 `极影字幕+轻之国度` 形式出现，拆开后单列）
  '雪飘工作室', // 27
  '幻之字幕组', // 27
  '澄空学园', // 6
  'FLsnow', // 3
  '漫游字幕组', // 1
  '月光恋曲', // 1
];

/// 「最近用过」的字幕组最多记几个。
///
/// 12 是"够排到面板第一屏、又不至于把预置名单挤没"的量（面板首屏约 8~10 行）。
const int kRecentSubtitleGroupLimit = 12;

/// 预置名单的 key → 展示名（保留站点上最常见的那个写法，别把用户的名单改成小写）。
final Map<String, String> kPresetSubtitleGroupLabels = <String, String>{
  for (final String label in kPresetSubtitleGroups)
    if (normalizeGroupKey(label) case final String key) key: label,
};

// ─────────────────────────────────────────────────────────────────────────────
// 筛选面板的候选
// ─────────────────────────────────────────────────────────────────────────────

/// 面板里的一项。
class SubtitleGroupOption {
  const SubtitleGroupOption({
    required this.key,
    required this.label,
    required this.count,
    required this.preset,
    required this.selected,
    this.isUnknown = false,
  });

  /// 归一化后的 key（勾选状态存的就是它）。
  final String key;

  /// 给人看的名字（预置表优先，其次取本批结果里最常见的原始写法）。
  final String label;

  /// 本批池子里命中几条。
  final int count;

  /// 来自预置名单。
  final bool preset;

  final bool selected;

  /// 「未知组」那一档（[kUnknownSubtitleGroupKey]）。
  final bool isUnknown;

  bool get known => isUnknown != true;
}

/// 从当前池子 + 预置表 + 最近用过，构建面板里那一串候选。
///
/// 排序（用户第四十五轮定下的口径 + 一处实现细节）：
/// 1. **已勾选的排最前** —— 面板可能有上百项，勾完找不到自己勾了什么是很糟的体验；
/// 2. 最近用过的（新 → 旧）；
/// 3. 本批命中条数多的在前；
/// 4. 预置表的顺序（0 命中的预置项沉在这一段，置灰显示 0 条）；
/// 5. 其余按名字。
///
/// 「未知组」**永远在最后**：它是一个兜底档，不是常用项。
List<SubtitleGroupOption> buildSubtitleGroupOptions({
  required List<SourceItemView> pool,
  Set<String> selected = const <String>{},
  List<String> recent = const <String>[],
}) {
  final Map<String, int> counts = <String, int>{};
  final Map<String, Map<String, int>> rawForms = <String, Map<String, int>>{};
  int unknown = 0;
  for (final SourceItemView item in pool) {
    final List<String> keys = groupKeysOf(item.group);
    if (keys.isEmpty) {
      unknown++;
      continue;
    }
    for (final String key in keys) {
      counts[key] = (counts[key] ?? 0) + 1;
      final String raw = (item.group ?? '').trim();
      if (raw.isNotEmpty) {
        final Map<String, int> forms = rawForms.putIfAbsent(key, () => <String, int>{});
        forms[raw] = (forms[raw] ?? 0) + 1;
      }
    }
  }

  String labelFor(String key) {
    final String? preset = kPresetSubtitleGroupLabels[key];
    if (preset != null) return preset;
    final Map<String, int>? forms = rawForms[key];
    if (forms == null || forms.isEmpty) return key;
    // 取本批里出现最多的那个原始写法（并列时取短的，再并列按字典序 ——
    // `List.sort` 不保证稳定，没有最后这道确定性 tiebreak 时标签会随机跳）。
    final List<MapEntry<String, int>> sorted = forms.entries.toList()
      ..sort((MapEntry<String, int> a, MapEntry<String, int> b) {
        final int byCount = b.value.compareTo(a.value);
        if (byCount != 0) return byCount;
        final int byLength = a.key.length.compareTo(b.key.length);
        if (byLength != 0) return byLength;
        return a.key.compareTo(b.key);
      });
    return sorted.first.key;
  }

  int recentRank(String key) {
    final int at = recent.indexOf(key);
    return at < 0 ? recent.length : at;
  }

  int presetRank(String key) {
    final int at = kPresetSubtitleGroups.indexWhere(
      (String g) => normalizeGroupKey(g) == key,
    );
    return at < 0 ? kPresetSubtitleGroups.length : at;
  }

  final Set<String> all = <String>{...counts.keys, ...selected};
  for (final String g in kPresetSubtitleGroups) {
    final String? key = normalizeGroupKey(g);
    if (key != null) all.add(key);
  }
  all.remove(kUnknownSubtitleGroupKey);

  final List<SubtitleGroupOption> options = <SubtitleGroupOption>[
    for (final String key in all)
      SubtitleGroupOption(
        key: key,
        label: labelFor(key),
        count: counts[key] ?? 0,
        preset: kPresetSubtitleGroupLabels.containsKey(key),
        selected: selected.contains(key),
      ),
  ];

  options.sort((SubtitleGroupOption a, SubtitleGroupOption b) {
    final int bySelected = (b.selected ? 1 : 0).compareTo(a.selected ? 1 : 0);
    if (bySelected != 0) return bySelected;
    final int byRecent = recentRank(a.key).compareTo(recentRank(b.key));
    if (byRecent != 0) return byRecent;
    final int byCount = b.count.compareTo(a.count);
    if (byCount != 0) return byCount;
    final int byPreset = presetRank(a.key).compareTo(presetRank(b.key));
    if (byPreset != 0) return byPreset;
    return a.label.compareTo(b.label);
  });

  options.add(
    SubtitleGroupOption(
      key: kUnknownSubtitleGroupKey,
      label: '未知组',
      count: unknown,
      preset: false,
      selected: selected.contains(kUnknownSubtitleGroupKey),
      isUnknown: true,
    ),
  );
  return options;
}

/// 展示名：预置表优先，其次到池子里找一个原始写法，最后退回 key 本身。
///
/// 为什么要"到池子里找"：长尾里 30% 的组只出现一次、不在预置表里（实测 336 个组名），
/// 而 key 已经被归一化成小写 + 折过分隔符（`#CHAT RUMBLE#百合组` → `#chat-rumble#百合组`）
/// —— 直接把 key 摆给用户看是"把内部口径漏出去了"。
///
/// ⚠️ **两种匹配都要试**（第四十八轮修）：当归组把 `item.group` **整串**归一化时
/// （动漫库种子块的「按字幕组分段」，一条只落一段），协作署名 `喵萌奶茶屋&LoliHouse` 的 key 是
/// `喵萌奶茶屋&lolihouse`，而 [groupKeysOf] 是**拆开**的（`喵萌奶茶屋` + `lolihouse`）
/// —— 只按后者找，整串那个 key 永远找不到原始写法，界面上就会显示小写的内部 key。
String subtitleGroupLabel(String key, List<SourceItemView> pool) {
  if (key == kUnknownSubtitleGroupKey) return '未知组';
  final String? preset = kPresetSubtitleGroupLabels[key];
  if (preset != null) return preset;
  for (final SourceItemView item in pool) {
    final String raw = (item.group ?? '').trim();
    if (raw.isEmpty) continue;
    if (normalizeGroupKey(raw) == key || groupKeysOf(raw).contains(key)) {
      return raw;
    }
  }
  return key;
}

/// 全角 → 半角（ASCII 段 + 全角空格）。
///
/// 为什么手写：Dart 标准库**没有** Unicode 归一化（Python 的 `NFKC` 在这里没有对应物），
/// 而实测里全角括号 / 全角冒号 / 全角字母真的会出现（`Re：从零开始…` 就是一例）。
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
