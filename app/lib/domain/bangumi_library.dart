/// 「动漫库」的查询模型（第三十三轮）：**纯数据 + 纯函数**，请求怎么拼、筛选怎么落到
/// Bangumi 的参数上全在这里 —— 不碰 IO，所以能逐条单测（`bangumi_library_test.dart`）。
///
/// ## 端点是实测挑出来的（`tool/round33_bangumi_probe*.py`，2026-10-15 本机真打）
///
/// | 能力 | 用法 | 实测结论 |
/// |---|---|---|
/// | 关键词 | `POST /v0/search/subjects` body `keyword` | 可用（`葬送的芙莉莲` → total 5） |
/// | 排序 | body `sort` | 只认 `match` / `heat` / `rank` / `score`；`date` → **400 sort not supported** |
/// | 标签 | `filter.tag: []string` | 可用（`["百合"]`；多个标签取**交集**：`["百合","科幻"]` → 251） |
/// | 类型 | 同「标签」 | 第四十四轮：界面上叫「类型」的就是标签，清单见 [kLibraryGenreTags]（逐个实测过） |
/// | 评分下限 | `filter.rating: []string` | **必须是字符数组**（`[">=7"]`）。写成对象 → 400
///   `Unmarshal type error: expected=[]string, got=object, field=filter.rating` |
/// | 年份/季度 | `filter.air_date: [">=YYYY-MM-DD","<YYYY-MM-DD"]` | 可用 |
/// | 放送形态 | `filter.platform` | **会被静默忽略**（加了 platform 的 total 与不加**一模一样**）
///   ⇒ 服务端改用 `filter.tag:[形态]`（实测命中率 TV 10/10、剧场版 8/10、OVA 8/10、WEB 8/10），
///   再在本地按条目自带的 `platform` **精确过一遍**（[BangumiLibraryForm.matches]） |
/// | 翻页 | **查询串** `?limit=&offset=` | body 里的 `limit`/`offset` 会被忽略（实测 offset 无效） |
/// | total | —— | 该端点**封顶 1000**（窄查询才给真实值）|
///
/// 它比 `GET /v0/subjects` 强的地方：GET 那条路 `platform` 同样被忽略，而且排序只支持
/// `rank`/`date`，没有标签/评分/关键词筛选。
library;

import 'package:flutter/foundation.dart';

import 'bangumi.dart';

/// 一页排几整行。
///
/// ⚠️ 2026-10-15 第三十四轮（用户：「动漫库缺少6个才填满一页」）：以前这里是**写死的 24 条**，
/// 而列数是按窗口宽算出来的 —— 24 不是 5 / 7 / 9 / 10 的倍数，于是"最后一行缺几个"完全
/// 取决于窗口宽度（1920 窗 = 9 列 → 一页 24 条排成 2 整行 + 第三行只有 6 条，缺 3；
/// 2048 逻辑宽的屏 = 10 列 → 缺 6）。现在每页 = **列数 × 本常量**，永远整行。
const int kLibraryRows = 4;

/// **不知道列数**时的兜底每页条数（端口签名的默认值；真页面永远知道列数）。
///
/// 4 行 × 6 列 = 24：与第三十三轮一致，也是 1280 窗宽附近（6 列）的真实取值。
const int kLibraryDefaultPageSize = 24;

/// 服务端**单次请求**的条数上限（实测：`limit=21/24/25/30/50` 都只回 20 条，
/// 回显的 `limit` 也是 20 —— 见 `tool/round34_page_probe2.py` / `build/round34/body-probe.txt`）。
///
/// 所以"一页"要么 ≤ 20（一次请求），要么由服务层**多次请求拼出来**
/// （[libraryMaxFetches] 给的就是这个次数）。
const int kLibraryServerPageCap = 20;

/// 一页要多少条（列数已知）：**整行**。
///
/// 列数由页面用 [`_columnsFor`] 那套算式量出来（窗口宽度决定），所以每页条数跟着窗口走 ——
/// 这也正是"最后一行不会缺几个"的唯一可靠办法：让一页的条数**是列数的整数倍**。
int libraryPageSize(int columns) =>
    columns < 1 ? kLibraryDefaultPageSize : columns * kLibraryRows;

