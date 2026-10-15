/// mikan 首页「追番更新表」解析（spec §7.5）。
///
/// 主页数据源：`https://mikanani.me/`（服务端渲染，无需 JS）。
/// 结构（2026-10-09 实测，与 spec §7.5 记录一致）：
///
/// ```html
/// <div class="sk-bangumi" data-dayofweek="4">      <!-- 0=周日 … 6=周六；7=剧场版、8=OVA -->
///   <div id="data-row-4" class="row">星期四</div>
///   <div class="an-box"><ul class="list-inline an-ul">
///     <li>
///       <span data-src="/images/Bangumi/202603/712cede8.jpg?width=400&height=400&format=webp"
///             class="js-expand_bangumi b-lazy"
///             data-bangumiid="3887" data-bangumiindex="1" data-showsubscribed="false"></span>
///       <div class="an-info"><div class="an-info-group">
///         <div class="date-text">2026/10/05 更新</div>
///         <a href="/Home/Bangumi/3887" class="an-text" title="飙马野郎 JOJO的奇妙冒险 第一赛段">…</a>
///       </div></div>
///     </li>
///   </ul></div>
/// </div>
/// ```
///
/// 两个必须注意的点：
/// 1. **封面不在 `<img>` 里**，而在 `data-src`（b-lazy 懒加载）—— 只能从属性取。
/// 2. **首页没有集数**，`date-text` 只有「YYYY/MM/DD 更新」。集数要另开
///    `/Home/Bangumi/<id>` 详情页才有；本解析器**绝不伪造集数**（见 [MikanScheduleEntry]）。
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'http.dart' show ClockFn;
import 'mikan.dart';
import 'models.dart';
import 'parsing.dart';

/// 首页追番表的**单条**记录。
///
/// 与 [SourceItem] 的区别：这是一条「番剧在某天更新」的展示记录，
/// **通常不含种子/磁力**（那些在番剧详情页），所以不能直接拿来入队。
/// 想下载就先 [MikanScheduleEntry.detailUrl] 取详情页，或走订阅。
class MikanScheduleEntry {
  const MikanScheduleEntry({
    required this.bangumiId,
    required this.dayOfWeek,
    required this.title,
    required this.coverUri,
    required this.rawCover,
    required this.updateText,
    this.updatedAt,
    this.index = 0,
    this.subscribed = false,
    this.detailUrl,
  });

  /// 番剧 id（`/Home/Bangumi/<id>` 里的数字）。可能为空串（站点未给）。
  final String bangumiId;

  /// 0=周日 … 6=周六；**7 = 剧场版、8 = OVA**（mikan 自己的两个专档）。
  final int dayOfWeek;

  /// 中文番名（`a.an-text` 的 title 属性优先，回落到文本）。
  final String? title;

  /// 封面绝对 URL（已按 `baseUrl` 解析）。
  ///
  /// ⚠️ 实测 mikan 图床即使带 `format=webp` 也可能返回 WebP（RIFF 头），
  /// 缓存时**按响应内容判定扩展名**，不要一律当 `.jpg` 写。
  final Uri? coverUri;

  /// 原始 `data-src`（保留 `?width=400&height=400&format=webp` 这类参数，便于换尺寸）。
  final String rawCover;

  /// 首页原文的更新文案（如 `2026/10/05 更新`）。**没有集数**。
  final String updateText;

  /// 从 [updateText] 解析出的更新日期；解析不出为 null。
  final DateTime? updatedAt;

  /// `data-bangumiindex`：当天内的排位（1 起）。缺失为 0。
  final int index;

  /// 该条目在本机是否已订阅（站点给的 `data-showsubscribed`）。
  final bool subscribed;

  /// 番剧详情页 URL。
  final Uri? detailUrl;

  /// 是否属于 mikan 的**两个专档**（dayOfWeek 7/8）而不是星期几。
  ///
  /// 语义是"不是 0..6 的某一天"，所以它同时被用来判断"算不出还有几天更新"
  /// （见宿主 `following_view.dart` 的 `daysUntil`）。
  bool get isUnslotted => dayOfWeek > 6;

  /// 展示用星期名（0..6）。
  static const List<String> weekNames = <String>[
    '星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六',
  ];

