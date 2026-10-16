/// dmhy（动漫花园，`https://www.dmhy.org/`）源（用户 2026-10-12：「添加新源」）。
///
/// * 资源站 host 用 `https://share.dmhy.org`：`www.dmhy.org` 是门户（实测
///   `www.dmhy.org/topics/list` 裸路径会返回门户首页），而 `share.dmhy.org` 的
///   `/topics/list` 正常返回列表页；带 `?keyword=` 时两边内容一致，所以统一走 share。
/// * 列表（動畫分类，`sort_id=2`）：第 1 页 `/topics/list/sort_id/2`，
///   第 N 页 `/topics/list/sort_id/2/page/N`；
/// * 搜索：`/topics/list?keyword=<q>`，第 N 页 `/topics/list/page/N?keyword=<q>`；
/// * 每页 80 条（实测），分页靠页面里的「下一頁」链接判断 —— 站点不给总页数；
/// * **为什么不用 RSS**：`/topics/rss/rss.xml` 每条的 `enclosure length="1"` 是假值
///   （照它写会把体积显示成 1 B），而且 RSS 里没有做种/完成数；HTML 列表页
///   体积、做种数、完成数、字幕组分类都齐全，代价只是要按页取。
///
/// ## 两个分区（用户 2026-10-12 第 9 轮：「分区是动漫和全集的」）
/// 站点自己的分区导航实测是：`動畫 sort_id/2` 下面挂着 **`季度全集 sort_id/31`**
/// （见 `www.dmhy.org` 列表页的 `.top_sort`）。所以这里注册**两个实例**：
/// `dmhy`（動畫）与 `dmhy-batch`（季度全集），各自带自己的 id（缓存键与条目 id 都
/// 按 id 分开，不会互相覆盖）。
///
/// 站点抓取样本见 `core/test/fixtures/dmhy_list*.html`（2026-10-12 抓取）。
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../subs/title_parser.dart';
import 'cache.dart';
import 'http.dart';
import 'models.dart';
import 'parsing.dart';
import 'source_client.dart';

/// dmhy 资源站根。
const String dmhyBaseUrl = 'https://share.dmhy.org';

/// dmhy 的「動畫」分类 id（`/topics/list/sort_id/2`）。
///
/// 和 nyaa 固定动漫区、mikan 本身就是番剧站一个道理：这是个看番/下番的工具，
/// 列表页混进日劇/音樂/遊戲只会让"最新"变得没法看。搜索**不限**分类
/// （关键字搜索在 dmhy 是全站生效的），否则搜一首 OP 会永远搜不到。
const String kDmhyAnimeSortId = '2';

/// dmhy 的「季度全集」分类 id（`/topics/list/sort_id/31`，動畫下面的子分区）。
const String kDmhyBatchSortId = '31';

/// dmhy 这次给的**不是列表页**（站点自己的错误页 / 防护页，HTTP 200）。
///
/// 为什么要单独一个类型（第四十八轮·补三）：用户报「1/7 个源没回来：
/// 动漫花园·季度全集(DMHY) —— 页面里既没有结果表，也没有它自己的分页工具条」。
/// 真机复测（`build/round48b/probe_dmhy*.py`：同一个 URL 按 1.2s 节奏连打 6 次、
/// 加上零结果 / 分页 / 各种关键字共 20 多个样本）**站点结构没变** ——
/// 每个正常的列表/搜索页都同时有结果表和 `div.nav_title`（连"0 条"的都有），
/// 而**站点自己的错误页**（404 / 500 那两页）正好是"有 `.top_sort`、没有 nav_title、
/// 没有结果表"。也就是说那一次拿到的是**一张临时页**，不是"站点改版了"，
/// 更不是"这个关键词没命中"（那是另一条分支）。
///
/// 有了这个类型，[DmhySource] 就能**只对这一种重试一次**：
/// 它是偶发的，重试一次比让用户少看一个源划算；而「0 条」是**结论**，重试只是白打一次请求。
class DmhyNotListPageException extends SourceException {
  DmhyNotListPageException(super.message, {super.sourceId, super.url});
}

