/// 聚合搜索的**页面**级测试（2026-10-12 第十四轮）。
///
/// 控制器行为在 `aggregate_search_test.dart` 里验；这里只验用户能看见的那两件事：
/// 1. 默认聚合模式：顶部是「聚合 / 动漫 / 全集」三颗 chip，**没有**源下拉；
/// 2. 设置里切成「单独源」：当场变回源下拉（用户原话：「设置中切换回单独源模式」）；
/// 3. 部分源失败：结果上方有警告带，点名是哪几个源（不是静默跳过）。
library;

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/ui/search_page.dart';
import 'package:dsanima/ui/widgets/neo.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假源：按 id 给一页条目；[failures] 里的 id 每次都抛错。
class _MultiSourcePort implements SourcePort {
  _MultiSourcePort({
    required this.options,
    required this.pages,
    this.failures = const <String, String>{},
  });

  final List<SourceOption> options;
  final Map<String, List<SourceItemView>> pages;
  final Map<String, String> failures;
  final List<String> asked = <String>[];

  @override
  List<SourceOption> get sources => options;

  @override
  Future<SourcePageView> latest(String sourceId, {int page = 1}) => _page(sourceId, page);

  @override
  Future<SourcePageView> search(String sourceId, String keyword, {int page = 1}) =>
      _page(sourceId, page);

  Future<SourcePageView> _page(String sourceId, int page) async {
    asked.add(sourceId);
    final String? failure = failures[sourceId];
    if (failure != null) {
      throw PortUnavailableException(failure, hint: '稍后重试');
    }
    return SourcePageView(
      items: pages[sourceId] ?? const <SourceItemView>[],
      page: page,
      hasNext: false,
      fetchedAt: DateTime(2026, 10, 12, 12),
    );
  }
}

SourceItemView _item(String id, String title) => SourceItemView(
      id: id,
      sourceId: id.split(':').first,
      title: title,
      magnet: 'magnet:?xt=urn:btih:$id',
      infoHash: id,
      episodeHints: const <String>['01'],
    );

const List<SourceOption> _options = <SourceOption>[
  SourceOption(id: 'mikan', displayName: 'Mikan（蜜柑计划）'),
  SourceOption(id: 'dmhy', displayName: '动漫花园（DMHY）'),
  SourceOption(
    id: 'dmhy-batch',
    displayName: '动漫花园 · 季度全集（DMHY）',
    partition: SourcePartition.collection,
  ),
];

/// 打开了 sukebei 的源表（第十五轮：它按分区分在「其它」组，是一个普通开关）。
const List<SourceOption> _optionsWithSukebei = <SourceOption>[
  SourceOption(id: 'mikan', displayName: 'Mikan（蜜柑计划）'),
  SourceOption(id: 'dmhy', displayName: '动漫花园（DMHY）'),
  SourceOption(
    id: 'dmhy-batch',
    displayName: '动漫花园 · 季度全集（DMHY）',
    partition: SourcePartition.collection,
  ),
  SourceOption(id: 'sukebei', displayName: 'sukebei（成人区 · 动漫分区）', partition: SourcePartition.other),
];

/// 一页给一条假结果，覆盖 [options] 里的每个源。
Map<String, List<SourceItemView>> _pagesFor(List<SourceOption> options) =>
    <String, List<SourceItemView>>{
      for (final SourceOption s in options) s.id: <SourceItemView>[_item('${s.id}:1', '${s.id} 01')],
    };