/// 为了凑满 [size] 条，服务端最多要请求几次。
///
/// 两部分相加：
/// * `ceil(size / cap)` —— 服务端一次最多 20 条，光靠"要多条"就得请求这么多次；
/// * [extra] —— 放送形态的**本地精确筛**会再吃掉一些（实测命中率 TV 10/10、剧场版 8/10、
///   OVA 7/20…11/20、WEB 18/20）。给 3 次余量：一页 40 条按 40% 命中率算正好够。
///
/// 上限 8 次（8 × 20 = 160 条原始数据）—— 再凑不满就照实给少一点，
/// 不去把"一页必须满"变成"无限刷 Bangumi"。
int libraryMaxFetches(int size, {int extra = 3}) {
  final int need = (size / kLibraryServerPageCap).ceil() + extra;
  return need.clamp(1, 8);
}

/// `POST /v0/search/subjects` 的 `total` 封顶值（实测：宽查询一律 1000）。
const int kLibraryTotalCap = 1000;

/// 排序（`sort` 只认这四个，`date` 会 400）。
enum BangumiLibrarySort {
  heat('heat', '热度'),
  score('score', '评分'),
  rank('rank', '排名');

  const BangumiLibrarySort(this.code, this.label);

  final String code;
  final String label;

  static BangumiLibrarySort fromCode(String? code) => values.firstWhere(
    (BangumiLibrarySort s) => s.code == code,
    orElse: () => BangumiLibrarySort.heat,
  );
}

/// 放送形态。[tag] 是发给服务端的近似判据（`filter.platform` 实测被忽略），
/// [matches] 是本地按条目自带 `platform` 的精确判据。
enum BangumiLibraryForm {
  any('any', '全部', null),
  tv('tv', 'TV', 'TV'),
  ova('ova', 'OVA', 'OVA'),
  movie('movie', '剧场版', '剧场版'),
  web('web', 'WEB', 'WEB');

  const BangumiLibraryForm(this.code, this.label, this.tag);

  final String code;
  final String label;

  /// 发给服务端的标签（`null` = 不过滤）。
  final String? tag;

  static BangumiLibraryForm fromCode(String? code) => values.firstWhere(
    (BangumiLibraryForm f) => f.code == code,
    orElse: () => BangumiLibraryForm.any,
  );

  /// 本地精确判据：条目自己带的 `platform` 必须**就是**这个形态。
  ///
  /// 为什么不直接信服务端的标签：实测 `tag[剧场版]` 的前 10 条里有 2 条 platform 是「其他」、
  /// `tag[OVA]` 里有 1 条是 TV、1 条是剧场版 —— 标签是用户打的，会串味。
  bool matches(BangumiSubject subject) {
    final String? tag = this.tag;
    if (tag == null) return true;
    return (subject.platform ?? '').trim() == tag;
  }
}

/// 季度档（[quarter] 的含义：0 = 全年，1..4 = 1/4/7/10 月番）。
const List<String> kLibraryQuarterLabels = <String>['全年', '1 月番', '4 月番', '7 月番', '10 月番'];

/// 评分下限档位（`null` = 不限）。
const List<double> kLibraryMinScoreChoices = <double>[6, 7, 7.5, 8, 8.5, 9];

