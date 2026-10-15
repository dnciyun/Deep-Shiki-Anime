/// 搜索分页测试（用户 2026-10-11：「搜索改一下，按照一页20条，可加载其他几页」；
/// 2026-10-12：「搜索页改成默认不加载，只有个搜索，搜索后才有」+「加载更多去掉」
/// + 第八轮「为什么只有 50 页，不要固定页数，加载出数据就加一页」）。
///
/// 三件事分开钉：
/// 1. **纯函数**：`searchPageSlice` / `searchAppendItems` / `searchPageNumbers`
///    的边界（空池、正好整除、最后一页不满、跳号省略、**不画末页数字**）；
/// 2. **控制器**：喂假 `SourcePort`，验证"源页 ≠ 显示页"真的成立 ——
///    mikan 一次给全部时翻页零请求、nyaa 一页几十条时只在需要时续拉、
///    取数失败不丢已经拿到的结果；
/// 3. **默认不加载**：新容器不 loaded、一条请求都不打；只有 `refresh()`（用户真的按了
///    搜索/最新）才联网；翻页只有 `goToPage` 一个入口（`loadMore` 已删除）。
library;

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 测试替身
// ─────────────────────────────────────────────────────────────────────────────

/// 造 [from]..[to] 一批条目（id 顺排，方便直接断言"第 3 页是 41-45"）。
List<SourceItemView> pagingItems(int from, int to) => <SourceItemView>[
  for (int i = from; i <= to; i++)
    SourceItemView(
      id: 'id$i',
      sourceId: 'mikan',
      title: '芙莉莲 第 $i 话 [1080p]',
      group: 'G',
      episodeHints: <String>['$i'],
    ),
];

/// 假源：把"源的**原始页**"当脚本喂进来（`pages[1]` = 原始第 1 页的条目）。
///
/// `hasNext` 由 `pages.containsKey(page + 1)` 推出来，正好复现两种真实形态：
/// * mikan：只给 `pages[1]` 一大坨 → 第 1 页就 `hasNext == false`；
/// * nyaa：`pages` 里排着好几页 → 一直 `hasNext == true`，直到最后一页。
class FakePagingSource implements SourcePort {
  FakePagingSource(this.pages);

  final Map<int, List<SourceItemView>> pages;

  /// 每个原始页被真的请求过几次（用来断言"翻页零请求"这种事）。
  final List<int> requested = <int>[];

  /// 这一页的请求直接抛错（复现"翻页时网络断了"）。
  Object? failureOnPage;

  @override
  List<SourceOption> get sources => const <SourceOption>[
    SourceOption(id: 'mikan', displayName: 'mikanani.me'),
  ];

  @override
  Future<SourcePageView> latest(String sourceId, {int page = 1}) => _page(page);

  @override
  Future<SourcePageView> search(String sourceId, String keyword, {int page = 1}) => _page(page);

  Future<SourcePageView> _page(int page) async {
    requested.add(page);
    if (failureOnPage == page) {
      throw const PortUnavailableException('源暂时不可用', hint: '稍后重试');
    }
    return SourcePageView(
      items: pages[page] ?? const <SourceItemView>[],
      page: page,
      hasNext: pages.containsKey(page + 1),
      fetchedAt: DateTime(2026, 10, 11, 12),
    );
  }
}

ProviderContainer pagingContainer(FakePagingSource source) {
  final ProviderContainer container = ProviderContainer(
    overrides: [
      keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
      sourcePortProvider.overrideWithValue(source),
    ],
  );
  // 本文件全部用例盯的是**单独源**那条路（源页 ≠ 显示页、翻页零请求、失败留在原页）。
  // 第 14 轮起默认是聚合模式（`AppSettings.searchMode` 默认 `aggregate`），这里显式切回
  // 单源：聚合那条路的分页与去重是另一套（`aggregate_test.dart` + shell 里的聚合用例）。
  container.read(searchProvider.notifier).setMode(SearchMode.single);
  return container;
}

