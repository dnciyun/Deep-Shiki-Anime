/// 搜索页「字幕组筛选」的状态与页面测试（第四十五轮）。
///
/// 用户原话：「在搜索中加入字幕组筛选」，并在问答里逐条定下口径：
/// * 筛的是**已经取到的池子**（客户端，不重新发请求），多选 = **并集**；
/// * **池子级**：页码、页数、当前窗口都按筛选后的条数算；
/// * 筛完**不够一页就自动去源站续拉**，上限复用现有的 8 轮（单源）/ 3 轮（聚合），
///   用完了给「继续加载更多结果」；
/// * 勾选**落盘记住**，换关键字 / 切档 / 改源勾选之后都保留。
///
/// 这一层钉的是"用户能看见的后果"：`visible` / `items` / `pageCount` 的口径、
/// 自动续拉真的打了网络且会停手、以及页面上的 chip → 面板 → 结果这三步。
library;

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/subtitle_groups.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/ui/search_page.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 测试替身
// ─────────────────────────────────────────────────────────────────────────────

/// 假源：按**原始页**喂脚本（`pages[1]` = 原始第 1 页），`hasNext` 由 `pages` 推出来。
class _FakeSource implements SourcePort {
  _FakeSource(this.pages);

  final Map<int, List<SourceItemView>> pages;

  /// 每个原始页被真的请求过几次（断言"自动续拉"与"停手"都靠它）。
  final List<int> requested = <int>[];

  @override
  List<SourceOption> get sources => const <SourceOption>[
    SourceOption(id: 'mikan', displayName: 'mikanani.me'),
  ];

  @override
  Future<SourcePageView> latest(String sourceId, {int page = 1}) => _page(page);

  @override
  Future<SourcePageView> search(String sourceId, String keyword, {int page = 1}) =>
      _page(page);

  Future<SourcePageView> _page(int page) async {
    requested.add(page);
    return SourcePageView(
      items: pages[page] ?? const <SourceItemView>[],
      page: page,
      hasNext: pages.containsKey(page + 1),
      fetchedAt: DateTime(2026, 10, 16, 12),
    );
  }
}

SourceItemView _item(int i, String? group) => SourceItemView(
  id: 'id$i',
  sourceId: 'mikan',
  title: '芙莉莲 第 $i 话',
  group: group,
  magnet: 'magnet:?xt=urn:btih:id$i',
  infoHash: 'id$i',
  episodeHints: <String>['$i'],
);

