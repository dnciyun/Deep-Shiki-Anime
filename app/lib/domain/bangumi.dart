/// Bangumi API：条目解析、「全年代随机」推荐选择器、搜索与详情。
///
/// 规范：spec §7.7（今日推荐 · 全年代随机）、§7.8（Bangumi 封面与标签，含实测踩坑）。
///
/// **实测过的三条限制（别自己发挥）**：
/// * `/v0/subjects?type=2&sort=random&limit=5` → 服务端 **400**，不可用；
/// * `/calendar` 是「当季在播」，用户明确否决（要全年代随机）；
/// * ✅ `/v0/subjects?type=2&limit=20&offset=<随机>` 抽全库（`total ≈ 29521`）。
///   但 offset 切片**按 id 排序**，单个窗口只覆盖很窄的一段历史
///   （实测 `offset=0` → 1979~2008、`offset=5000` → 1978~2014），所以必须
///   **取多个相距较远的窗口、按窗口均衡抽取**，否则 5 部会挤在同一年代。
///
/// 另外 Bangumi **必须带 UA**（不带会被拒），请求间隔 ≥1s。
///
/// 搜索接口的响应形状**实测**是 `{"results":<条数>,"list":[条目…]}` ——
/// 条目在 `list` 里，`results` 是 int（见 [parseBangumiSearchResults]）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// UA 必须带（spec §7.8 实测：不带 UA 会被拒）。
const String bangumiUserAgent = 'DSAnima/0.1 (https://github.com/local/dsanima)';

/// 封面图床（`http` 不是 `https`），下载要带 `Referer: https://bgm.tv/`。
const String bangumiCoverReferer = 'https://bgm.tv/';

/// Bangumi 图床的**尺寸阶梯**（真机实测，2026-10-12 第二十轮）。
///
/// 图床的宽度是路径前缀 `/r/<宽>/pic/cover/…`，而且**只认这几档**：
/// 实测同一张封面 `/r/100/`=100×150 5 KB、`/r/200/`=200×300 14 KB、
/// `/r/400/`=400×600 42 KB、`/r/800/`=600×900 68 KB（源就 600×900 时封顶）；
/// 而 `/r/150/`、`/r/250/`、`/r/300/`、`/r/500/` 全部 **HTTP 400**。
/// 所以只能在这四档里往上抬，不能自己算一个宽度写进去。
const List<int> bangumiCoverWidths = <int>[100, 200, 400, 800];

/// 把想要的宽度抬到阶梯上最近的一档（≥ 请求值；超过最大档取最大档）。
int snapBangumiCoverWidth(int width) {
  for (final int step in bangumiCoverWidths) {
    if (width <= step) return step;
  }
  return bangumiCoverWidths.last;
}

/// 已经是带宽度前缀的形状：`/r/<宽>/pic/cover/<尺寸字母>/`。
final RegExp _coverResizePrefix = RegExp(r'/r/\d+/pic/cover/([a-z])/');

/// 老式形状（**旧搜索接口** `/search/subject/{q}` 给的就是它）：`/pic/cover/<尺寸字母>/`。
final RegExp _coverSizeDir = RegExp(r'/pic/cover/([a-z])/');

/// 角色头像（`/pic/crt/…`）的两种形状 —— 与封面**同一套档位规则**（第三十七轮实测：
/// `/r/200|400|800/pic/crt/l/` 都是 200，`/r/400/pic/crt/g/` 与 `/r/250/` 都是 **400**，
/// 也就是说只有 `l` 那一份能被缩放）。
final RegExp _crtResizePrefix = RegExp(r'/r/\d+/pic/crt/([a-z])/');
final RegExp _crtSizeDir = RegExp(r'/pic/crt/([a-z])/');

/// Bangumi 图床的尺寸目录字母：`s` 小 / `g` 网格 / `c` common / `m` medium / `l` 原图。
const Set<String> bangumiCoverSizeDirs = <String>{'s', 'g', 'c', 'm', 'l'};

/// 同一张封面在指定**像素宽度**下的 URL。
///
/// 用户 2026-10-12 第二十轮「bangumi 的封面很糊」的真身：代码一直拿 `images.grid`
/// 当封面用，而 grid 只有 100 像素宽（新接口是 `/r/100/pic/cover/l/…`；
/// **旧搜索接口给的是 `/pic/cover/g/…`，实测只有 48×48**），放到 208pt 的海报卡上
/// （本机缩放 1.25 ⇒ 需要 260 设备像素）等于放大好几倍。
///
/// ⚠️ **第二十一轮补的坑（我自己上一轮造出来的回归）**：`/r/<宽>/` 只能加在
/// **`l`（原图）** 那一份上 —— 真机实测 `/r/400/pic/cover/g/…`、`/r/400/pic/cover/c/…`
/// 全是 **HTTP 400**。上一版把 `/r/<宽>/` 无脑插进老式 URL，于是「已完成」页
/// （封面走旧搜索接口）的封面**全部加载不出来**。所以这里一律**先归一化到 `l` 再抬档**。
///
/// 规则：
/// * 不是 Bangumi 封面（mikan 等别的源）→ **原样返回**，绝不改别人的 URL；
/// * `/r/<宽>/pic/cover/<字母>/…`（新接口）→ 换成 `/r/<阶梯档>/pic/cover/l/…`；
/// * `/pic/cover/<字母>/…`（旧接口）→ 同上（字母不是 `s/g/c/m/l` 的**不认识的形状**则不动）；
/// * `width <= 0` 或 null / 空白 → 原样返回（调用方还没算出尺寸时不要乱降档）。
String? bangumiCoverAt(String? url, int width) {
  final String raw = (url ?? '').trim();
  if (raw.isEmpty || width <= 0) return raw.isEmpty ? null : raw;
  return _retierBangumiImage(raw, width, '/pic/cover/', _coverResizePrefix, _coverSizeDir);
}

/// 把「已经是 `/pic/cover/` 形状」的 URL 抬到 [snapBangumiCoverWidth] 那一档。
///
/// `kind` 决定的是**哪一族图**：`/pic/cover/`（条目封面）或 `/pic/crt/`（角色头像）。
/// 两族的档位阶梯、`l` 才能缩放、认不出的形状原样返回 —— 三条都由实测得出，完全一致
/// （见 [bangumiCoverAt] 与 [bangumiCharacterAt] 的注释），所以实现只有这一份。
String _retierBangumiImage(
  String raw,
  int width,
  String kind,
  RegExp prefixed,
  RegExp sized,
) {
  final String resized = '/r/${snapBangumiCoverWidth(width)}$kind' 'l/';
  final Match? already = prefixed.firstMatch(raw);
  if (already != null) {
    return '${raw.substring(0, already.start)}$resized${raw.substring(already.end)}';
  }
  final Match? sizedMatch = sized.firstMatch(raw);
  if (sizedMatch == null || !bangumiCoverSizeDirs.contains(sizedMatch.group(1))) {
    return raw;
  }
  return '${raw.substring(0, sizedMatch.start)}$resized${raw.substring(sizedMatch.end)}';
}