/// 「类型」筛选的标签清单（第四十四轮，**顺序就是界面上的顺序**：常见 → 冷门）。
///
/// 用户原话：「优化动漫库…并加入类型的筛选，比如异世界 玄幻 校园这些」。
///
/// Bangumi **没有**「类型」这个字段 —— 类型就是**用户打的标签**，走的是与详情页标签胶囊
/// 完全同一条路（`filter.tag`，见 [BangumiLibraryQuery.filter]）。而标签是自由文本，
/// 凭空列一份清单必然有一半是没人用的（「玄幻」这种中文网文词，动画条目上到底有没有人打？
/// 凭空猜是不负责任的），所以先**真打了一遍**：
/// `tool/round44_genre_probe.py`（2026-10-16 本机实测，`filter.type=[2]` + `filter.tag=[标签]`，
/// 35 个候选逐个查 `POST /v0/search/subjects`，原始表在 `build/round44/genre-probe.txt`）。
/// 下表是它回来的 `total`（服务端宽查询封顶 1000）：
///
/// | 标签 | total | 标签 | total | 标签 | total |
/// |---|---|---|---|---|---|
/// | 校园 | 1000 | 奇幻 | 1000 | 科幻 | 1000 |
/// | 恋爱 | 1000 | 日常 | 1000 | 搞笑 | 1000 |
/// | 治愈 | 1000 | 战斗 | 1000 | 冒险 | 1000 |
/// | 机战 | 1000 | 热血 | 1000 | 百合 | 1000 |
/// | 后宫 | 1000 | 泡面番 | 1000 | 子供向 | 1000 |
/// | **异世界** | **803** | 青春 | 719 | 悬疑 | 652 |
/// | 音乐 | 621 | **玄幻** | **537** | 运动 | 511 |
/// | 战争 | 439 | 猎奇 | 439 | 偶像 | 425 |
/// | 历史 | 413 | 女性向 | 392 | 魔法 | 357 |
/// | 竞技 | 357 | 推理 | 301 | 催泪 | 273 |
/// | 超能力 | 255 | 武侠 | 239 | 恐怖 | 176 |
///
/// 落选的两个（**故意不列**，因为列了等于骗人）：`悬疑推理` 只有 4 条、`奇幻冒险` 9 条 ——
/// 用户点了它得到一屏空结果，看起来就是"这个筛选坏了"。清单里每一条最少也有 176 条。
const List<String> kLibraryGenreTags = <String>[
  // 题材
  '奇幻',
  '科幻',
  '异世界',
  '玄幻',
  '校园',
  '恋爱',
  '日常',
  '搞笑',
  '治愈',
  '战斗',
  '冒险',
  '悬疑',
  '推理',
  '恐怖',
  '音乐',
  '运动',
  '机战',
  '魔法',
  '超能力',
  '历史',
  '战争',
  '青春',
  '热血',
  '武侠',
  // 氛围 / 受众
  '百合',
  '后宫',
  '偶像',
  '竞技',
  '猎奇',
  '催泪',
  '泡面番',
  '子供向',
  '女性向',
];

/// 这个标签是不是清单里的「类型」（右栏的类型胶囊靠它决定要不要额外补一颗"当前标签"）。
bool isLibraryGenre(String tag) => kLibraryGenreTags.contains(tag.trim());

/// 一次动漫库查询。
@immutable
class BangumiLibraryQuery {
  const BangumiLibraryQuery({
    this.keyword = '',
    this.year,
    this.quarter = 0,
    this.form = BangumiLibraryForm.any,
    this.sort = BangumiLibrarySort.heat,
    this.minScore,
    this.tag,
  });

  final String keyword;

  /// 年份；`null` = 不限。
  final int? year;

  /// 0 = 全年；1..4 = 1/4/7/10 月番（[kLibraryQuarterLabels]）。
  final int quarter;

  final BangumiLibraryForm form;

  /// 只在**没有关键词**时生效（有关键词就按相关度，见 [serverSort]）。
  final BangumiLibrarySort sort;

  /// 评分下限；`null` = 不限。
  final double? minScore;

  /// 标签（如「异世界」「百合」）；`null` = 不限。界面上叫**类型**。
  ///
  /// 两个入口（都是同一个字段，所以两处永远一致）：
  /// * 动漫库右栏的**类型胶囊**（[kLibraryGenreTags] 那份实测清单，点一下筛、再点一下取消）；
  /// * **条目详情页的标签**（点一下 = 回库里按这个标签筛）—— 那儿的标签不限于清单
  ///   （「公路片」「2022年10月」都可能），所以右栏遇到清单外的标签会补一颗"当前标签"胶囊
  ///   把它显示出来，否则用户会看到"结果被筛过、但界面上找不到原因"。
  final String? tag;

  String get trimmedKeyword => keyword.trim();

  /// 真正发给 Bangumi 的 `sort`：有关键词时一律 `match`（相关度），
  /// 否则用用户选的那一档 —— 搜了名字还被"热度"排序会觉得搜错了。
  String get serverSort =>
      trimmedKeyword.isEmpty ? sort.code : 'match';