class DmhySource extends CachedSourceClient {
  DmhySource({
    required super.http,
    required super.cache,
    this.baseUrl = dmhyBaseUrl,
    this.animeSortId = kDmhyAnimeSortId,
    String? id,
    String? displayName,
    super.clock,
  })  : _id = id ?? 'dmhy',
        _displayName = displayName ?? '动漫花园（DMHY）';

  final String baseUrl;

  /// 列表页用的分类 id，见 [kDmhyAnimeSortId] / [kDmhyBatchSortId]。
  final String animeSortId;

  final String _id;
  final String _displayName;

  @override
  String get id => _id;

  @override
  String get displayName => _displayName;

  @override
  bool get supportsSearch => true;

  /// 「最新」第 [page] 页（動畫分类）。
  Uri latestUri(int page) => page <= 1
      ? Uri.parse('$baseUrl/topics/list/sort_id/$animeSortId')
      : Uri.parse('$baseUrl/topics/list/sort_id/$animeSortId/page/$page');

  /// 搜索第 [page] 页。
  ///
  /// 关键字走 `queryParameters`（UTF-8 百分号编码由 Uri 负责），绝不手工拼字符串 ——
  /// 中文关键字手工拼会漏编码，站点会当成乱码关键字。
  ///
  /// **必须带站点自己的分区参数 `sort_id`**（用户 2026-10-12 第二十四轮：
  /// 「修复其他无法只搜索全集的bug（还是会搜到单集）」）：
  /// 不带 `sort_id` 的搜索是**全站**搜索（日劇/音樂/遊戲/綜藝全在里面），
  /// 于是「季度全集」那个实例的搜索出来的绝大部分是单集。
  /// 真机实测（`build/probe-scope/probe-scope-filters.log`，关键词「蜡笔小新」）：
  ///
  /// | URL | 条数 | 合集 | 单集 |
  /// |---|---|---|---|
  /// | `/topics/list?keyword=…`（旧实现） | 80 | 0 | 13（其余认不出，也都是单集） |
  /// | `…&sort_id=31`（用户给的 URL） | 21 | 12 | 0 |
  /// | `…&sort_id=2`（動畫） | 80 | 0 | 13 |
  ///
  /// 所以两个实例都带上自己的分区：`dmhy` → 2（動畫）、`dmhy-batch` → 31（季度全集）。
  Uri searchUri(String keyword, int page) {
    final Uri base = page <= 1
        ? Uri.parse('$baseUrl/topics/list')
        : Uri.parse('$baseUrl/topics/list/page/$page');
    return base.replace(
      queryParameters: <String, String>{
        'keyword': keyword,
        'sort_id': animeSortId,
      },
    );
  }

  @override
  Future<SourcePage> latest({int page = 1}) async {
    if (page < 1) {
      throw SourceException('page 必须 >= 1（收到 $page）', sourceId: id);
    }
    return loadPage(
      request: CacheRequest.latest(page: page),
      fetch: () async {
        final outcome = await _loadParsed(latestUri(page));
        return SourcePage(
          items: outcome.items,
          hasNext: outcome.hasNext,
          page: page,
          fetchedAt: clock(),
        );
      },
    );
  }

  @override
  Future<SourcePage> search(String keyword, {int page = 1}) async {
    final q = keyword.trim();
    if (q.isEmpty) {
      throw SourceException('搜索关键字不能为空', sourceId: id);
    }
    if (page < 1) {
      throw SourceException('page 必须 >= 1（收到 $page）', sourceId: id);
    }
    return loadPage(
      request: CacheRequest.search(q, page: page),
      fetch: () async {
        final outcome = await _loadParsed(searchUri(q, page), keyword: q);
        return SourcePage(
          items: outcome.items,
          hasNext: outcome.hasNext,
          page: page,
          fetchedAt: clock(),
        );
      },
    );
  }

