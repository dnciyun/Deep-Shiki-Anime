/// `NyaaSource` 的 `id` / `displayName` / `baseUrl` 可覆盖 —— 这是「sukebei 开关」（用户决策 Q4）
/// 的唯一实现路径：nyaa.si 与 sukebei.nyaa.si 共用同一套 RSS 解析，只有 host 与分类不同。
///
/// 背景（2026-10-09 Lead 实测）：
/// * `baseUrl` 本来就能传，但 `id` 硬编码成 `'nyaa'` → 第二个实例会在 `SourceRegistry`
///   与磁盘缓存里**撞 id**（`CachedSourceClient.loadPage` 用 `id` 做缓存键），于是 sukebei
///   根本注册不进去。
/// * 两个站的分类编号语义**不同**：nyaa.si `1_2` = Anime - English-translated；
///   sukebei `1_1` = Art - Anime、`1_2` = Art - Doujinshi（实测 sukebei RSS 的
///   `<nyaa:categoryId>` 已确认）。因此「不限分类」（category 留空、URL 里不带 `c` 参数）
///   必须能表达，否则拿不到全量列表。
///
/// 全部离线。
library;

import 'package:dsanima_core/sources/sources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  NyaaSource build({
    String? id,
    String? displayName,
    String baseUrl = nyaaBaseUrl,
    String category = '1_2',
  }) {
    return NyaaSource(
      http: buildHttp(textFactory('<rss version="2.0"><channel></channel></rss>')),
      cache: SourceCache(store: InMemoryKeyValueStore()),
      id: id,
      displayName: displayName,
      baseUrl: baseUrl,
      category: category,
    );
  }

  test('默认实例：id=nyaa、显示名「Nyaa（动漫区）」、baseUrl=nyaa.si（不得漂移）', () {
    final NyaaSource s = build();
    expect(s.id, 'nyaa');
    expect(s.displayName, 'Nyaa（动漫区）');
    expect(s.baseUrl, 'https://nyaa.si');
    expect(s.category, '1_2');
  });

  test('可注册第二个实例：sukebei 与 nyaa 的 id 不同（不再撞缓存键）', () {
    final NyaaSource nyaa = build();
    final NyaaSource sukebei = build(
      id: 'sukebei',
      displayName: 'sukebei（成人区）',
      baseUrl: 'https://sukebei.nyaa.si',
      category: '',
    );
    expect(sukebei.id, 'sukebei');
    expect(sukebei.id, isNot(nyaa.id));
    expect(sukebei.displayName, 'sukebei（成人区）');
    expect(sukebei.baseUrl, 'https://sukebei.nyaa.si');
    expect(sukebei.supportsSearch, isTrue);
  });

  test('RSS URL：带分类时带 c，不限分类时整个省略 c（sukebei 全量需要）', () {
    final NyaaSource scoped = build(category: '1_2');
    final NyaaSource anyCategory =
        build(baseUrl: 'https://sukebei.nyaa.si', category: '');

    final Uri scopedUri = scoped.rssUri();
    expect(scopedUri.host, 'nyaa.si');
    expect(scopedUri.queryParameters['c'], '1_2');
    expect(scopedUri.queryParameters['page'], 'rss');
    expect(scopedUri.queryParameters['f'], '0');

    final Uri anyUri = anyCategory.rssUri();
    expect(anyUri.host, 'sukebei.nyaa.si');
    expect(anyUri.queryParameters.containsKey('c'), isFalse,
        reason: 'c= 空值会被站点当成非法分类来过滤，必须整条省略');

    // 搜索关键字走同一套规则
    expect(anyCategory.rssUri(keyword: 'x').queryParameters['q'], 'x');
    expect(anyCategory.rssUri(keyword: 'x').queryParameters.containsKey('c'), isFalse);
  });

  test('HTML 搜索翻页 URL 同样跟随 baseUrl 且省略空分类', () {
    final NyaaSource scoped = build(category: '1_0');
    final NyaaSource anyCategory =
        build(baseUrl: 'https://sukebei.nyaa.si', category: '');

    final Uri s = scoped.searchHtmlUri('frieren', 2);
    expect(s.host, 'nyaa.si');
    expect(s.queryParameters['c'], '1_0');
    expect(s.queryParameters['p'], '2');

    final Uri a = anyCategory.searchHtmlUri('x', 3);
    expect(a.host, 'sukebei.nyaa.si');
    expect(a.queryParameters.containsKey('c'), isFalse);
    expect(a.queryParameters['p'], '3');
  });

  test('详情页 URL 跟随 baseUrl（sukebei 的 view 链接不能指向 nyaa.si）', () {
    final NyaaSource sukebei = build(baseUrl: 'https://sukebei.nyaa.si', category: '');
    expect(sukebei.viewUri('2171209').toString(),
        'https://sukebei.nyaa.si/view/2171209');
  });

  test('注册表能同时容纳两实例，并按 id 取回各自实例', () {
    final NyaaSource nyaa = build();
    final NyaaSource sukebei = build(
      id: 'sukebei',
      displayName: 'sukebei（成人区）',
      baseUrl: 'https://sukebei.nyaa.si',
      category: '',
    );
    final RecordingHttpFactory factory = textFactory('');
    final SourceRegistry registry = SourceRegistry(
      http: factory,
      cache: SourceCache(store: InMemoryKeyValueStore()),
      limiter: RateLimiter(
        minInterval: Duration.zero,
        clock: FakeClock(DateTime.utc(2026, 10, 8, 12)).call,
        sleep: FakeClock(DateTime.utc(2026, 10, 8, 12)).sleep,
      ),
      proxy: const ProxyConfig.none(),
    );
    addTearDown(registry.dispose);

    registry.register(nyaa);
    registry.register(sukebei);

    expect((registry.byId('nyaa') as NyaaSource?)?.baseUrl, 'https://nyaa.si');
    expect((registry.byId('sukebei') as NyaaSource?)?.baseUrl,
        'https://sukebei.nyaa.si');

    // 两个 id 必须解析到**不同实例**（防止 id 再次硬编码导致互相覆盖）
    expect(registry.byId('nyaa'), isNot(same(registry.byId('sukebei'))));
  });

  test('http 客户端在测试中不会被真实创建（工厂计数为 0 即未联网）', () {
    final RecordingHttpFactory factory = textFactory('');
    final NyaaSource s = NyaaSource(
      http: buildHttp(factory),
      cache: SourceCache(store: InMemoryKeyValueStore()),
    );
    expect(s.id, 'nyaa');
    expect(factory.createCount, 0, reason: '构造源不得触发任何网络');
    expect(factory.requestedUris, isEmpty);
  });
}