  /// 「这一档一共有哪些筛选条件」的中文一行（历史记录与结果抬头都用它）。
  String get description {
    final List<String> parts = <String>[
      if (trimmedKeyword.isNotEmpty) '「$trimmedKeyword」',
      if (year != null) quarter == 0 ? '$year 年' : '$year 年 ${kLibraryQuarterLabels[quarter]}',
      if (form != BangumiLibraryForm.any) form.label,
      if (minScore != null) '≥${_scoreLabel(minScore!)} 分',
      if ((tag ?? '').trim().isNotEmpty) '类型「${tag!.trim()}」',
    ];
    if (parts.isEmpty) return '全部动画';
    return parts.join(' · ');
  }

  /// 排序那一档的人话（有词时说明按相关度）。
  String get sortLabel => trimmedKeyword.isEmpty ? '按${sort.label}' : '按相关度';

  bool get isDefault =>
      trimmedKeyword.isEmpty &&
      year == null &&
      quarter == 0 &&
      form == BangumiLibraryForm.any &&
      minScore == null &&
      (tag ?? '').trim().isEmpty;

  BangumiLibraryQuery copyWith({
    String? keyword,
    int? year,
    int? quarter,
    BangumiLibraryForm? form,
    BangumiLibrarySort? sort,
    double? minScore,
    String? tag,
    bool clearYear = false,
    bool clearMinScore = false,
    bool clearTag = false,
  }) =>
      BangumiLibraryQuery(
        keyword: keyword ?? this.keyword,
        year: clearYear ? null : (year ?? this.year),
        quarter: quarter ?? this.quarter,
        form: form ?? this.form,
        sort: sort ?? this.sort,
        minScore: clearMinScore ? null : (minScore ?? this.minScore),
        tag: clearTag ? null : (tag ?? this.tag),
      );

  /// 发给服务端的 `filter`（只有非默认项才出现，省得让服务端解析没用的条件）。
  Map<String, Object?> get filter {
    final List<String>? air = airDate;
    final List<String>? rating = ratingFilter;
    // 形态与用户点选的标签**一起**放进 `tag`（Bangumi 的多个标签是取交集）。
    final String formTag = form.tag ?? '';
    final String pickedTag = (tag ?? '').trim();
    final List<String> tags = <String>[
      if (formTag.isNotEmpty) formTag,
      if (pickedTag.isNotEmpty) pickedTag,
    ];
    return <String, Object?>{
      'type': const <int>[2], // 2 = 动画
      if (tags.isNotEmpty) 'tag': tags,
      'air_date': ?air,
      'rating': ?rating,
    };
  }

  /// `air_date` 区间（`[">=起","<止"]`）；没选年份就是 null。
  List<String>? get airDate {
    final int? y = year;
    if (y == null) return null;
    if (quarter <= 0 || quarter > 4) {
      return <String>['>=$y-01-01', '<${y + 1}-01-01'];
    }
    final int startMonth = 1 + (quarter - 1) * 3; // 1 / 4 / 7 / 10
    final int endYear = quarter == 4 ? y + 1 : y;
    final int endMonth = quarter == 4 ? 1 : startMonth + 3;
    return <String>['>=$y-${_two(startMonth)}-01', '<$endYear-${_two(endMonth)}-01'];
  }

  /// `rating` 过滤（**字符数组**，实测写成对象会 400）。
  List<String>? get ratingFilter {
    final double? min = minScore;
    if (min == null) return null;
    return <String>['>=${_scoreLabel(min)}'];
  }

  /// 缓存键 / 在途去重键 / 历史记录用的稳定串。
  ///
  /// ⚠️ **每一个会影响服务端结果的字段都必须在里面**。第四十四轮补上了 `t=`（标签）：
  /// 旧串只到 `r=`（评分）为止，而 [tag] 同样进 [filter] —— 于是"同一个关键词/年份/形态，
  /// 只换了类型标签"两份查询会算出**同一个键**，而它被用在两处关键地方：
  /// * `state/bangumi_library.dart` 的**页缓存**（键 `cacheKey|offset|limit`）：
  ///   点了「异世界」会拿到上一次（无标签）那一页，**最多错 10 分钟**；
  /// * `state/library_provider.dart` 的在途去重：筛选期间改标签会被当成"同一份请求"，
  ///   新的那次查询**根本不发**。
  /// 也就是说：少了这一节，第四十四轮新加的「类型」筛选在界面上点得动、结果却纹丝不动。
  String get cacheKey =>
      'k=${trimmedKeyword.toLowerCase()}|y=${year ?? ''}|q=$quarter|'
      'f=${form.code}|s=$serverSort|r=${minScore ?? ''}|'
      't=${(tag ?? '').trim()}';