/// 只取当前窗口的 id 列表，断言分页边界时最直观。
List<String> idsOf(SearchState state) =>
    state.items.map((SourceItemView i) => i.id).toList(growable: false);

void main() {
  group('searchPageSlice（20 条一切）', () {
    test('45 条 → 3 页：20 / 20 / 5，第 4 页空', () {
      final List<SourceItemView> all = pagingItems(1, 45);

      expect(idsIn(searchPageSlice(all, 1)), ids(1, 20));
      expect(idsIn(searchPageSlice(all, 2)), ids(21, 40));
      expect(idsIn(searchPageSlice(all, 3)), ids(41, 45), reason: '最后一页只有 5 条，不该补齐也不该丢');
      expect(searchPageSlice(all, 4), isEmpty, reason: '越界返回空表（不是抛错）：翻页与网络是异步的');
    });

    test('正好整除（40 条）→ 第 3 页空；空池一律空', () {
      final List<SourceItemView> all = pagingItems(1, 40);
      expect(searchPageSlice(all, 2).length, 20);
      expect(searchPageSlice(all, 3), isEmpty);
      expect(searchPageSlice(const <SourceItemView>[], 1), isEmpty);
    });

    test('页号非法（0 / 负数）返回空表，不炸', () {
      final List<SourceItemView> all = pagingItems(1, 45);
      expect(searchPageSlice(all, 0), isEmpty);
      expect(searchPageSlice(all, -3), isEmpty);
    });

    test('一条也不重复：三页拼起来正好等于原表', () {
      final List<SourceItemView> all = pagingItems(1, 45);
      final List<String> stitched = <String>[
        for (int p = 1; p <= 3; p++)
          ...searchPageSlice(all, p).map((SourceItemView i) => i.id),
      ];
      expect(stitched, all.map((SourceItemView i) => i.id).toList());
    });
  });

  group('searchAppendItems（池子追加去重）', () {
    test('相邻源页重叠时不重复入池', () {
      final List<SourceItemView> first = pagingItems(1, 30);
      // nyaa 的 RSS 首页与 ?p=1 经常给同一批条目：这里让第 2 页从 21 开始重叠。
      final List<SourceItemView> second = pagingItems(21, 60);
      final List<SourceItemView> merged = searchAppendItems(first, second);
      expect(merged.length, 60, reason: '重叠的 21-30 只算一次');
      expect(merged.map((SourceItemView i) => i.id).toSet().length, merged.length);
      expect(merged.last.id, 'id60', reason: '追加的是后半段，顺序不能乱');
    });

    test('空批次原样返回', () {
      final List<SourceItemView> base = pagingItems(1, 3);
      expect(searchAppendItems(base, const <SourceItemView>[]), same(base));
    });
  });

  group('searchPageNumbers（页码条）', () {
    test('页数够少就全铺', () {
      expect(searchPageNumbers(page: 1, pageCount: 3), <int?>[1, 2, 3]);
      expect(searchPageNumbers(page: 3, pageCount: 5), <int?>[1, 2, 3, 4, 5]);
    });

    test('页数多时：首页 + 当前页左右 + 省略号，**不画末页数字**', () {
      // 用户 2026-10-12 第八轮：「为什么只有 50 页，不要固定页数，加载出数据就加一页」。
      // 末页数字要真翻到才出现，右边只留一个"还有"的省略号。
      expect(searchPageNumbers(page: 1, pageCount: 9), <int?>[1, 2, null]);
      expect(searchPageNumbers(page: 5, pageCount: 9), <int?>[1, null, 4, 5, 6, null]);
      expect(searchPageNumbers(page: 9, pageCount: 9), <int?>[1, null, 8, 9]);
      expect(
        searchPageNumbers(page: 1, pageCount: 50),
        <int?>[1, 2, null],
        reason: 'mikan 一搜就是 1000 条 = 50 页，但第 1 页底部绝不能直接挂「50」',
      );
    });

    test('0 页不画东西', () {
      expect(searchPageNumbers(page: 1, pageCount: 0), isEmpty);
    });
  });

  group('SearchQueryController（源页 ≠ 显示页）', () {
    test('mikan 一次给 45 条：第 1 页 20 条、共 3 页，翻页一次网络都不打', () async {
      final FakePagingSource source = FakePagingSource(<int, List<SourceItemView>>{
        1: pagingItems(1, 45),
      });
      final ProviderContainer c = pagingContainer(source);
      addTearDown(c.dispose);
      final SearchQueryController notifier = c.read(searchProvider.notifier);

      await notifier.refresh();
      SearchState s = c.read(searchProvider);
      expect(s.items.length, 20, reason: '一页 20 条是宿主的硬约束，源给了 45 条也只显示 20');
      expect(idsOf(s).first, 'id1');
      expect(idsOf(s).last, 'id20');
      expect(s.page, 1);
      expect(s.fetched.length, 45, reason: '池子留住源给的全部条目');
      expect(s.pageCount, 3, reason: '源说没有下一页 → 按池子算 3 页');
      expect(s.hasMoreSource, isFalse);
      expect(s.canGoPrevious, isFalse);
      expect(s.canGoNext, isTrue);
      expect(source.requested, <int>[1]);

      await notifier.goToPage(2);
      s = c.read(searchProvider);
      expect(s.page, 2);
      expect(idsOf(s).first, 'id21');
      expect(idsOf(s).last, 'id40');

      // 点第 3 页：池子里已经够，同样不打网络，拿到 41-45 这 5 条。
      await notifier.goToPage(3);
      s = c.read(searchProvider);
      expect(s.page, 3);
      expect(idsOf(s), ids(41, 45));
      expect(s.canGoNext, isFalse);
      expect(source.requested, <int>[1], reason: 'mikan 一次给全部，翻页/跳页都不该再请求源');

      // 翻回第 1 页同样是零请求，且内容一致（池子没被翻页重置）。
      await notifier.goToPage(1);
      s = c.read(searchProvider);
      expect(idsOf(s), ids(1, 20));
      expect(source.requested, <int>[1]);
    });

    test('nyaa 一页 30 条：第 2 页需要更多原始条目时才续拉，重叠条目去重', () async {
      final FakePagingSource source = FakePagingSource(<int, List<SourceItemView>>{
        1: pagingItems(1, 30),
        2: pagingItems(21, 60), // 与第 1 页重叠 21-30（真实源就会这样）
      });
      final ProviderContainer c = pagingContainer(source);
      addTearDown(c.dispose);
      final SearchQueryController notifier = c.read(searchProvider.notifier);

      await notifier.refresh();
      SearchState s = c.read(searchProvider);
      expect(s.items.length, 20);
      expect(s.pageCount, 3, reason: '池子 30 条 → 已知 2 页，源还说"有" → 至少 3 页');

      await notifier.goToPage(2);
      s = c.read(searchProvider);
      expect(source.requested, <int>[1, 2], reason: '池子只有 30 条不够第 2 页（要 40 条），续拉原始第 2 页');
      expect(s.fetched.length, 60, reason: '重叠的 21-30 只算一次');
      expect(idsOf(s).length, 20);
      expect(idsOf(s).first, 'id21');
      expect(idsOf(s).last, 'id40');

      await notifier.goToPage(3);
      s = c.read(searchProvider);
      expect(idsOf(s), ids(41, 60));
      expect(source.requested, <int>[1, 2], reason: '池子已经够第 3 页，不再续拉');
      expect(s.pageCount, 3);
      expect(s.hasMoreSource, isFalse);
    });

    test('翻页只有 goToPage 一个入口（「加载更多」已删）：连翻两页同样零请求', () async {
      final FakePagingSource source = FakePagingSource(<int, List<SourceItemView>>{
        1: pagingItems(1, 100),
      });
      final ProviderContainer c = pagingContainer(source);
      addTearDown(c.dispose);
      final SearchQueryController notifier = c.read(searchProvider.notifier);

      await notifier.refresh();
      await notifier.goToPage(2);
      expect(c.read(searchProvider).page, 2);
      await notifier.goToPage(3);
      expect(c.read(searchProvider).page, 3);
      await notifier.goToPage(5);
      expect(c.read(searchProvider).page, 5);
      expect(idsOf(c.read(searchProvider)).first, 'id81');

      // 窗口永远只有 20 条：翻页不是"把后面的追加到列表里"。
      expect(c.read(searchProvider).items.length, 20);
      expect(c.read(searchProvider).pageCount, 5, reason: '100 条 = 5 页');
      expect(source.requested, <int>[1]);
    });

    test('翻页取数失败：留在原页、不丢已经拿到的 20 条，只报原因', () async {
      final FakePagingSource source = FakePagingSource(<int, List<SourceItemView>>{
        1: pagingItems(1, 30),
        2: pagingItems(31, 60),
      });
      final ProviderContainer c = pagingContainer(source);
      addTearDown(c.dispose);
      final SearchQueryController notifier = c.read(searchProvider.notifier);

      await notifier.refresh();
      source.failureOnPage = 2; // 第 2 页"网络断了"

      await notifier.goToPage(2);
      final SearchState s = c.read(searchProvider);
      expect(s.page, 1, reason: '取不到就不动页，别让用户看到一张空表');
      expect(idsOf(s), ids(1, 20), reason: '已经拿到的结果必须还在');
      expect(s.loadingPage, isFalse);
      expect(s.failure, isNotNull);
      expect(s.failure!.message, '源暂时不可用');

      // 恢复后重试同一个页码即可继续（池子没变，页码也没变）。
      source.failureOnPage = null;
      await notifier.goToPage(2);
      expect(c.read(searchProvider).page, 2);
      expect(c.read(searchProvider).failure, isNull);
    });

    test('源嘴上说"还有"却给不出内容：报"这一页没有内容"，不装成空白一页', () async {
      final FakePagingSource source = FakePagingSource(<int, List<SourceItemView>>{
        1: pagingItems(1, 20),
        2: const <SourceItemView>[], // 空页：hasNext(page1) 仍为 true
      });
      final ProviderContainer c = pagingContainer(source);
      addTearDown(c.dispose);
      final SearchQueryController notifier = c.read(searchProvider.notifier);

      await notifier.refresh();
      expect(c.read(searchProvider).pageCount, 2, reason: '源说还有 → 至少算 2 页');

      await notifier.goToPage(2);
      final SearchState s = c.read(searchProvider);
      expect(s.page, 1);
      expect(idsOf(s).length, 20);
      expect(s.failure!.message, '第 2 页没有内容');
      expect(s.hasMoreSource, isFalse, reason: '源给不出东西了，以事实为准关掉"还有"');
      expect(s.canGoNext, isFalse);
    });

    test('刷新 = 清空池子、回到第 1 页（换关键字/换源后旧条目不能留在页数里）', () async {
      final FakePagingSource source = FakePagingSource(<int, List<SourceItemView>>{
        1: pagingItems(1, 100),
      });
      final ProviderContainer c = pagingContainer(source);
      addTearDown(c.dispose);
      final SearchQueryController notifier = c.read(searchProvider.notifier);

      await notifier.refresh();
      await notifier.goToPage(4);
      expect(c.read(searchProvider).page, 4);

      // 换一批结果（模拟"改关键字后源回了另外 25 条"）。
      source.pages
        ..clear()
        ..[1] = pagingItems(1, 25);
      await notifier.refresh();

      final SearchState s = c.read(searchProvider);
      expect(s.page, 1);
      expect(s.fetched.length, 25);
      expect(s.pageCount, 2);
      expect(idsOf(s), ids(1, 20));
    });

    test('空结果：isEmpty 且只有 1 页，加载更多/下一页都禁用', () async {
      final FakePagingSource source = FakePagingSource(<int, List<SourceItemView>>{
        1: const <SourceItemView>[],
      });
      final ProviderContainer c = pagingContainer(source);
      addTearDown(c.dispose);
      final SearchQueryController notifier = c.read(searchProvider.notifier);

      await notifier.refresh();
      final SearchState s = c.read(searchProvider);
      expect(s.isEmpty, isTrue);
      expect(s.pageCount, 1, reason: '"第 1 / 1 页"比"第 1 / 0 页"更像人话');
      expect(s.canGoNext, isFalse);
      expect(s.canGoPrevious, isFalse);

      // 禁用的入口再点一次也不能偷偷发请求。
      await notifier.goToPage(2);
      expect(source.requested, <int>[1]);
    });

    test('并发重复刷新只发一次请求（源下拉 onChanged 的老毛病）', () async {
      final FakePagingSource source = FakePagingSource(<int, List<SourceItemView>>{
        1: pagingItems(1, 30),
      });
      final ProviderContainer c = pagingContainer(source);
      addTearDown(c.dispose);
      final SearchQueryController notifier = c.read(searchProvider.notifier);

      // 不 await 第一次：模拟"setSource 触发一次 + 页面显式再触发一次"。
      final Future<void> first = notifier.refresh();
      final Future<void> second = notifier.refresh();
      await Future.wait(<Future<void>>[first, second]);

      expect(source.requested, <int>[1], reason: '同一次选择不该打两次网络');
    });
  });

  // ── 2026-10-12：搜索页默认不加载 ──────────────────────────────────────────────
  group('默认不加载（用户 2026-10-12：「只有个搜索，搜索后才有」）', () {
    test('新容器：没搜过、没结果、一条网络请求都不打', () {
      final FakePagingSource source = FakePagingSource(<int, List<SourceItemView>>{
        1: pagingItems(1, 30),
      });
      final ProviderContainer c = pagingContainer(source);
      addTearDown(c.dispose);

      final SearchState s = c.read(searchProvider);
      expect(s.loaded, isFalse, reason: '不该有任何"我已经拉过了"的状态');
      expect(s.loading, isFalse);
      expect(s.fetched, isEmpty);
      expect(s.items, isEmpty);
      expect(s.pageCount, 1, reason: '"第 1 / 1 页"比"第 1 / 0 页"更像人话');
      expect(source.requested, isEmpty, reason: '默认不加载 = 进页面一条请求都不许发');
    });

    test('换源不触发加载（换源不是"要结果"的意思）', () async {
      final FakePagingSource source = FakePagingSource(<int, List<SourceItemView>>{
        1: pagingItems(1, 30),
      });
      final ProviderContainer c = pagingContainer(source);
      addTearDown(c.dispose);

      c.read(searchProvider.notifier).setSource('dmhy');
      await Future<void>.delayed(Duration.zero); // 给"万一它偷偷 refresh"一次机会

      expect(c.read(searchProvider).sourceId, 'dmhy', reason: '选择本身要生效');
      expect(c.read(searchProvider).loaded, isFalse);
      expect(source.requested, isEmpty, reason: '还没搜过就不该联网');
    });

    test('已经有结果时换源 → 顺手重查一次（旧源的结果不能挂在新源名下）', () async {
      final FakePagingSource source = FakePagingSource(<int, List<SourceItemView>>{
        1: pagingItems(1, 30),
      });
      final ProviderContainer c = pagingContainer(source);
      addTearDown(c.dispose);
      final SearchQueryController notifier = c.read(searchProvider.notifier);

      await notifier.refresh();
      expect(c.read(searchProvider).loaded, isTrue);

      notifier.setSource('dmhy');
      // setSource 内部的 refresh 是 unawaited：等它跑完再断言。
      for (int i = 0; i < 10 && c.read(searchProvider).loading; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(source.requested, <int>[1, 1], reason: '换了源就得重查一次');
      expect(c.read(searchProvider).fetched.length, 30);
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// 断言辅助
// ─────────────────────────────────────────────────────────────────────────────

List<String> ids(int from, int to) =>
    <String>[for (int i = from; i <= to; i++) 'id$i'];

List<String> idsIn(List<SourceItemView> items) =>
    items.map((SourceItemView i) => i.id).toList(growable: false);