/// 角色头像在指定**像素宽度**下的 URL（`/pic/crt/…`）。
///
/// 为什么单独一个函数（第三十七轮）：[bangumiCoverAt] 只认 `/pic/cover/`，而
/// `/v0/subjects/{id}/characters` 给的头像是 `/pic/crt/l/…` —— 不抬档的话，一个 56pt
/// 的角色头像会去下 `/pic/crt/l/` 那份原图（本机实测同一张：原图 25 KB、`/r/100/` 6.8 KB，
/// 一屏 12 个就是 300 KB 换 82 KB，而且解码也更大）。
///
/// 实测的档位与封面一致（2026-10-15 本机真打）：
/// `/r/100/`→6.8 KB、`/r/200/`→19.5 KB、`/r/400/`→25.4 KB、`/r/800/`→25.5 KB 全是 200；
/// `/r/250/pic/crt/l/` 与 `/r/400/pic/crt/g/` 都是 **HTTP 400** ⇒ 只能落在
/// [bangumiCoverWidths] 这四档上、且只能改 `l` 那一份。
String? bangumiCharacterAt(String? url, int width) {
  final String raw = (url ?? '').trim();
  if (raw.isEmpty || width <= 0) return raw.isEmpty ? null : raw;
  if (!raw.contains('/pic/crt/')) return raw;
  return _retierBangumiImage(raw, width, '/pic/crt/', _crtResizePrefix, _crtSizeDir);
}

/// Bangumi 图床上**任何一张图**（条目封面 / 角色头像）在指定宽度下的 URL。
///
/// 这是控件侧唯一的取档入口（`cover.dart` 的 `_ensure` 用它）：两族路径不重叠，
/// 各跑一遍，顺序无关；不是 Bangumi 的 URL（mikan 等）一律原样返回。
String? bangumiImageAt(String? url, int width) {
  final String? cover = bangumiCoverAt(url, width);
  return bangumiCharacterAt(cover, width);
}


const String bangumiApiBase = 'https://api.bgm.tv';

/// Bangumi 调用失败（网络/HTTP/解析）。调用方一律**静默降级**，不能拖慢列表。
class BangumiException implements Exception {
  BangumiException(this.message, {this.statusCode, this.url, this.cause});

  final String message;
  final int? statusCode;
  final Uri? url;
  final Object? cause;

  @override
  String toString() =>
      'BangumiException($message${statusCode == null ? '' : ' · HTTP $statusCode'}'
      '${url == null ? '' : ' · $url'})';
}

/// 一条 Bangumi 条目（只取宿主用得到的字段）。
///
/// ⚠️ 只有**详情端点**（`GET /v0/subjects/{id}`）才带右边这三样：
/// [ratingCounts]（1..10 每档多少人）、[collection]（想看/在看/看过/抛弃）、[infobox]
/// （话数/放送开始/电视台/原作/监督…的原始资料表）。搜索端点不给 —— 所以它们**都能为空**，
/// 渲染层必须自己判空（第三十四轮实测，见 `tool/round34_subject_probe.py`）。
@immutable
class BangumiSubject {
  const BangumiSubject({
    required this.id,
    this.name,
    this.nameCn,
    this.date,
    this.eps,
    this.score,
    this.rank,
    this.ratingTotal,
    this.coverUrl,
    this.largeCoverUrl,
    this.tags = const <String>[],
    this.summary,
    this.platform,
    this.type,
    this.ratingCounts = const <int, int>{},
    this.collection,
    this.infobox = const <BangumiInfoboxItem>[],
  });

  final int id;

  /// 原名（日文/罗马音）。
  final String? name;

  /// 中文名（**可能是空串**，实测 `Kanon` 就是 `""`）。
  final String? nameCn;

  /// 上映日期 `YYYY-MM-DD`；**可能缺失**（实测 offset=15000 有 3 条、28000 有 11 条）。
  ///
  /// ⚠️ 两个接口的字段名**不一样**（第十七轮补）：`/v0/subjects` 用 `date`，
  /// 旧搜索接口 `/search/subject/{q}` 用 `air_date`（实测响应里就是它）。
  /// [BangumiSubject.fromJson] 两个都认，否则搜索结果里的日期全是空的。
  final String? date;

  /// 话数（用 `eps`；`total_episodes` 实测常见 0）。
  final int? eps;

  /// 评分；**未开播/无评分时为 null**，渲染层必须能显示「暂无评分」。
  final double? score;
  final int? rank;
  final int? ratingTotal;

  /// `images.grid` —— ⚠️ 它就是 `/r/100/`，**只有 100 像素宽**（旧注释写"约 150pt"是错的，
  /// 第二十轮真机抓下来是 100×150）。只够 40pt 那种小缩略图；卡片一律用
  /// [coverUrlAt] 按显示尺寸重新取档，别再直接拿它铺满卡片（那样会明显发糊）。
  final String? coverUrl;

  /// `images.large`（原图，没有 `/r/` 前缀）。
  final String? largeCoverUrl;
  final List<String> tags;
  final String? summary;
  final String? platform;
  final int? type;

  /// 评分分布：`{1: 129, 2: 37, …, 10: 7511}`（详情端点才有；搜索端点回空表）。
  ///
  /// 键恒为 1..10，没投过票的档**不出现**（渲染时补 0）。
  final Map<int, int> ratingCounts;

  /// 收藏统计（详情端点才有；条目没人收藏时五项都是 0）。
  final BangumiCollection? collection;

  /// 原始资料表（详情端点才有；实测 41–61 行，值可能是字符串或一组 `{v: …}`）。
  final List<BangumiInfoboxItem> infobox;

  /// 展示用标题：中文名非空优先，否则原名。
  String get displayTitle {
    final String cn = (nameCn ?? '').trim();
    if (cn.isNotEmpty) return cn;
    final String raw = (name ?? '').trim();
    return raw.isEmpty ? 'Bangumi #$id' : raw;
  }

  /// 英文/原名（与中文名不同才有意义，用于「正在追」卡的英文名行）。
  String? get alternateTitle {
    final String raw = (name ?? '').trim();
    if (raw.isEmpty || raw == displayTitle) return null;
    return raw;
  }

  String get airDateLabel => (date ?? '').trim();

  /// 推荐用的完整性判据（spec §7.7：`date` 缺失 / `score == null` / 无封面 全部剔除）。
  ///
  /// 这是**策略**，不是数据保证：渲染层仍然要能处理 `score == null`。
  bool get isComplete =>
      airDateLabel.isNotEmpty &&
      score != null &&
      score! > 0 &&
      (coverUrl ?? '').trim().isNotEmpty;