  /// 抓一页并解析；**「不是列表页」自动重试一次**（第四十八轮·补三，见
  /// [DmhyNotListPageException] 的类注释）。
  ///
  /// * 只重试这一种：偶发的临时页（站点自己的错误页 / 防护页）重试一次通常就好了 ——
  ///   代价只有限速器那 1.2s（同 host 两次请求的**开始**时刻本来就至少隔这么久）；
  /// * 「这一页 0 条」**不重试**：那是结论，再打一次还是 0 条；
  /// * 「结构变了」在重试后照旧抛出去给用户看 —— 只是文案不再把偶发页面说成改版。
  Future<ParseOutcome> _loadParsed(Uri uri, {String? keyword}) async {
    for (int attempt = 0; ; attempt++) {
      final String body = await http.getText(uri, sourceId: id);
      try {
        return DmhyListParser.parse(
          body,
          sourceId: id,
          baseUrl: baseUrl,
          clock: clock,
          keyword: keyword,
          pageUri: uri,
        );
      } on DmhyNotListPageException catch (e) {
        if (attempt >= 1) {
          throw DmhyNotListPageException(
            '${e.message}（已自动重试一次，两次都是这个页面）',
            sourceId: id,
            url: uri,
          );
        }
      }
    }
  }

  /// `/topics/view/725809_xxx.html` → `725809`。
  ///
  /// 前缀是「源 id + `:`」，所以 `dmhy` 与 `dmhy-batch` 两个分区各自生成不同的条目 id。
  static String? topicIdOf(SourceItem item) {
    final fromId = RegExp(r'^dmhy[^:]*:(\d+)$').firstMatch(item.id);
    if (fromId != null) return fromId.group(1);
    final path = item.detailUrl?.path ?? '';
    return RegExp(r'/topics/view/(\d+)').firstMatch(path)?.group(1);
  }
}

/// dmhy 列表页（`table#topic_list`）解析器。
///
/// 列顺序（实测，2026-10-12，表头就在上面一行）：
/// `0 張貼日期 | 1 分類 | 2 標題 | 3 磁鏈(磁力) | 4 大小 | 5 種子(seeders) |
/// 6 下載(leechers) | 7 完成(downloads) | 8 發佈人`。
///
/// ⚠️ **做种数按"列的位置"取，不按 CSS 类名取**：站点把第 5 列（表头「種子」）的数字包在
/// `span.btl_N` 里、第 6 列（表头「下載」）包在 `span.bts_N` 里 —— 类名读起来像
/// "bt leechers / bt seeders"，与列的位置**正好相反**；样式表还把 `bts_1` 涂绿、
/// `btl_1` 涂蓝（绿=种子），进一步误导。判定依据是两条独立证据：
/// 1. 站点自己的表头「種子」「下載」就压在这两列上（列错位会被站点排序功能暴露）；
/// 2. 社区里成熟的 qBittorrent 搜索插件（`diazchika/dmhy`）也是按列的位置取
///    "第 6 格 = seeds、第 7 格 = leech"（1-based）。
/// 所以 `seeders = cells[5]`、`leechers = cells[6]`。**别照着类名改回去**。
///
/// ⚠️ **第二十二轮：区分「这一页没有结果」与「站点改版了」**（用户报「2/11 个源没回来」，
/// 报错文案却是"HTML 结构已变"）。真机实测（`build/probe-dmhy/probe-dmhy-shapes.log`）：
/// dmhy 的**所有**列表/搜索页 —— 有结果的、**零结果的**、连不存在的 `sort_id` —— 都有
/// 站点自己的 `div.nav_title`（那条"最近一天 / 最近一週"的工具条）；被换掉的错误页或
/// 门户页没有它。所以：**骨架在而结果表不在 = 站点正常、这一页 0 条**；
/// **骨架也不在 = 才说"结构可能已改版"**。两种都仍然报错（用户选定：0 条也要看得见），
/// 但必须说成两件不同的事，否则用户会把"关键字没命中"当成"站点坏了"。
///
/// ⚠️ **第四十八轮·补三：骨架不在时再分两种**（用户又报了一次同样的文案，这次是
/// 「1/7 个源没回来：动漫花园·季度全集(DMHY)」）。二十多个真机样本（`build/round48b/`）
/// 复现不出"正常的列表页却没有 nav_title"—— **站点结构没变**；反倒是站点**自己的错误页**
/// （404 / 500）正好长成"有 `.top_sort`、没有 nav_title、没有结果表"。
/// 所以骨架不在时：站点标记还在 → 「站点给了张临时页（偶发）」；连站点标记都没有 →
/// 「根本没到 dmhy（代理 / 防护页）」。两种都抛 [DmhyNotListPageException]，
/// 让 [DmhySource] 先自动重试一次，仍失败才把这条文案交给用户。
class DmhyListParser {
  const DmhyListParser._();