/// 让"没被 await 的那条异步链"（`setGroupFilter` 里 unawaited 的自动续拉、
/// 落盘）跑完。假源是即时的，几轮事件循环足够。
Future<void> settle() async {
  for (int i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

ProviderContainer _containerFor(_FakeSource source, {InMemoryKeyValueStore? store}) {
  final ProviderContainer container = ProviderContainer(
    overrides: [
      keyValueStoreProvider.overrideWithValue(store ?? InMemoryKeyValueStore()),
      sourcePortProvider.overrideWithValue(source),
    ],
  );
  // 本文件的池子口径用例都走**单独源**那条路（顺序就是源给的顺序，断言最好读）。
  // 聚合那条路的筛选口径是同一份代码（`visible`），另有页面用例覆盖。
  container.read(searchProvider.notifier).setMode(SearchMode.single);
  return container;
}

void main() {
  group('池子级口径', () {
    test('筛选改变 visible / items / pageCount；不够一页就自动续拉并填满', () async {
      final _FakeSource src = _FakeSource(<int, List<SourceItemView>>{
        1: <SourceItemView>[
          for (int i = 1; i <= 10; i++) _item(i, '桜都字幕组'),
          for (int i = 11; i <= 15; i++) _item(i, 'LoliHouse'),
        ],
        2: <SourceItemView>[for (int i = 16; i <= 25; i++) _item(i, '桜都字幕组')],
      });
      final ProviderContainer c = _containerFor(src);
      addTearDown(c.dispose);

      await c.read(searchProvider.notifier).refresh();
      expect(c.read(searchProvider).fetched.length, 15);
      expect(src.requested, <int>[1]);

      c.read(searchProvider.notifier).setGroupFilter(<String>{'桜都'});
      await settle();

      final SearchState s = c.read(searchProvider);
      expect(s.groupFilter, <String>{'桜都'});
      expect(s.visible.length, 20, reason: '筛完只有 10 条 → 自动往后拉，直到填满这一页');
      expect(s.items.length, 20);
      expect(s.pageCount, 1, reason: '页数按**筛选后**的 20 条算（不是池子的 25 条）');
      expect(src.requested, <int>[1, 2], reason: '填满就停，不会把源搬空');
      expect(s.filtering, isTrue);
    });

    test('翻到第 2 页后换筛选：回到第 1 页（页码不会停在筛选后不存在的页上）', () async {
      final _FakeSource src = _FakeSource(<int, List<SourceItemView>>{
        1: <SourceItemView>[for (int i = 1; i <= 30; i++) _item(i, 'LoliHouse')],
        2: <SourceItemView>[for (int i = 31; i <= 40; i++) _item(i, 'LoliHouse')],
      });
      final ProviderContainer c = _containerFor(src);
      addTearDown(c.dispose);
      await c.read(searchProvider.notifier).refresh();
      await c.read(searchProvider.notifier).goToPage(2);
      expect(c.read(searchProvider).page, 2);

      c.read(searchProvider.notifier).setGroupFilter(<String>{'lolihouse'});
      await settle();
      expect(c.read(searchProvider).page, 1);
      expect(c.read(searchProvider).items.length, 20);
    });
  });

  group('续拉的边界', () {
    test('某原始页一条都没命中就停手（不为一个冷门组白拉满 8 轮）', () async {
      final _FakeSource src = _FakeSource(<int, List<SourceItemView>>{
        1: <SourceItemView>[
          for (int i = 1; i <= 5; i++) _item(i, '桜都字幕组'),
          for (int i = 6; i <= 10; i++) _item(i, 'LoliHouse'),
        ],
        2: <SourceItemView>[for (int i = 11; i <= 20; i++) _item(i, 'LoliHouse')],
        3: <SourceItemView>[for (int i = 21; i <= 30; i++) _item(i, 'LoliHouse')],
      });
      final ProviderContainer c = _containerFor(src);
      addTearDown(c.dispose);
      await c.read(searchProvider.notifier).refresh();

      c.read(searchProvider.notifier).setGroupFilter(<String>{'桜都'});
      await settle();

      final SearchState s = c.read(searchProvider);
      expect(s.visible.length, 5);
      expect(src.requested, <int>[1, 2], reason: '第 2 页没有新增命中 → 停手');
      expect(s.hasMoreSource, isTrue, reason: '源嘴上还有，只是我们不再白拉');
    });

    test('「继续加载更多结果」明知上一轮已用完上限也再拉一轮', () async {
      final _FakeSource src = _FakeSource(<int, List<SourceItemView>>{
        1: <SourceItemView>[
          _item(1, '桜都字幕组'),
          for (int i = 2; i <= 10; i++) _item(i, 'LoliHouse'),
        ],
        2: <SourceItemView>[for (int i = 11; i <= 20; i++) _item(i, 'LoliHouse')],
        3: <SourceItemView>[_item(21, '桜都字幕组')],
      });
      final ProviderContainer c = _containerFor(src);
      addTearDown(c.dispose);
      await c.read(searchProvider.notifier).refresh();
      c.read(searchProvider.notifier).setGroupFilter(<String>{'桜都'});
      await settle();
      expect(src.requested, <int>[1, 2]);

      await c.read(searchProvider.notifier).loadMoreForFilter();
      expect(src.requested, <int>[1, 2, 3], reason: '用户明确要更多 → 再拉一轮');
      expect(c.read(searchProvider).visible.length, 2);
    });

    test('一条都没命中：emptyAfterFilter 为真，但那不是「什么都没搜到」', () async {
      final _FakeSource src = _FakeSource(<int, List<SourceItemView>>{
        1: <SourceItemView>[for (int i = 1; i <= 10; i++) _item(i, 'LoliHouse')],
      });
      final ProviderContainer c = _containerFor(src);
      addTearDown(c.dispose);
      await c.read(searchProvider.notifier).refresh();

      c.read(searchProvider.notifier).setGroupFilter(<String>{'桜都'});
      await settle();

      final SearchState s = c.read(searchProvider);
      expect(s.visible, isEmpty);
      expect(s.emptyAfterFilter, isTrue);
      expect(s.isEmpty, isFalse, reason: '池子里有 10 条，只是没命中勾的组');
      expect(s.items, isEmpty);
    });

    test('未知组那一档：勾它就只看组名解析不出来的条目', () async {
      final _FakeSource src = _FakeSource(<int, List<SourceItemView>>{
        1: <SourceItemView>[
          _item(1, '桜都字幕组'),
          _item(2, null),
          _item(3, '搬运'),
        ],
      });
      final ProviderContainer c = _containerFor(src);
      addTearDown(c.dispose);
      await c.read(searchProvider.notifier).refresh();
      c.read(searchProvider.notifier).setGroupFilter(
        <String>{kUnknownSubtitleGroupKey},
      );
      await settle();
      expect(c.read(searchProvider).visible.map((SourceItemView i) => i.id), <String>['id2', 'id3']);
    });
  });

  group('状态怎么活', () {
    test('落盘记住：勾选与「最近用过」都写进设置，新容器（同 store）读得回来', () async {
      final _FakeSource src = _FakeSource(<int, List<SourceItemView>>{
        1: <SourceItemView>[_item(1, '桜都字幕组')],
      });
      final InMemoryKeyValueStore store = InMemoryKeyValueStore();
      final ProviderContainer first = _containerFor(src, store: store);
      addTearDown(first.dispose);
      await first.read(searchProvider.notifier).refresh();
      first.read(searchProvider.notifier).setGroupFilter(<String>{'桜都'});
      await settle();
      expect(first.read(settingsProvider).subtitleGroupFilter, <String>['桜都']);
      expect(first.read(settingsProvider).recentSubtitleGroups, contains('桜都'));

      // 新容器 = 下次启动。
      final ProviderContainer second = _containerFor(src, store: store);
      addTearDown(second.dispose);
      expect(second.read(searchProvider).groupFilter, <String>{'桜都'});
    });

    test('换源 / 切档 不会把筛选丢掉（两处是新建 state，不是 copyWith）', () async {
      final _FakeSource src = _FakeSource(<int, List<SourceItemView>>{
        1: <SourceItemView>[_item(1, '桜都字幕组')],
      });
      final ProviderContainer c = _containerFor(src);
      addTearDown(c.dispose);
      c.read(searchProvider.notifier).setGroupFilter(<String>{'桜都'});
      c.read(searchProvider.notifier).setSource('dmhy');
      expect(c.read(searchProvider).groupFilter, <String>{'桜都'});
      c.read(searchProvider.notifier).setMode(SearchMode.aggregate);
      expect(c.read(searchProvider).groupFilter, <String>{'桜都'});
    });

    test('清空筛选：一条都不勾 = 不限，池子全回来', () async {
      final _FakeSource src = _FakeSource(<int, List<SourceItemView>>{
        1: <SourceItemView>[_item(1, '桜都字幕组'), _item(2, 'LoliHouse')],
      });
      final ProviderContainer c = _containerFor(src);
      addTearDown(c.dispose);
      await c.read(searchProvider.notifier).refresh();
      c.read(searchProvider.notifier).setGroupFilter(<String>{'桜都'});
      await settle();
      expect(c.read(searchProvider).visible.length, 1);

      c.read(searchProvider.notifier).clearGroupFilter();
      await settle();
      expect(c.read(searchProvider).groupFilter, isEmpty);
      expect(c.read(searchProvider).visible.length, 2);
      expect(c.read(searchProvider).filtering, isFalse);
    });

    test('toggleGroup：再点一下同一个组就是取消（并集语义下唯一自然的交互）', () {
      final _FakeSource src = _FakeSource(<int, List<SourceItemView>>{});
      final ProviderContainer c = _containerFor(src);
      addTearDown(c.dispose);
      c.read(searchProvider.notifier).toggleGroup('桜都');
      expect(c.read(searchProvider).groupFilter, <String>{'桜都'});
      c.read(searchProvider.notifier).toggleGroup('lolihouse');
      expect(c.read(searchProvider).groupFilter, <String>{'桜都', 'lolihouse'});
      c.read(searchProvider.notifier).toggleGroup('桜都');
      expect(c.read(searchProvider).groupFilter, <String>{'lolihouse'});
    });
  });

  group('页面', () {
    Widget harness(_FakeSource src, InMemoryKeyValueStore store) => ProviderScope(
      overrides: [
        keyValueStoreProvider.overrideWithValue(store),
        sourcePortProvider.overrideWithValue(src),
      ],
      child: MaterialApp(
        theme: buildDsanimaTheme(),
        home: const Scaffold(body: SearchPage()),
      ),
    );

    Future<void> searchOnce(WidgetTester tester) async {
      await tester.enterText(find.byType(TextField).first, '芙莉莲');
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
    }

    testWidgets('chip → 面板 → 只剩勾中的组；提示行与「清空筛选」都在', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final _FakeSource src = _FakeSource(<int, List<SourceItemView>>{
        1: <SourceItemView>[
          _item(1, '桜都字幕组'),
          _item(2, 'LoliHouse'),
          _item(3, '喵萌奶茶屋'),
          _item(4, null),
        ],
      });
      final InMemoryKeyValueStore store = InMemoryKeyValueStore(<String, Object?>{
        SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
      });
      await tester.pumpWidget(harness(src, store));
      await searchOnce(tester);
      // 四条都在（筛选没开）。
      for (int i = 1; i <= 4; i++) {
        expect(find.text('芙莉莲 第 $i 话'), findsOneWidget);
      }

      // 「全选本页」先勾上 4 条，稍后验"筛选把看不见的勾去掉"。
      await tester.tap(find.text('全选本页'));
      await tester.pump();
      expect(find.text('已选 4 条'), findsOneWidget);

      await tester.tap(find.byKey(dsGroupFilterChipKey));
      await tester.pumpAndSettle();
      expect(find.byKey(dsGroupFilterPanelKey), findsOneWidget);
      expect(find.text('按字幕组筛这批结果'), findsOneWidget);
      expect(find.textContaining('池子里 4 条'), findsOneWidget);
      // 命中的组带条数、预置的标出来（「未知组」那一档排在最末，要滚才看得到，
      // 它的"单列一项 + 永远在最后"由 `subtitle_groups_test.dart` 钉住）。
      expect(find.text('1 条 · 预置'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey<String>('ds-group-toggle-桜都')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(find.text('芙莉莲 第 1 话'), findsOneWidget);
      expect(find.text('芙莉莲 第 2 话'), findsNothing);
      expect(find.text('字幕组 · 1'), findsOneWidget, reason: 'chip 上带勾了几个组');
      expect(find.textContaining('正在按字幕组筛选'), findsOneWidget);
      expect(find.textContaining('命中 1 条 / 共 4 条'), findsOneWidget);
      expect(
        find.text('已选 1 条'),
        findsOneWidget,
        reason: '被筛掉的 3 条勾选要清掉 —— 否则「下载选中」会下看不见的东西',
      );

      await tester.tap(find.text('清空筛选'));
      await tester.pumpAndSettle();
      for (int i = 1; i <= 4; i++) {
        expect(find.text('芙莉莲 第 $i 话'), findsOneWidget);
      }
      expect(find.textContaining('正在按字幕组筛选'), findsNothing);
    });

    testWidgets('筛出 0 条：说清是「这批结果里没有这个组」，并给三个出口', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final _FakeSource src = _FakeSource(<int, List<SourceItemView>>{
        1: <SourceItemView>[_item(1, 'LoliHouse'), _item(2, 'LoliHouse')],
      });
      final InMemoryKeyValueStore store = InMemoryKeyValueStore(<String, Object?>{
        SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
      });
      await tester.pumpWidget(harness(src, store));
      await searchOnce(tester);

      await tester.tap(find.byKey(dsGroupFilterChipKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('ds-group-toggle-桜都')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(find.textContaining('这批结果里没有'), findsOneWidget);
      expect(find.text('清空筛选'), findsOneWidget);
      expect(find.text('换关键字'), findsOneWidget);
      // 源说没有更多了 → 不再摆那颗点了也没用的按钮。
      expect(find.text('继续加载更多结果'), findsNothing);

      await tester.tap(find.text('清空筛选'));
      await tester.pumpAndSettle();
      expect(find.text('芙莉莲 第 1 话'), findsOneWidget);
    });
  });
}