  /// 两个专档的**站点原文名**（mikan 首页 `date-li-7` / `date-li-8` 的 `date-cn` 就是这两个词）。
  ///
  /// ⚠️ 第二十五轮修：以前 7 与 8 都显示成「未定档」（那时以为它们只是"档期未定"），
  /// 用户指出「两个未定档的日期分别是剧场版和 ova」—— 站点自己写得很清楚：
  /// ```html
  /// <li class="date-li-7" data-anchor="#data-row-7">…<div class="sk-col date-cn">剧场版</div></li>
  /// <li class="date-li-8" data-anchor="#data-row-8">…<div class="sk-col date-cn">OVA</div></li>
  /// ```
  /// 真机样本见 `core/test/fixtures/mikan_home_schedule.html` 第 1378/1416 行（`data-row-7` 正文
  /// 就是「剧场版」、`data-row-8` 是「OVA」）。展示名照抄站点，不自己起名。
  static const Map<int, String> specialDayNames = <int, String>{7: '剧场版', 8: 'OVA'};

  /// 展示用档位名：0..6 是星期几，7/8 是「剧场版 / OVA」。
  String get dayLabel => specialDayNames[dayOfWeek] ?? weekNames[dayOfWeek];

  Map<String, dynamic> toJson() => <String, dynamic>{
        'bangumiId': bangumiId,
        'dayOfWeek': dayOfWeek,
        'title': title,
        'cover': coverUri?.toString(),
        'rawCover': rawCover,
        'updateText': updateText,
        'updatedAt': updatedAt?.toIso8601String(),
        'index': index,
        'subscribed': subscribed,
        'detailUrl': detailUrl?.toString(),
      };

  static MikanScheduleEntry? fromJson(Map<String, dynamic>? m) {
    if (m == null) return null;
    final id = m['bangumiId'];
    if (id is! String) return null;
    final raw = m['rawCover'];
    return MikanScheduleEntry(
      bangumiId: id,
      dayOfWeek: (m['dayOfWeek'] as num?)?.toInt() ?? 0,
      title: m['title'] as String?,
      coverUri: m['cover'] is String ? Uri.tryParse(m['cover'] as String) : null,
      rawCover: raw is String ? raw : '',
      updateText: (m['updateText'] as String?) ?? '',
      updatedAt:
          m['updatedAt'] is String ? DateTime.tryParse(m['updatedAt'] as String) : null,
      index: (m['index'] as num?)?.toInt() ?? 0,
      subscribed: m['subscribed'] == true,
      detailUrl:
          m['detailUrl'] is String ? Uri.tryParse(m['detailUrl'] as String) : null,
    );
  }
}

/// 解析结果：按星期分组 + 平铺列表 + 可观测的丢弃计数。
class MikanSchedule {
  const MikanSchedule({
    required this.entries,
    required this.byDay,
    this.skipped = 0,
    this.warnings = const <String>[],
  });

  final List<MikanScheduleEntry> entries;

  /// key = dayOfWeek（0..6，以及 7=剧场版 / 8=OVA）→ 当天的条目（按 index 排序）。
  final Map<int, List<MikanScheduleEntry>> byDay;

  final int skipped;
  final List<String> warnings;

  bool get isEmpty => entries.isEmpty;

  /// 按「周一 → 周日 → 剧场版 → OVA」的展示顺序返回非空的天。
  List<int> get displayDays {
    const order = <int>[1, 2, 3, 4, 5, 6, 0, 7, 8];
    return order.where((d) => (byDay[d] ?? const []).isNotEmpty).toList(growable: false);
  }
}

/// 首页追番表解析器。**永不伪造字段**：解析不到的留 null / 空串，并计入 skipped。
class MikanScheduleParser {
  const MikanScheduleParser._();