  static ParseOutcome parse(
    String htmlText, {
    required String sourceId,
    String baseUrl = dmhyBaseUrl,
    required ClockFn clock,
    String? keyword,
    Uri? pageUri,
  }) {
    final dom.Document doc;
    try {
      doc = html_parser.parse(htmlText);
    } catch (e) {
      throw SourceException('dmhy 列表页解析失败: $e', sourceId: sourceId, cause: e);
    }
    final Uri where = pageUri ?? Uri.parse(baseUrl);

    final table = doc.querySelector('table#topic_list') ??
        doc.querySelector('table.tablesorter');
    if (table == null) {
      // **不返回空列表**：0 条和"页面结构变了"对用户是两件事，静默空表会把后者伪装成前者。
      // 但也**不能把 0 条说成"结构已变"** —— 那正是第二十二轮用户报的那条假警报。
      // （fetch 层只把 2xx 的响应送到这里，所以下面写 HTTP 200 是准确的。）
      final String head = keyword == null ? 'dmhy 这一页' : 'dmhy 搜索「$keyword」';
      if (_looksLikeDmhyListPage(doc)) {
        final String why =
            keyword == null ? '这个分类下暂无内容' : '这个关键字在 dmhy 上没有命中';
        throw SourceException(
          '$head没有结果（0 条）：站点页面是正常的（它自己的分页工具条在），'
          '是$why —— 不是页面改版（HTTP 200）',
          sourceId: sourceId,
          url: where,
        );
      }
      // 第四十八轮·补三：骨架（分页工具条）不在，就**别急着说"改版"**。
      //
      // 真机复测（`build/round48b/`，20 多个样本）：正常的列表/搜索页 —— 有结果的、
      // 零结果的、`sort_id` 不存在的 —— 全都带 `div.nav_title`；只有**站点自己的
      // 错误页**（404 / 500 那两页）是"有 `.top_sort`、没有 nav_title、没有结果表"。
      // 也就是说这种情况多半是**站点临时给了张不是列表页的页面**（偶发），
      // 所以这里换成一个能行动的文案：[DmhySource] 会先重试一次，仍失败才让用户看到它。
      final String title = _pageTitle(doc);
      final String tail = title.isEmpty ? '' : '，页面标题「$title」';
      throw DmhyNotListPageException(
        _looksLikeDmhySite(doc)
            ? '$head没回列表页（HTTP 200）：站点自己的东西在（分类导航 / 搜索框都在），'
              '但既没有结果表，也没有它自己的分页工具条$tail —— '
              '真 0 条时站点会带上那条工具条，所以这多半是站点临时抽风或被防护页挡了'
              '（也可能列表页换了骨架）。过几分钟再点一次；一直这样的话把这一条反馈给我'
            : 'dmhy 这次回的根本不是 dmhy 的页面（HTTP 200）$tail —— '
              '像是代理 / 防护页 / 被换站。过几分钟再点一次；'
              '一直这样的话把这一条反馈给我',
        sourceId: sourceId,
        url: where,
      );
    }

    final base = Uri.parse('$baseUrl/');
    final items = <SourceItem>[];
    var skipped = 0;
    final warnings = <String>[];

    for (final row in table.querySelectorAll('tr')) {
      final cells = row.querySelectorAll('td');
      if (cells.isEmpty) continue; // 表头（<th>）行
      if (cells.length < 8) {
        skipped++;
        warnings.add('某行只有 ${cells.length} 个单元格（期望 8），已跳过');
        continue;
      }

      final anchor = cells[2].querySelector('a[href*="/topics/view/"]') ??
          cells[2].querySelector('a');
      final href = anchor?.attributes['href'] ?? '';
      final title = normalizeWhitespace(anchor?.text) ?? '';
      final topicId =
          RegExp(r'/topics/view/(\d+)').firstMatch(href)?.group(1);
      if (topicId == null || title.isEmpty) {
        skipped++;
        warnings.add('某行找不到 /topics/view/<id> 或标题为空，已跳过');
        continue;
      }

      // 磁力：优先**带 tracker** 的那条（base32 btih 换成 hex），退化到不带 tracker
      // 的 hex 那条。两条都没有也能建条目（id/标题是稳的），只是播不了 ——
      // 与其它源一致：不给假磁力，播放按钮自己会显示「无磁力链」。
      final arrow = _magnetOf(cells[3], 'a.arrow-magnet');
      final dlx = _magnetAttribute(cells[3], 'a.download-xl', 'data-magnet');
      final magnet = magnetWithHexInfoHash(arrow) ??
          magnetWithHexInfoHash(dlx) ??
          extractMagnet(arrow) ??
          extractMagnet(dlx);

      final sizeText = normalizeWhitespace(cells[4].text);
      final dateText = _firstDate(cells[0].text);
      final parsed = TitleParser.parse(title, sourceId: sourceId);
      // 站点自己的**字幕组**字段（第四十五轮实测加上的）：列表行标题单元格里那个
      // `a[href*="/topics/list/team_id/"]` 的文本就是组名（`云光字幕组` / `LoliHouse` /
      // `动漫国字幕组`）。实测 80 行里 62~68 行有它，且**文本从来不为空**。
      //
      // 为什么优先信它而不是标题前导方括号：方括号里那个 token 常常是**发布者**，
      // 而这个链接是站点登记的团队（dmhy 的 `/topics/list/team_id/<id>` 页就按它归类）。
      // 解析不出来才退回标题（不少个人发布没有 team，只有方括号）。
      final String? siteGroup = normalizeWhitespace(
        row.querySelector('a[href*="/topics/list/team_id/"]')?.text,
      );

      items.add(SourceItem(
        id: '$sourceId:$topicId',
        sourceId: sourceId,
        title: title,
        detailUrl: resolveUri(base, href),
        // 列表行里没有 `.torrent` 直链（只有磁力与站内跳转），不猜。
        torrentUrl: null,
        magnet: magnet,
        infoHash: infoHashFromMagnet(magnet),
        sizeBytes: parseSizeToBytes(sizeText),
        seeders: _counter(cells[5]),
        leechers: _counter(cells[6]),
        downloads: parseIntLoose(normalizeWhitespace(cells[7].text)),
        publishedAt: parseFeedDate(dateText),
        category: normalizeWhitespace(cells[1].text),
        group: siteGroup ?? parsed.group,
        episodeHints: parsed.episodeHints,
        extra: <String, dynamic>{
          ...parsed.toExtra(),
          'sizeText': ?sizeText,
          'publishedText': ?dateText,
          'siteGroup': ?siteGroup,
          if (cells.length > 8)
            'uploader': ?normalizeWhitespace(cells[8].text),
          'fromHtmlList': true,
        },
      ));
    }

    return ParseOutcome(
      items: items,
      hasNext: _hasNextPage(doc),
      skipped: skipped,
      warnings: warnings,
    );
  }