  /// 年份（取不到返回 null，不猜）。
  int? get year {
    final String d = airDateLabel;
    if (d.length < 4) return null;
    return int.tryParse(d.substring(0, 4));
  }

  /// 这张封面在某个**显示宽度（设备像素）**下该用的 URL（见 [bangumiCoverAt]）。
  ///
  /// 优先从 [coverUrl]（`/r/100/`，任何一份存量数据里存的都是它）改写宽度 ——
  /// 所以**老数据不用迁移**也能跟着变清晰；只有 grid 缺失时才退到原图 [largeCoverUrl]。
  String? coverUrlAt(int width) => bangumiCoverAt(coverUrl ?? largeCoverUrl, width);

  /// 评分分布里某一档有多少人（没投票 = 0）。
  int ratingAt(int score) => ratingCounts[score] ?? 0;

  /// 评分分布的总票数（端点给的 `rating.total`，没有分布时回落到它）。
  int get ratingVotes {
    if (ratingCounts.isEmpty) return ratingTotal ?? 0;
    int sum = 0;
    for (final int v in ratingCounts.values) {
      sum += v;
    }
    return sum > 0 ? sum : (ratingTotal ?? 0);
  }

  /// 有没有可画的评分分布（一票都没有就别画空条）。
  bool get hasRatingBreakdown => ratingCounts.values.any((int v) => v > 0);

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'name_cn': nameCn,
        'date': date,
        'eps': eps,
        'score': score,
        'rank': rank,
        'rating_total': ratingTotal,
        'cover': coverUrl,
        'cover_large': largeCoverUrl,
        'tags': tags,
        'summary': summary,
        'platform': platform,
        'type': type,
        // 详情才有的三样：存进缓存，下次点开同一部不必再等网络（第三十四轮）。
        if (ratingCounts.isNotEmpty)
          'rating_counts': <String, Object?>{
            for (final MapEntry<int, int> e in ratingCounts.entries) '${e.key}': e.value,
          },
        if (collection != null) 'collection': collection!.toJson(),
        if (infobox.isNotEmpty)
          'infobox': <Object?>[
            for (final BangumiInfoboxItem item in infobox) item.toJson(),
          ],
      };

  /// 解析**两种形状**：Bangumi 原始响应（`images` / `rating` 嵌套）与本类的
  /// [toJson]（扁平键）—— 缓存往返都走这一个解析器，避免两套逻辑漂移。
  factory BangumiSubject.fromJson(Map<String, Object?> json) {
    final Object? images = json['images'];
    final Map<Object?, Object?> imageMap =
        images is Map ? images.cast<Object?, Object?>() : const <Object?, Object?>{};
    final Object? rating = json['rating'];
    final Map<Object?, Object?> ratingMap =
        rating is Map ? rating.cast<Object?, Object?>() : const <Object?, Object?>{};
    String? str(Object? v) {
      if (v == null) return null;
      final String s = v.toString().trim();
      return s.isEmpty ? null : s;
    }

    return BangumiSubject(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: str(json['name']),
      nameCn: str(json['name_cn']),
      date: str(json['date']) ?? str(json['air_date']),
      eps: (json['eps'] as num?)?.toInt() ??
          (json['total_episodes'] as num?)?.toInt(),
      score: (ratingMap['score'] as num?)?.toDouble() ??
          (json['score'] as num?)?.toDouble(),
      rank: (ratingMap['rank'] as num?)?.toInt() ??
          (json['rank'] as num?)?.toInt(),
      ratingTotal: (ratingMap['total'] as num?)?.toInt() ??
          (json['rating_total'] as num?)?.toInt(),
      coverUrl: str(imageMap['grid']) ??
          str(imageMap['common']) ??
          str(json['cover']),
      largeCoverUrl: str(imageMap['large']) ?? str(json['cover_large']),
      // `tags` 正常是 `[{name,count}, …]`；换类型（int/null/字符串）时**当没有标签**，
      // 不能因为一个字段把这一条整个解析炸掉（同 [_asListOrEmpty] 的理由）。
      tags: <String>[
        for (final Object? t in _asListOrEmpty(json['tags']))
          if (t is Map && t['name'] != null)
            t['name'].toString()
          else if (t is String && t.trim().isNotEmpty)
            t.trim(),
      ],
      summary: str(json['summary']),
      platform: str(json['platform']),
      type: (json['type'] as num?)?.toInt(),
      ratingCounts: _ratingCounts(ratingMap['count'] ?? json['rating_counts']),
      collection: BangumiCollection.fromJson(json['collection']),
      infobox: BangumiInfoboxItem.listFromJson(json['infobox']),
    );
  }
}

/// 收藏统计（详情端点的 `collection`）：五项 + 总数。
@immutable
class BangumiCollection {
  const BangumiCollection({
    this.wish = 0,
    this.collect = 0,
    this.doing = 0,
    this.onHold = 0,
    this.dropped = 0,
  });

  /// 想看。
  final int wish;

  /// 看过。
  final int collect;

  /// 在看。
  final int doing;

  /// 搁置。
  final int onHold;

  /// 抛弃。
  final int dropped;

  int get total => wish + collect + doing + onHold + dropped;

  /// 一项都没有（新番常常如此）—— 那就不画这一块。
  bool get isEmpty => total == 0;

  Map<String, Object?> toJson() => <String, Object?>{
        'wish': wish,
        'collect': collect,
        'doing': doing,
        'on_hold': onHold,
        'dropped': dropped,
      };

  /// 不是对象 / 字段换类型 → 当作**没有统计**（`null`），不编数字。
  static BangumiCollection? fromJson(Object? json) {
    if (json is! Map) return null;
    final Map<Object?, Object?> map = json.cast<Object?, Object?>();
    // 认形状、不 cast：值换成字符串时**当 0**，不让一个脏字段把整条详情炸掉。
    int n(String key) {
      final Object? value = map[key];
      return value is num ? value.toInt() : 0;
    }

    if (!map.keys.any((Object? k) => k is String && const <String>[
          'wish',
          'collect',
          'doing',
          'on_hold',
          'dropped',
        ].contains(k))) {
      return null;
    }
    return BangumiCollection(
      wish: n('wish'),
      collect: n('collect'),
      doing: n('doing'),
      onHold: n('on_hold'),
      dropped: n('dropped'),
    );
  }
}

/// 资料表的一行（详情端点的 `infobox`）：`{key: '放送开始', value: '2023年9月29日'}`。
///
/// 值的形状实测有两种：字符串，或一组 `{v: …}`（别名 / 官方网站这种一格多项）。
/// 这里统一成**字符串列表**，渲染层只负责用「 / 」接起来。
@immutable
class BangumiInfoboxItem {
  const BangumiInfoboxItem({required this.key, this.values = const <String>[]});