void main() {
  Widget harness(_MultiSourcePort port, {AppSettings? settings}) {
    return ProviderScope(
      overrides: [
        keyValueStoreProvider.overrideWithValue(
          InMemoryKeyValueStore(<String, Object?>{
            SettingsController.storageKey: (settings ??
                    const AppSettings(firstRunCompleted: true))
                .toJson(),
          }),
        ),
        sourcePortProvider.overrideWithValue(port),
      ],
      child: MaterialApp(
        theme: buildDsanimaTheme(),
        home: const Scaffold(body: SearchPage()),
      ),
    );
  }

  testWidgets('默认聚合：三颗 chip（聚合/动漫/全集），没有源下拉', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _MultiSourcePort port = _MultiSourcePort(
      options: _options,
      pages: <String, List<SourceItemView>>{
        'mikan': <SourceItemView>[_item('mikan:1', '芙莉莲 01')],
        'dmhy': <SourceItemView>[_item('dmhy:1', '芙莉莲 01')],
        'dmhy-batch': <SourceItemView>[_item('dmhy-batch:1', '芙莉莲 全集')],
      },
    );
    await tester.pumpWidget(harness(port));
    await tester.pumpAndSettle();

    for (final String label in <String>['聚合', '动漫', '全集']) {
      expect(find.text(label), findsOneWidget, reason: '缺聚合档 chip：$label');
    }
    expect(find.byType(SearchSourcePicker), findsNothing,
        reason: '聚合模式下不该再有单源下拉（它在「单独源模式」里才出现）');

    // 默认「聚合」档：搜索会问全部三个源。
    await tester.tap(find.widgetWithText(NeoButton, '搜索'));
    await tester.pumpAndSettle();
    expect(port.asked.toSet(), <String>{'mikan', 'dmhy', 'dmhy-batch'});
    expect(find.textContaining('芙莉莲 全集'), findsWidgets);
  });

  testWidgets('点「全集」档：只问合集源；再点「动漫」档：只问动漫源', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _MultiSourcePort port = _MultiSourcePort(
      options: _options,
      pages: <String, List<SourceItemView>>{
        'mikan': <SourceItemView>[_item('mikan:1', '芙莉莲 01')],
        'dmhy-batch': <SourceItemView>[_item('dmhy-batch:1', '芙莉莲 全集')],
      },
    );
    await tester.pumpWidget(harness(port));
    await tester.pumpAndSettle();

    await tester.tap(find.text('全集'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(NeoButton, '搜索'));
    await tester.pumpAndSettle();
    expect(port.asked.toSet(), <String>{'dmhy-batch'});
    expect(find.textContaining('芙莉莲 全集'), findsWidgets);
    expect(find.textContaining('芙莉莲 01'), findsNothing, reason: '「全集」档不该出现动漫源的结果');

    port.asked.clear();
    await tester.tap(find.text('动漫'));
    await tester.pumpAndSettle();
    expect(port.asked.toSet(), <String>{'mikan', 'dmhy'},
        reason: '切档后已经搜过 → 当场按新档重查（动漫档 = mikan + dmhy，合集源不在里面）');
  });

  testWidgets('设置里切成单独源模式 → 源下拉出现、三颗 chip 消失', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _MultiSourcePort port = _MultiSourcePort(
      options: _options,
      pages: <String, List<SourceItemView>>{
        'mikan': <SourceItemView>[_item('mikan:1', '芙莉莲 01')],
      },
    );
    await tester.pumpWidget(harness(port));
    await tester.pumpAndSettle();
    expect(find.byType(SearchSourcePicker), findsNothing);

    // 设置页那条真实链路：replace 整个 AppSettings（含 searchMode）。
    final ProviderContainer container =
        ProviderScope.containerOf(tester.element(find.byType(SearchPage)));
    await container.read(settingsProvider.notifier).replace(
          const AppSettings(firstRunCompleted: true, searchMode: SearchMode.single),
        );
    await tester.pumpAndSettle();

    expect(find.byType(SearchSourcePicker), findsOneWidget,
        reason: '单独源模式：回到源下拉');
    expect(find.text('聚合'), findsNothing, reason: '单独源模式下不再有档位 chip（「动画」那种词可能撞页面文案，所以只查「聚合」）');
  });

  testWidgets('部分源失败 → 结果上方一条警告带，点名是哪几个源', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _MultiSourcePort port = _MultiSourcePort(
      options: _options,
      pages: <String, List<SourceItemView>>{
        'mikan': <SourceItemView>[_item('mikan:1', '芙莉莲 01')],
      },
      failures: <String, String>{'dmhy': '拉取超时', 'dmhy-batch': 'HTTP 502'},
    );
    await tester.pumpWidget(harness(port));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(NeoButton, '搜索'));
    await tester.pumpAndSettle();

    // 结果照常显示（不是整页错误）。
    expect(find.textContaining('芙莉莲 01'), findsWidgets);
    expect(find.textContaining('个源没回来'), findsOneWidget);
    expect(find.textContaining('动漫花园（DMHY）（拉取超时）'), findsOneWidget);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 第十五轮：勾选（默认全开 / 可只勾几个 / 开启 sukebe 时也能勾选 / 至少留一个）
  // ───────────────────────────────────────────────────────────────────────────
  testWidgets('默认全开：右上角「源 4/4」，面板分「动漫 / 全集 / 其它」三组', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _MultiSourcePort port = _MultiSourcePort(
      options: _optionsWithSukebei,
      pages: _pagesFor(_optionsWithSukebei),
    );
    await tester.pumpWidget(harness(port));
    await tester.pumpAndSettle();

    expect(find.text('源 4/4'), findsWidgets, reason: '默认全开：4 个源全勾着');

    await tester.tap(find.byKey(dsSourcePanelChipKey));
    await tester.pumpAndSettle();
    expect(find.byKey(dsSourcePanelKey), findsOneWidget);
    expect(find.text('动漫（2）'), findsOneWidget);
    expect(find.text('全集（1）'), findsOneWidget);
    expect(find.text('其它（1）'), findsOneWidget, reason: 'sukebei 打开后就在「其它」这一组里');
    expect(find.text('sukebei（成人区 · 动漫分区）'), findsOneWidget);
    for (final String id in <String>['mikan', 'dmhy', 'dmhy-batch', 'sukebei']) {
      expect(
        tester
            .widget<NeoSwitch>(find.byKey(ValueKey<String>('ds-source-toggle-$id')))
            .value,
        isTrue,
        reason: '$id 默认应该是勾上的',
      );
    }
  });

  testWidgets('打开面板时那颗 chip 不许变成「处理中…」（打开面板不是"在跑"的动作）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _MultiSourcePort port = _MultiSourcePort(options: _options, pages: _pagesFor(_options));
    await tester.pumpWidget(harness(port));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(dsSourcePanelChipKey));
    await tester.pumpAndSettle();

    expect(find.byKey(dsSourcePanelKey), findsOneWidget);
    expect(
      find.text('处理中…'),
      findsNothing,
      reason: 'NeoActionChip 会把 onTap 的 Future 当忙态：`() async => onPressed()` 那种写法'
          '会把 showDialog 的 Future 一路 await 下去，面板开着期间 chip 一直显示「处理中…」',
    );
    expect(find.text('源 3/3'), findsWidgets);
  });

  testWidgets('面板里关掉一个源 → chip 变 2/3、档位变自定义、搜索只问勾着的两个', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _MultiSourcePort port = _MultiSourcePort(options: _options, pages: _pagesFor(_options));
    await tester.pumpWidget(harness(port));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(dsSourcePanelChipKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('ds-source-toggle-dmhy')));
    await tester.pumpAndSettle();
    expect(find.text('源 2/3'), findsWidgets);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    final ProviderContainer container =
        ProviderScope.containerOf(tester.element(find.byType(SearchPage)));
    expect(container.read(searchProvider).excludedSourceIds, <String>{'dmhy'});
    expect(container.read(searchProvider).scope, isNull, reason: '手动改过 → 三颗 chip 都不再亮');

    await tester.tap(find.widgetWithText(NeoButton, '搜索'));
    await tester.pumpAndSettle();
    expect(port.asked.toSet(), <String>{'mikan', 'dmhy-batch'},
        reason: '取消掉的 dmhy 一次都不该被问');
  });

  testWidgets('开启 sukebei 后能勾选：取消它就不再问，其它源照常', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _MultiSourcePort port = _MultiSourcePort(
      options: _optionsWithSukebei,
      pages: _pagesFor(_optionsWithSukebei),
    );
    await tester.pumpWidget(harness(port));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(dsSourcePanelChipKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('ds-source-toggle-sukebei')));
    await tester.pumpAndSettle();
    expect(find.text('源 3/4'), findsWidgets);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(NeoButton, '搜索'));
    await tester.pumpAndSettle();
    expect(port.asked.toSet(), <String>{'mikan', 'dmhy', 'dmhy-batch'});
    expect(port.asked, isNot(contains('sukebei')));
  });

  testWidgets('至少留一个源：只剩一个勾着时那个开关变灰（点不动）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const List<SourceOption> two = <SourceOption>[
      SourceOption(id: 'mikan', displayName: 'Mikan（蜜柑计划）'),
      SourceOption(id: 'dmhy', displayName: '动漫花园（DMHY）'),
    ];
    final _MultiSourcePort port = _MultiSourcePort(options: two, pages: _pagesFor(two));
    await tester.pumpWidget(harness(port));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(dsSourcePanelChipKey));
    await tester.pumpAndSettle();
    // 一开始两个都能点。
    expect(
      tester.widget<NeoSwitch>(find.byKey(const ValueKey<String>('ds-source-toggle-mikan'))).onChanged,
      isNotNull,
    );

    await tester.tap(find.byKey(const ValueKey<String>('ds-source-toggle-dmhy')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<NeoSwitch>(find.byKey(const ValueKey<String>('ds-source-toggle-mikan'))).onChanged,
      isNull,
      reason: 'mikan 是最后一个勾着的源：取消它会让搜索必然报错，所以挡下',
    );
    // 点它也不会改变勾选（开关已经是 disabled）。
    await tester.tap(find.byKey(const ValueKey<String>('ds-source-toggle-mikan')));
    await tester.pumpAndSettle();
    final ProviderContainer container =
        ProviderScope.containerOf(tester.element(find.byType(SearchPage)));
    expect(container.read(searchProvider).excludedSourceIds, <String>{'dmhy'});
  });

  testWidgets('三颗 chip 是快捷全选：点「动漫」→ chip 显示 2/4，合集与 sukebei 被排掉', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _MultiSourcePort port = _MultiSourcePort(
      options: _optionsWithSukebei,
      pages: _pagesFor(_optionsWithSukebei),
    );
    await tester.pumpWidget(harness(port));
    await tester.pumpAndSettle();

    await tester.tap(find.text('动漫'));
    await tester.pumpAndSettle();
    expect(find.text('源 2/4'), findsWidgets);

    await tester.tap(find.widgetWithText(NeoButton, '搜索'));
    await tester.pumpAndSettle();
    expect(port.asked.toSet(), <String>{'mikan', 'dmhy'});
  });

  testWidgets('搜索历史（第三十三轮）：搜过的词进历史，点历史再搜一次，单条删 / 清空', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _MultiSourcePort port = _MultiSourcePort(
      options: _options,
      pages: <String, List<SourceItemView>>{
        for (final SourceOption s in _options)
          s.id: <SourceItemView>[_item('${s.id}:1', '${s.id} 01')],
      },
    );
    await tester.pumpWidget(harness(port));
    await tester.pumpAndSettle();

    // 搜一次（回车 = 提交）。
    await tester.enterText(find.byType(TextField).first, '芙莉莲');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(port.asked, isNotEmpty);

    // 输入框清空 → 「最近搜索」出现（输入框里还有字时它让位，不当噪音）。
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('torrent-history-bar')), findsOneWidget);
    expect(find.byKey(const Key('torrent-history-chip-芙莉莲')), findsOneWidget);

    // 点历史 = 填进去并立刻再搜一次。
    final int before = port.asked.length;
    await tester.tap(find.byKey(const Key('torrent-history-chip-芙莉莲')));
    await tester.pumpAndSettle();
    expect(port.asked.length, greaterThan(before));
    expect(find.byKey(const Key('torrent-history-bar')), findsNothing,
        reason: '输入框里又有词了');

    // 单条删。
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('torrent-history-forget-芙莉莲')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('torrent-history-chip-芙莉莲')), findsNothing);
    expect(find.byKey(const Key('torrent-history-bar')), findsNothing,
        reason: '空了就不摆这一行');

    // 再搜两个词 → 一键清空（弹确认）。
    for (final String word in <String>['芙莉莲', '迷宫饭']) {
      await tester.enterText(find.byType(TextField).first, word);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pumpAndSettle();
    }
    expect(find.byKey(const Key('torrent-history-chip-迷宫饭')), findsOneWidget);
    await tester.tap(find.byKey(const Key('torrent-history-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('torrent-history-clear-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('torrent-history-bar')), findsNothing);
  });
}