  /// 这一页是不是站点自己的列表/搜索页骨架。
  ///
  /// 判据 = `div.nav_title`（分页 + "最近一天/最近一週/订阅这个分类"那一条工具条）。
  /// 真机实测它在**所有**列表/搜索页都在：有结果的、零结果的、不存在的 `sort_id` 都有；
  /// 而被换掉的错误页/门户页没有（见本类的类注释）。
  static bool _looksLikeDmhyListPage(dom.Document doc) =>
      doc.querySelector('div.nav_title') != null;

  /// 这一页**是不是 dmhy 自己的页面**（不管它是不是列表页）。
  ///
  /// 三个独立标记取"任意一个"（第四十八轮·补三真机实测，`build/round48b/`）：
  /// `.top_sort` 那排分类导航、搜索框 `input[name=keyword]`、站点名。
  /// 站点自己的 404 / 500 页**三个都在**，而代理 / 防护页一个都没有 ——
  /// 文案据此分开说"站点给了张怪页"与"根本没到 dmhy"。
  static bool _looksLikeDmhySite(dom.Document doc) =>
      doc.querySelector('.top_sort') != null ||
      doc.querySelector('input[name="keyword"]') != null ||
      _pageTitle(doc).contains('動漫花園');

  /// 页面 `<title>`（诊断用：反馈时带上它，一眼能看出那是张什么页面）。
  static String _pageTitle(dom.Document doc) =>
      normalizeWhitespace(doc.querySelector('head title')?.text) ?? '';