  final String key;
  final List<String> values;

  /// 拼成一行（多项用「 / 」）。
  String get text => values.join(' / ');

  Map<String, Object?> toJson() => <String, Object?>{
        'key': key,
        'values': values,
      };

  /// 解析整张资料表：不认识的形状**跳过这一行**，绝不让一行脏数据把详情炸掉。
  static List<BangumiInfoboxItem> listFromJson(Object? json) {
    final List<BangumiInfoboxItem> out = <BangumiInfoboxItem>[];
    if (json is! List) return out;
    for (final Object? row in json) {
      final BangumiInfoboxItem? item = fromJson(row);
      if (item != null) out.add(item);
    }
    return out;
  }

  static BangumiInfoboxItem? fromJson(Object? json) {
    if (json is! Map) return null;
    final Map<Object?, Object?> map = json.cast<Object?, Object?>();
    final Object? key = map['key'] ?? map['k'];
    if (key == null) return null;
    final String name = key.toString().trim();
    if (name.isEmpty) return null;
    // `values` 是**本类的** toJson（往返缓存），`value` 是 Bangumi 原文。
    final List<String> values = _infoboxValues(map['values'] ?? map['value']);
    if (values.isEmpty) return null;
    return BangumiInfoboxItem(key: name, values: values);
  }

  static List<String> _infoboxValues(Object? value) {
    if (value == null) return const <String>[];
    if (value is String) {
      final String s = value.trim();
      return s.isEmpty ? const <String>[] : <String>[s];
    }
    if (value is List) {
      final List<String> out = <String>[];
      for (final Object? e in value) {
        out.addAll(_infoboxValues(e));
      }
      if (out.isNotEmpty) return out;
      return const <String>[];
    }
    if (value is Map) {
      final Object? v = value['v'] ?? value['value'];
      return _infoboxValues(v);
    }
    final String s = value.toString().trim();
    return s.isEmpty ? const <String>[] : <String>[s];
  }
}