  Map<String, Object?> toJson() => <String, Object?>{
    'keyword': keyword,
    'year': year,
    'quarter': quarter,
    'form': form.code,
    'sort': sort.code,
    'minScore': minScore,
    'tag': tag,
  };

  /// 值相等（筛选条的每一格改动都会整份换掉这个对象；状态控制器靠它判断"真的变了"）。
  @override
  bool operator ==(Object other) =>
      other is BangumiLibraryQuery &&
      other.trimmedKeyword == trimmedKeyword &&
      other.year == year &&
      other.quarter == quarter &&
      other.form == form &&
      other.sort == sort &&
      other.minScore == minScore &&
      (other.tag ?? '').trim() == (tag ?? '').trim();

  @override
  int get hashCode => Object.hash(
      trimmedKeyword, year, quarter, form, sort, minScore, (tag ?? '').trim());

  factory BangumiLibraryQuery.fromJson(Map<String, Object?> json) {
    final Object? year = json['year'];
    final Object? min = json['minScore'];
    return BangumiLibraryQuery(
      keyword: (json['keyword'] as String?) ?? '',
      year: year is num ? year.toInt() : null,
      quarter: (json['quarter'] as num?)?.toInt() ?? 0,
      form: BangumiLibraryForm.fromCode(json['form'] as String?),
      sort: BangumiLibrarySort.fromCode(json['sort'] as String?),
      minScore: min is num ? min.toDouble() : null,
      tag: (json['tag'] as String?)?.trim().isEmpty ?? true
          ? null
          : (json['tag'] as String),
    );
  }
}

/// 一页结果。
@immutable
class BangumiLibraryPage {
  const BangumiLibraryPage({
    required this.items,
    required this.total,
    required this.startOffset,
    required this.nextOffset,
    required this.hasMore,
  });

  static const BangumiLibraryPage empty = BangumiLibraryPage(
    items: <BangumiSubject>[],
    total: 0,
    startOffset: 0,
    nextOffset: 0,
    hasMore: false,
  );

  final List<BangumiSubject> items;

  /// 服务端给的总数（已按 [kLibraryTotalCap] 封顶）。
  final int total;

  /// 这一页从哪个服务端 offset 开始（上一页要用它）。
  final int startOffset;

  /// 下一页从哪个 offset 开始（放送形态的本地过滤会吃掉一部分，所以它 ≥ startOffset+条数）。
  final int nextOffset;

  final bool hasMore;

  bool get isEmpty => items.isEmpty;

  BangumiLibraryPage copyWith({
    List<BangumiSubject>? items,
    int? total,
    int? startOffset,
    int? nextOffset,
    bool? hasMore,
  }) =>
      BangumiLibraryPage(
        items: items ?? this.items,
        total: total ?? this.total,
        startOffset: startOffset ?? this.startOffset,
        nextOffset: nextOffset ?? this.nextOffset,
        hasMore: hasMore ?? this.hasMore,
      );
}

/// 这一页是否已经凑够（放送形态的本地过滤之后）。纯函数，便于单测。
bool libraryPageFilled(List<BangumiSubject> kept, int pageSize) =>
    kept.length >= pageSize;

/// 服务端 offset 的硬上限（`total` 封顶 + 不能再往后翻）。
int libraryHardEnd(int serverTotal) =>
    serverTotal <= 0 ? 0 : (serverTotal < kLibraryTotalCap ? serverTotal : kLibraryTotalCap);

String _two(int n) => n < 10 ? '0$n' : '$n';

/// 评分显示：整数不带小数点（7 分而不是 7.0 分）。
String _scoreLabel(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