  /// 解析 `https://mikanani.me/` 首页 HTML。
  ///
  /// [url] 仅用于报错定位；[baseUrl] 用于把封面/详情链接解析成绝对地址。
  static MikanSchedule parse(
    String htmlText, {
    required Uri url,
    required String sourceId,
    String baseUrl = mikanBaseUrl,
    ClockFn? clock,
  }) {
    final dom.Document doc;
    try {
      doc = html_parser.parse(htmlText);
    } catch (e) {
      throw SourceException('mikan 首页解析失败: $e', sourceId: sourceId, cause: e);
    }

    final root = Uri.parse('$baseUrl/');
    final entries = <MikanScheduleEntry>[];
    final warnings = <String>[];
    var skipped = 0;

    final blocks = doc.querySelectorAll('div.sk-bangumi');
    if (blocks.isEmpty) {
      // 与 mikan 番剧页解析同一策略：结构变了就显式报错，而不是静默返回空表
      // （静默空列表会被上层当成「今天没更新」，属于假成功）。
      throw SourceException(
        'mikan 首页结构已变：找不到 div.sk-bangumi（追番表根节点）',
        sourceId: sourceId,
        url: url,
      );
    }

    for (final block in blocks) {
      final dowRaw = block.attributes['data-dayofweek'];
      final dow = int.tryParse(dowRaw ?? '');
      if (dow == null) {
        skipped++;
        warnings.add('sk-bangumi 缺少/非法的 data-dayofweek（值: ${dowRaw ?? '空'}），整块跳过');
        continue;
      }

      // 同一天可能被拆成多个 sk-bangumi 块，全部收集后统一按 index 排序。
      for (final li in block.querySelectorAll('li')) {
        final span = li.querySelector('span[data-src], span[data-bangumiid]');
        final anchor = li.querySelector('a.an-text') ?? li.querySelector('a');
        final dateNode = li.querySelector('div.date-text');

        final rawCover = span?.attributes['data-src'] ?? '';
        final bangumiId = span?.attributes['data-bangumiid']?.trim() ?? '';
        final href = anchor?.attributes['href'];
        // title 属性优先：站点给它保留了完整中文名；文本有时被截断/加了后缀。
        final title = normalizeWhitespace(anchor?.attributes['title']) ??
            normalizeWhitespace(anchor?.text);
        final updateText = normalizeWhitespace(dateNode?.text) ?? '';

        // 关键字段全缺 → 这条没有展示价值，计入 skipped（可观测，不静默丢）
        if (rawCover.isEmpty && bangumiId.isEmpty && (title == null || title.isEmpty)) {
          skipped++;
          warnings.add('追番表某条既没有封面、也没有番剧 id 与标题，已跳过');
          continue;
        }

        entries.add(MikanScheduleEntry(
          bangumiId: bangumiId,
          dayOfWeek: dow,
          title: title,
          rawCover: rawCover,
          coverUri: rawCover.isEmpty ? null : resolveUri(root, rawCover),
          updateText: updateText,
          updatedAt: parseMikanUpdateDate(updateText),
          index: int.tryParse(span?.attributes['data-bangumiindex'] ?? '') ?? 0,
          subscribed: span?.attributes['data-showsubscribed'] == 'true',
          detailUrl: resolveUri(root, href),
        ));
      }
    }

    // 一条都没解析出来时：
    // * 连 sk-bangumi 块都没有 → 页面结构变了，抛错（上面已处理）；
    // * 有块但全是空壳 → 属于「结构认识、内容为空」，返回空表并让 skipped 说话，
    //   不要抛错，否则某个真实存在的空壳块会让整页报废。
    if (entries.isEmpty && skipped == 0) {
      throw SourceException(
        'mikan 首页追番表解析到 0 条（找到 ${blocks.length} 个 sk-bangumi 块）—— '
        '结构可能已变',
        sourceId: sourceId,
        url: url,
      );
    }

    final byDay = <int, List<MikanScheduleEntry>>{};
    for (final e in entries) {
      byDay.putIfAbsent(e.dayOfWeek, () => <MikanScheduleEntry>[]).add(e);
    }
    for (final list in byDay.values) {
      list.sort((a, b) => a.index.compareTo(b.index));
    }

    return MikanSchedule(
      entries: List<MikanScheduleEntry>.unmodifiable(entries),
      byDay: Map<int, List<MikanScheduleEntry>>.unmodifiable(byDay),
      skipped: skipped,
      warnings: List<String>.unmodifiable(warnings),
    );
  }

  /// 从 `2026/10/05 更新` / `2026-10-05 更新` 这类文案里取日期。
  ///
  /// 取不到返回 null（**不猜**）。日期按站点本地时区理解，仅用于展示排序。
  static DateTime? parseMikanUpdateDate(String? text) {
    final t = normalizeWhitespace(text);
    if (t == null || t.isEmpty) return null;
    final m = RegExp(r'(\d{4})[/\-.](\d{1,2})[/\-.](\d{1,2})').firstMatch(t);
    if (m == null) return null;
    final y = int.parse(m.group(1)!);
    final mo = int.parse(m.group(2)!);
    final d = int.parse(m.group(3)!);
    // 越界日期必须自己校验：DateTime 会「归一化」（2026-13-45 → 2027-02-18）而不是报错，
    // 那会悄悄产生错误日期。
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    final dt = DateTime(y, mo, d);
    if (dt.year != y || dt.month != mo || dt.day != d) return null;
    return dt;
  }
}