/// `rating.count`（`{"1": 129, …, "10": 7511}`）→ `{1: 129, …, 10: 7511}`。
///
/// 只认 1..10 的整数键；换类型/非数字一律**当作没有这一档**（不猜、不编 0 进去，
/// 免得"没人投票"和"字段是脏的"看起来一样）。
Map<int, int> _ratingCounts(Object? raw) {
  if (raw is! Map) return const <int, int>{};
  final Map<int, int> out = <int, int>{};
  for (final MapEntry<Object?, Object?> e in raw.cast<Object?, Object?>().entries) {
    final int? score = int.tryParse('${e.key}');
    // ⚠️ 这里**不能**写 `e.value as num?`：值换成字符串时它是一个 TypeError，
    // 会把整条详情炸掉（同 `_asListOrEmpty` 的教训：认形状、不 cast）。
    final Object? value = e.value;
    final int? count = value is num ? value.toInt() : null;
    if (score == null || count == null) continue;
    if (score < 1 || score > 10) continue;
    out[score] = count;
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// 第三十七轮：详情页「参考 bangumi 那样的布局」要用的两样真数据
// （角色 / 关联条目）——端点与形状都是实测的，见 `tool/round37_subject_probe.py`
// ─────────────────────────────────────────────────────────────────────────────

/// 一位角色（`GET /v0/subjects/{id}/characters`）。
///
/// **实测形状**（2026-10-15 本机真打，`build/round37/subject-endpoints.txt`）：
/// 响应是**裸数组**，一行的键是
/// `id / name / relation / type / images / summary / actors`。
///
/// * `relation` 实测取值：主角 / 配角 / 闲角 / 客串 / 旁白 —— API 已经**按主次排序**
///   （主角在最前），所以"取前 N 位"就是最该显示的 N 位，不用自己排；
/// * `name` 是**日文原名**，这个端点**不给 `name_cn`**（角色的中文译名在角色自己的
///   infobox 里，要再打一次接口）。bangumi 网页上那一行也是"日文名 + 中文声优"，
///   所以这里照抄：名字用 [name]，下面一行用声优 [actorName]（`actors[0].name`）；
/// * 头像取 `images.large`（`/pic/crt/l/…`，**没有档位前缀**），交给
///   [bangumiCharacterAt] 按显示尺寸抬档；部分头像 URL 带 `?r=<时间戳>`，抬档时原样保留。
@immutable
class BangumiCharacter {
  const BangumiCharacter({
    required this.id,
    this.name,
    this.relation,
    this.avatarUrl,
    this.actorName,
  });

  final int id;

  /// 日文原名（可能为空 —— 那时显示 `角色 #id`）。
  final String? name;

  /// 主角 / 配角 / 闲角 / 客串 / 旁白。
  final String? relation;

  /// `images.large`（原图那一份，抬档前）。
  final String? avatarUrl;

  /// 声优名（`actors[0].name`，中文）；没声优时为 null。
  final String? actorName;

  String get label {
    final String n = (name ?? '').trim();
    return n.isEmpty ? '角色 #$id' : n;
  }

  /// 这张头像在某个**显示宽度（设备像素）**下该用的 URL。
  String? avatarUrlAt(int width) => bangumiCharacterAt(avatarUrl, width);

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'relation': relation,
        'avatar': avatarUrl,
        'actor': actorName,
      };

  /// 解析**两种形状**：Bangumi 原始响应（`images` 嵌套 / `actors` 数组）与本类的
  /// [toJson]（扁平键）—— 缓存往返走同一个解析器，避免两套逻辑漂移
  /// （同 [BangumiSubject.fromJson] 的做法）。
  factory BangumiCharacter.fromJson(Map<String, Object?> json) {
    final Object? images = json['images'];
    final Map<Object?, Object?> imageMap =
        images is Map ? images.cast<Object?, Object?>() : const <Object?, Object?>{};
    String? str(Object? v) {
      if (v == null) return null;
      final String s = v.toString().trim();
      return s.isEmpty ? null : s;
    }

    final List<Object?> actors = _asListOrEmpty(json['actors']);
    String? actor;
    for (final Object? a in actors) {
      if (a is Map) {
        final String? name = str((a.cast<Object?, Object?>()['name']));
        if (name != null) {
          actor = name;
          break;
        }
      } else if (a is String && a.trim().isNotEmpty) {
        actor = a.trim();
        break;
      }
    }
    return BangumiCharacter(
      id: _intOf(json['id']),
      name: str(json['name']),
      relation: str(json['relation']),
      // 头像优先原图那一份（`large`），退到 `common`/`medium`（后者带 `/r/400/` 前缀，
      // 抬档会把它换成需要的那一档，没问题）；本类的扁平键 `avatar` 排最后。
      avatarUrl: str(imageMap['large']) ??
          str(imageMap['common']) ??
          str(imageMap['medium']) ??
          str(json['avatar']),
      actorName: actor ?? str(json['actor']),
    );
  }

  /// 解析整个角色数组：**认形状、不 cast** —— 不是对象的那一行直接跳过
  /// （见 [_asListOrEmpty] 的教训：一个脏字段不许把整页炸掉）。
  static List<BangumiCharacter> listFromJson(Object? json) {
    final List<BangumiCharacter> out = <BangumiCharacter>[];
    for (final Object? row in _asListOrEmpty(json)) {
      if (row is Map) out.add(BangumiCharacter.fromJson(row.cast<String, Object?>()));
    }
    return out;
  }
}

/// 一条关联条目（`GET /v0/subjects/{id}/subjects`）：续集 / 前传 / 不同版本 / 原声集…
///
/// **实测形状**：裸数组，一行的键是 `id / images / name / name_cn / relation / type`。
/// `relation` 实测取值：续集 / 衍生 / 联动 / 原声集 / 片头曲 / 片尾曲 / 广播剧 / 书籍 /
/// 单行本 / 游戏 / 三次元 / 番外篇 / 角色出演 / 其他；`type` 实测出现过 1/2/3/4/6
/// （所以**不能**只留动画：关联里大半是音乐/书籍，bangumi 网页也是照单全列）。
///
/// 这里直接复用 [BangumiSubject]（同一套 `images`/`name_cn` 解析 + [BangumiSubject.coverUrlAt]
/// 抬档），另加一个 `relation` 标签。
@immutable
class BangumiRelated {
  const BangumiRelated({required this.subject, required this.relation});

  final BangumiSubject subject;
  final String relation;

  Map<String, Object?> toJson() => <String, Object?>{
        'relation': relation,
        'subject': subject.toJson(),
      };

  static BangumiRelated? fromJson(Map<String, Object?> json) {
    final Object? nested = json['subject'];
    if (nested is Map) {
      final Map<String, Object?> inner = nested.cast<String, Object?>();
      if (inner['id'] is! num) return null;
      return BangumiRelated(
        subject: BangumiSubject.fromJson(inner),
        relation: (json['relation'] ?? '').toString().trim(),
      );
    }
    // Bangumi 原始形状：条目字段与 `relation` 平铺在同一层。
    // ⚠️ `id` 必须是数字：它不是的话这**一行**跳过 —— 不认形状就别硬 cast
    //（`BangumiSubject.fromJson` 里 `json['id'] as num?` 遇到字符串会抛 TypeError，
    // 那会把整块关联条目带走）。
    if (json['id'] is! num) return null;
    return BangumiRelated(
      subject: BangumiSubject.fromJson(json),
      relation: (json['relation'] ?? '').toString().trim(),
    );
  }

  static List<BangumiRelated> listFromJson(Object? json) {
    final List<BangumiRelated> out = <BangumiRelated>[];
    for (final Object? row in _asListOrEmpty(json)) {
      if (row is! Map) continue;
      final BangumiRelated? one = fromJson(row.cast<String, Object?>());
      if (one != null) out.add(one);
    }
    return out;
  }
}

/// 详情页顶部信息带下面的两块**补充内容**（第三十七轮）：
/// 角色（带头像）与关联条目。两块都能单独为空（实测：孤独摇滚那条
/// `/characters` 与 `/subjects` 都回 `[]`），为空就不画那一块。
@immutable
class BangumiSubjectExtra {
  const BangumiSubjectExtra({
    this.characters = const <BangumiCharacter>[],
    this.related = const <BangumiRelated>[],
    this.charactersError,
    this.relatedError,
  });

  static const BangumiSubjectExtra empty = BangumiSubjectExtra();

  final List<BangumiCharacter> characters;
  final List<BangumiRelated> related;

  /// 角色那一路**没拉到**时的异常；`null` = 这一路成功了（哪怕结果是空表）。
  ///
  /// 第四十四轮加（用户原话：「优化详细页反馈。加载关联等没有反馈，是突然出现在下面的」）：
  /// 两条端点各自失败时，旧实现只把那半边的空表交出去，调用方**分不出**
  /// 「这部真的没有角色」与「角色没拉到」—— 详情页下面那一块于是静静地什么都不显示。
  /// 有了它，那一块才能照实说「没拉到（原因）+ 重试」。
  ///
  /// ⚠️ 只在内存里传，**不落盘**（[toJson] 不带它们，见 `BangumiLibraryPort.extras` 的第 2 条
  /// 契约：有失败就不写缓存，所以盘上读回来的永远是"成功的那一份"）。
  final Object? charactersError;

  /// 关联条目那一路没拉到时的异常（语义同 [charactersError]）。
  final Object? relatedError;

  bool get isEmpty => characters.isEmpty && related.isEmpty;

  /// 有没有哪一路没拉到（详情页靠它决定要不要挂一条"部分没拉到"的横幅）。
  bool get hasFailures => charactersError != null || relatedError != null;

  Map<String, Object?> toJson() => <String, Object?>{
        'characters': <Object?>[
          for (final BangumiCharacter c in characters) c.toJson(),
        ],
        'related': <Object?>[
          for (final BangumiRelated r in related) r.toJson(),
        ],
      };

  factory BangumiSubjectExtra.fromJson(Map<String, Object?> json) =>
      BangumiSubjectExtra(
        characters: BangumiCharacter.listFromJson(json['characters'] ?? json['data']),
        related: BangumiRelated.listFromJson(json['related'] ?? json['list']),
      );
}

/// 一个可能是数字、也可能是数字字符串的字段 → int（认形状、不 cast）。
///
/// 第三十七轮踩到的：`{"id": "x"}` 用 `as num?` 会抛 `type 'String' is not a subtype of
/// type 'num?'`，而这个异常**不是** `BangumiException`，会把整块补充内容带走。
int _intOf(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse('${value ?? ''}') ?? 0;
}

/// 从任意响应体里挑出一组对象（裸数组 / `{data:[…]}` / `{list:[…]}`）。
///
/// 与 [_subjectsFrom] 同一套"按已知包裹键一个个试"的做法；认不出来就是空表。
List<Object?> _rowsFrom(Object? decoded) {
  if (decoded is List) return decoded;
  if (decoded is Map) {
    for (final String key in const <String>['data', 'list', 'results', 'items']) {
      final Object? value = decoded[key];
      if (value is List) return value;
    }
  }
  return const <Object?>[];
}

/// 解析 `GET /v0/subjects/{id}/characters`。
List<BangumiCharacter> parseBangumiCharacters(String body, {Uri? url}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (error) {
    throw BangumiException('Bangumi 角色响应不是合法 JSON', url: url, cause: error);
  }
  return BangumiCharacter.listFromJson(_rowsFrom(decoded));
}

/// 解析 `GET /v0/subjects/{id}/subjects`（关联条目）。
List<BangumiRelated> parseBangumiRelated(String body, {Uri? url}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (error) {
    throw BangumiException('Bangumi 关联条目响应不是合法 JSON', url: url, cause: error);
  }
  return BangumiRelated.listFromJson(_rowsFrom(decoded));
}

/// 一页 `/v0/subjects` 响应。
@immutable
class BangumiSubjectsPage {
  const BangumiSubjectsPage({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  final List<BangumiSubject> items;

  /// 全库总数（实测 29521）。
  final int total;
  final int limit;
  final int offset;
}

/// 「这里是数组吗」——**不做 hard cast**，不是数组就当空表。
///
/// 为什么必须这样：[`BangumiSubject.fromJson`] 与下面几个解析器以前写的是
/// `json['x'] as List<Object?>?`。真实的旧搜索接口
/// `/search/subject/{q}` 返回的是 `{"results":693,"list":[…]}` —— `results` 是
/// **条数（int）**，不是数组。把它按 `List<Object?>` cast 会抛
/// `type 'int' is not a subtype of type 'List<Object?>?' in type cast`，
/// 一路冒到界面就是「搜索失败：操作失败：type 'int' is not a subtype …」
/// （2026-10-12 第十七轮用户真机报的缺陷，`/tmp` 里那次实测的响应体就是
/// `{"results":693,"list":[…]}`）。鉴权/限流/改版都可能让某个字段换个类型，
/// 这里的原则是**认形状、不 cast**：不认识就当没有，绝不因为一个字段把整次查询炸掉。
List<Object?> _asListOrEmpty(Object? value) =>
    value is List ? value : const <Object?>[];

/// 从任意响应体里挑出条目数组（**按已知的包裹键一个个试**）。
///
/// * `list`  —— 旧搜索接口 `/search/subject/{q}`；
/// * `data`  —— `/v0/subjects` 与 `/v0/search/subjects`；
/// * `results` —— 只有它**自己就是数组**时才当数组用（它是 int 就是条数，忽略）；
/// * 裸数组 —— 直接就是它。
List<BangumiSubject> _subjectsFrom(Object? decoded) {
  Object? raw;
  if (decoded is List) {
    raw = decoded;
  } else if (decoded is Map) {
    for (final String key in const <String>['list', 'data', 'results', 'items']) {
      final Object? value = decoded[key];
      if (value is List) {
        raw = value;
        break;
      }
    }
  }
  return <BangumiSubject>[
    for (final Object? e in _asListOrEmpty(raw))
      if (e is Map) BangumiSubject.fromJson(e.cast<String, Object?>()),
  ];
}

/// 解析 `/v0/subjects` / `/v0/search/subjects` 的响应体。
///
/// 兼容两种形状：`{data: [...], total, limit, offset}` 与裸数组。
BangumiSubjectsPage parseBangumiSubjectsPage(String body, {Uri? url}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (error) {
    throw BangumiException('Bangumi 响应不是合法 JSON', url: url, cause: error);
  }
  if (decoded is List) {
    final List<BangumiSubject> items = _subjectsFrom(decoded);
    return BangumiSubjectsPage(
      items: items,
      total: items.length,
      limit: items.length,
      offset: 0,
    );
  }
  if (decoded is! Map) {
    throw BangumiException('Bangumi 响应结构不认识（既不是对象也不是数组）', url: url);
  }
  final Map<String, Object?> map = decoded.cast<String, Object?>();
  final List<BangumiSubject> items = _subjectsFrom(map);
  return BangumiSubjectsPage(
    items: items,
    total: (map['total'] as num?)?.toInt() ?? items.length,
    limit: (map['limit'] as num?)?.toInt() ?? items.length,
    offset: (map['offset'] as num?)?.toInt() ?? 0,
  );
}

/// 解析旧搜索接口 `GET /search/subject/{关键词}` 的响应体。
///
/// **实测形状（2026-10-12 真机 + 本地 curl）**：
/// `{"results":693,"list":[{id,name,name_cn,date,images,eps,rating,…}, …]}`
/// —— 条目在 `list` 里，`results` 是**命中条数**。
///
/// 这里也认 `data`（新接口形状）与裸数组，见 [_subjectsFrom]；`results` 是 int
/// 时**当作没给数组**，返回空候选（UI 显示「没有候选」），绝不抛类型错。
List<BangumiSubject> parseBangumiSearchResults(String body, {Uri? url}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (error) {
    throw BangumiException('Bangumi 搜索响应不是合法 JSON', url: url, cause: error);
  }
  if (decoded is! Map && decoded is! List) {
    throw BangumiException('Bangumi 搜索响应结构不认识', url: url);
  }
  return _subjectsFrom(decoded);
}

/// 解析 `GET /v0/subjects/{id}`。
///
/// ⚠️ **实测（2026-10-09 live 探针）：详情端点返回的是条目对象本身**
/// （`{"id":37254,"name":…}`），**没有** `data` 包一层 —— 早先按「一页」解析会抛
/// 「响应里没有数据」。这里三种形状都认：直接对象 / `{data:{…}}` / `{data:[…]}`。
BangumiSubject parseBangumiSubject(String body, {Uri? url}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (error) {
    throw BangumiException('Bangumi 响应不是合法 JSON', url: url, cause: error);
  }
  if (decoded is Map) {
    final Map<String, Object?> map = decoded.cast<String, Object?>();
    final Object? data = map['data'];
    if (data is Map) return BangumiSubject.fromJson(data.cast<String, Object?>());
    if (data is List && data.isNotEmpty && data.first is Map) {
      return BangumiSubject.fromJson((data.first! as Map).cast<String, Object?>());
    }
    if (map['id'] != null) return BangumiSubject.fromJson(map);
  }
  if (decoded is List && decoded.isNotEmpty && decoded.first is Map) {
    return BangumiSubject.fromJson((decoded.first! as Map).cast<String, Object?>());
  }
  throw BangumiException('Bangumi 条目响应结构不认识', url: url);
}

// ─────────────────────────────────────────────────────────────────────────────
// 全年代随机：种子 / offset / 均衡选择（纯函数，可单测）
// ─────────────────────────────────────────────────────────────────────────────

/// 默认取几个窗口（4 个远距离 offset）。
const int recommendWindowCount = 4;
const int recommendLimitPerWindow = 20;

/// 每页拉多少条（实测 limit=20 稳定）。
const int recommendPageLimit = 20;

/// 「当天种子」：同一天固定 → 当天稳定；隔天自然换批。
int recommendSeedForDate(DateTime day) =>
    day.year * 10000 + day.month * 100 + day.day;

/// `换一批` 用的递增种子。
int recommendSeedWithBatch(int baseSeed, int batch) => baseSeed + batch * 7919;

/// 算出 [windows] 个**相距较远**的随机 offset。
///
/// 做法：把全库按 id 均分成 [windows] 段，每段内随机取一个起点。
/// 这样即使两次随机都偏，也不会出现「两个窗口挨在一起 → 5 部全挤在同一年代」。
List<int> recommendOffsets({
  required int seed,
  required int total,
  int windows = recommendWindowCount,
  int limit = recommendPageLimit,
}) {
  if (windows <= 0) return const <int>[];
  final int maxOffset = max(0, total - limit);
  if (maxOffset == 0) return List<int>.filled(windows, 0, growable: false);
  final Random rng = Random(seed);
  final int band = max(1, (maxOffset + 1) ~/ windows);
  final List<int> offsets = <int>[];
  for (int i = 0; i < windows; i++) {
    final int lo = min(maxOffset, i * band);
    final int hi = min(maxOffset, (i + 1) * band);
    final int span = max(1, hi - lo);
    offsets.add(min(maxOffset, lo + rng.nextInt(span)));
  }
  return offsets;
}

/// 按窗口**均衡**抽取推荐条目 —— 防「年代聚簇」的核心。
///
/// 规则（spec §7.7）：
/// 1. 每个窗口先过滤残缺项（[BangumiSubject.isComplete]）；
/// 2. 每个窗口先各取 [perWindow] 条（窗口顺序按种子打乱）；
/// 3. 不够 [want] 再从各窗口剩余项里轮转补齐；
/// 4. 结果按上映日期升序、按 id 去重。
///
/// 候选不足 [want] 时**返回能拿到的全部**（不报错、不编数据）。
List<BangumiSubject> selectRecommendations(
  List<List<BangumiSubject>> windows, {
  required int seed,
  int want = 5,
  int perWindow = 2,
}) {
  if (want <= 0) return const <BangumiSubject>[];
  final Random rng = Random(seed);

  // 每个窗口：过滤 → 洗牌（洗牌用同一个 rng，结果只由 seed 决定）
  final List<List<BangumiSubject>> pools = <List<BangumiSubject>>[];
  for (final List<BangumiSubject> window in windows) {
    final List<BangumiSubject> pool = <BangumiSubject>[
      for (final BangumiSubject s in window)
        if (s.isComplete && s.id > 0) s,
    ];
    pool.shuffle(rng);
    pools.add(pool);
  }

  final List<BangumiSubject> picked = <BangumiSubject>[];
  final Set<int> seen = <int>{};
  void take(BangumiSubject s) {
    if (seen.add(s.id)) picked.add(s);
  }

  // 第一轮：每个窗口各取 perWindow 条（保证跨年代）
  final int firstRound = perWindow <= 0 ? 0 : perWindow;
  for (final List<BangumiSubject> pool in pools) {
    for (int i = 0; i < firstRound && i < pool.length; i++) {
      take(pool[i]);
      if (picked.length >= want) break;
    }
    if (picked.length >= want) break;
  }

  // 第二轮：轮转补齐（窗口里还有剩的）
  int cursor = firstRound;
  while (picked.length < want) {
    bool progressed = false;
    for (final List<BangumiSubject> pool in pools) {
      if (cursor < pool.length) {
        take(pool[cursor]);
        progressed = true;
        if (picked.length >= want) break;
      }
    }
    if (!progressed) break;
    cursor++;
  }

  picked.sort((BangumiSubject a, BangumiSubject b) {
    final int byDate = (a.date ?? '').compareTo(b.date ?? '');
    return byDate != 0 ? byDate : a.id.compareTo(b.id);
  });
  return List<BangumiSubject>.unmodifiable(picked);
}

/// 「抽出的条目来自几个不同窗口」——测试与诊断用。
int distinctWindowCount(
  List<BangumiSubject> picked,
  List<List<BangumiSubject>> windows,
) {
  final Set<int> hits = <int>{};
  for (int i = 0; i < windows.length; i++) {
    for (final BangumiSubject s in windows[i]) {
      if (picked.any((BangumiSubject p) => p.id == s.id)) hits.add(i);
    }
  }
  return hits.length;
}

// ─────────────────────────────────────────────────────────────────────────────
// HTTP 客户端
// ─────────────────────────────────────────────────────────────────────────────

/// Bangumi API 客户端。
///
/// * **必须带 UA**；* **请求间隔 ≥ minInterval**（默认 1100ms，实测 1.1s 可用）；
/// * 结果由调用方缓存（见 `state/bangumi_recommend.dart`）。
///
/// ⚠️ **第三十一轮**（用户 2026-10-15：「今日推荐拉取失败」）修的三处：
/// 1. **超时 25s → 45s**：真机实测同一天同一台机器，`/v0/subjects` 单次耗时在
///    **0.24s ~ 35.9s** 之间剧烈抖动（`offset=15000` 实测 35.9s、`offset=0` 实测 21s，
///    隔几分钟再打同一批又是 0.2s）—— 25s 的超时会把**正常的**慢响应当成失败。
/// 2. **失败重试一次**（只重试"抖动型"失败：网络/超时/429/5xx；4xx 参数与权限问题重试
///    没意义）。重试也过 [minInterval] 闸门，不会变成连打。
/// 3. **限速闸门改成队列式**：原来是「读 `_lastRequestAt` → 等 → 写」，两个调用同时进来
///    会读到同一个旧值、谁都不等就一起发。推荐那 4 个窗口现在是**并发**的，正好会踩到；
///    现在每个请求的**开始时刻**排在一条 Future 链上（至少隔 [minInterval]），
///    但互相不等响应。
class BangumiClient {
  BangumiClient({
    http.Client? client,
    this.baseUrl = bangumiApiBase,
    this.minInterval = const Duration(milliseconds: 1100),
    this.timeout = const Duration(seconds: 45),
    this.retries = 1,
    this.retryBackoff = const Duration(milliseconds: 800),
    DateTime Function()? clock,
  })  : _client = client ?? http.Client(),
        _clock = clock ?? DateTime.now;

  final http.Client _client;
  final String baseUrl;
  final Duration minInterval;
  final Duration timeout;

  /// 失败后最多再试几次（默认 1 = 一共两次）。
  final int retries;

  /// 两次尝试之间的等待。
  final Duration retryBackoff;
  final DateTime Function() _clock;

  DateTime? _lastRequestAt;

  /// 「发车时刻」队列：见类注释第 3 条。
  Future<void> _gate = Future<void>.value();

  /// 请求间隔闸门：串行化**开始时刻**（Bangumi 有限速），但不串行化响应。
  Future<void> _throttle() {
    final Future<void> start = _gate.then((_) async {
      final DateTime? last = _lastRequestAt;
      if (last != null) {
        final Duration waited = _clock().difference(last);
        final Duration remain = minInterval - waited;
        if (remain > Duration.zero) await Future<void>.delayed(remain);
      }
      _lastRequestAt = _clock();
    });
    // 闸门自己永远不因某次失败而卡住（`start` 的异常仍照常传回调用方）。
    _gate = start.then((_) {}, onError: (Object _) {});
    return start;
  }

  /// 这次失败值得再试一次吗？—— 网络/超时（没有状态码）、429、5xx。
  static bool _isTransient(BangumiException failure) {
    final int? code = failure.statusCode;
    if (code == null) return true;
    return code == 429 || code >= 500;
  }

  /// 取一次 JSON（失败按 [retries] 重试）。
  Future<String> _getJson(Uri url) => _json(url);

  /// `POST` 一次 JSON（动漫库的筛选搜索走这条路，第三十三轮）。
  Future<String> _postJson(Uri url, Map<String, Object?> body) =>
      _json(url, body: jsonEncode(body));

  /// GET/POST 共用的取数：限速闸门 → 请求 → 200 判定 → 抖动型失败重试。
  Future<String> _json(Uri url, {String? body}) async {
    const Map<String, String> headers = <String, String>{
      'User-Agent': bangumiUserAgent,
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
    BangumiException? last;
    for (int attempt = 0; attempt <= retries; attempt++) {
      await _throttle();
      late BangumiException failure;
      try {
        final http.Response res = await (body == null
                ? _client.get(url, headers: headers)
                : _client.post(url, headers: headers, body: body))
            .timeout(timeout);
        if (res.statusCode == 200) {
          // 响应体是 UTF-8，按字节解（`res.body` 依赖响应头 charset）。
          return utf8.decode(res.bodyBytes, allowMalformed: true);
        }
        failure = BangumiException(
          'Bangumi 返回了非 200${_whyNotOk(res)}',
          statusCode: res.statusCode,
          url: url,
        );
      } catch (error) {
        failure = BangumiException('Bangumi 请求失败（网络/超时）',
            url: url, cause: error);
      }
      last = failure;
      if (attempt >= retries || !_isTransient(failure)) break;
      await Future<void>.delayed(retryBackoff);
    }
    throw last!;
  }

  /// 4xx 的响应体里有 Bangumi 自己的理由（实测形状：`{"title":"JSON Error",
  /// "description":"Unmarshal type error: expected=[]string, got=object, field=filter.rating"}`）。
  /// 把它带上 —— 少一次"参数写错了却只看到 HTTP 400"的猜谜。
  static String _whyNotOk(http.Response res) {
    if (res.statusCode < 400 || res.statusCode >= 500) return '';
    try {
      final Object? decoded = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
      if (decoded is Map) {
        final String description = (decoded['description'] ?? '').toString().trim();
        final String title = (decoded['title'] ?? '').toString().trim();
        final String reason = description.isNotEmpty ? description : title;
        if (reason.isNotEmpty) {
          final String short = reason.length > 160 ? '${reason.substring(0, 160)}…' : reason;
          return '（$short）';
        }
      }
    } catch (_) {
      // 响应体不是 JSON：只报状态码，不猜。
    }
    return '';
  }

  /// `GET /v0/subjects?type=2&limit=&offset=`（全库分页）。
  Future<BangumiSubjectsPage> subjects({
    int limit = recommendPageLimit,
    int offset = 0,
    int type = 2,
  }) async {
    final Uri url = Uri.parse('$baseUrl/v0/subjects').replace(
      queryParameters: <String, String>{
        'type': '$type',
        'limit': '$limit',
        'offset': '$offset',
      },
    );
    return parseBangumiSubjectsPage(await _getJson(url), url: url);
  }

  /// `GET /v0/subjects/{id}`（详情：`name_cn` / `rating.score` / `tags`）。
  Future<BangumiSubject> subject(int id) async {
    final Uri url = Uri.parse('$baseUrl/v0/subjects/$id');
    return parseBangumiSubject(await _getJson(url), url: url);
  }

  /// `GET /v0/subjects/{id}/characters`（角色，第三十七轮实测 200）。
  Future<List<BangumiCharacter>> characters(int id) async {
    final Uri url = Uri.parse('$baseUrl/v0/subjects/$id/characters');
    return parseBangumiCharacters(await _getJson(url), url: url);
  }

  /// `GET /v0/subjects/{id}/subjects`（关联条目，第三十七轮实测 200）。
  Future<List<BangumiRelated>> relatedSubjects(int id) async {
    final Uri url = Uri.parse('$baseUrl/v0/subjects/$id/subjects');
    return parseBangumiRelated(await _getJson(url), url: url);
  }

  /// 搜索条目（spec §7.8 的旧接口，实测最稳）。
  ///
  /// `GET /search/subject/{keywords}?type=2&responseGroup=small&max_results=N`
  /// → 响应体交给 [parseBangumiSearchResults]（条目在 `list` 里，`results` 是条数）。
  Future<List<BangumiSubject>> searchSubjects(
    String keyword, {
    int maxResults = 10,
  }) async {
    final String q = keyword.trim();
    if (q.isEmpty) return const <BangumiSubject>[];
    final Uri url = Uri.parse(
      '$baseUrl/search/subject/${Uri.encodeComponent(q)}',
    ).replace(queryParameters: <String, String>{
      'type': '2',
      'responseGroup': 'small',
      'max_results': '$maxResults',
    });
    return parseBangumiSearchResults(await _getJson(url), url: url);
  }

  /// **动漫库用的筛选搜索**：`POST /v0/search/subjects?limit=&offset=`（第三十三轮）。
  ///
  /// 为什么是 POST 这条：`GET /v0/subjects` 不支持关键词/标签/评分筛选，而且
  /// `platform` 参数**两条路都会被忽略**（实测）。POST 这条的 `filter` 支持
  /// `type` / `tag` / `air_date` / `rating` / `rank` / `nsfw`。
  ///
  /// ⚠️ 两个实测出来的坑（都写在 [BangumiLibraryQuery] 的注释里、也有用例钉住）：
  /// * **分页只能走查询串**：body 里的 `limit`/`offset` 会被服务端忽略；
  /// * `filter.rating` 必须是**字符数组**（`[">=7"]`），写成对象直接 400。
  ///
  /// [limit] 单页条数（服务端默认 10）、[offset] 从第几条开始；`total` 封顶 1000。
  Future<BangumiSubjectsPage> searchSubjectsFiltered({
    String keyword = '',
    String sort = 'heat',
    Map<String, Object?> filter = const <String, Object?>{},
    int limit = 20,
    int offset = 0,
  }) async {
    final Uri url = Uri.parse('$baseUrl/v0/search/subjects').replace(
      queryParameters: <String, String>{
        'limit': '$limit',
        'offset': '$offset',
      },
    );
    final String body = await _postJson(url, <String, Object?>{
      'keyword': keyword.trim(),
      'sort': sort,
      'filter': filter,
    });
    return parseBangumiSubjectsPage(body, url: url);
  }

  void dispose() => _client.close();
}