  /// 取某个选择器的 `href`（`a.arrow-magnet` 的磁力就在 href 上）。
  static String? _magnetOf(dom.Element cell, String selector) =>
      cell.querySelector(selector)?.attributes['href'];

  /// 取某个选择器的自定义属性（`a.download-xl` 的 hex 磁力在 `data-magnet` 上）。
  static String? _magnetAttribute(
    dom.Element cell,
    String selector,
    String attribute,
  ) =>
      cell.querySelector(selector)?.attributes[attribute];

  /// 做种/下载数：数字包在 `span.bt*_N` 里，没有 span 就退回整格文本。
  static int? _counter(dom.Element cell) =>
      parseIntLoose(normalizeWhitespace(cell.querySelector('span')?.text)) ??
      parseIntLoose(normalizeWhitespace(cell.text));

  /// `2026/08/28 05:32`（只看第一次出现的那个）。
  ///
  /// 为什么不能直接拿整格文本：日期格里除了可见日期，还有一个 `display:none` 的 span
  /// 写着**同一份**日期（站点给排序脚本用的），`Element.text` 会把两份拼起来
  /// （`2026/08/28 05:32 2026/08/28 05:32`）—— 而 [parseFeedDate] 认不出这种形状，
  /// 发布时间会整列变成 null。这里只取第一次出现的日期。
  static final RegExp _datePattern =
      RegExp(r'\d{4}/\d{1,2}/\d{1,2}\s+\d{1,2}:\d{2}(?::\d{2})?');

  static String? _firstDate(String? cellText) {
    if (cellText == null) return null;
    final m = _datePattern.firstMatch(cellText);
    return m?.group(0);
  }

  /// 有没有「下一頁」。
  ///
  /// 为什么只看这个链接存在与否：dmhy 的翻页条是 `上一頁 第N頁 下一頁`，
  /// 到最后一页时**「下一頁」这个链接根本不输出**（没有 `disabled` 类可判）。
  static bool _hasNextPage(dom.Document doc) {
    for (final a in doc.querySelectorAll('a')) {
      final text = normalizeWhitespace(a.text) ?? '';
      if (!text.contains('下一頁')) continue;
      if ((a.attributes['href'] ?? '').isNotEmpty) return true;
    }
    return false;
  }
}
