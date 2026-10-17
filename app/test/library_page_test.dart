/// 动漫库页面（第三十三轮）。
///
/// 用户：「添加新页面，名为动漫库，调用bangumi，有筛选」+ 问答里选定的：
/// 筛选（年份/季度/放送形态/排序/评分下限）、关键词搜索、点开详情、
/// 独立一份搜索历史、入口排在主页下面（入口顺序在 `shell_widget_test` 里钉）。
///
/// 这里全部用假端口（不联网），断言落在**用户看得见的东西**上：卡片、条数、页码、
/// 空态/错误态、历史胶囊，以及"点了某个筛选之后请求真的变了"。
library;

import 'dart:ui' show Tristate;

import 'package:dsanima/domain/bangumi.dart';
import 'package:dsanima/domain/bangumi_library.dart';
import 'package:dsanima/domain/following_store.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/search_history.dart';
import 'package:dsanima/state/library_provider.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/ui/library_detail_page.dart';
import 'package:dsanima/ui/library_page.dart';
import 'package:dsanima/ui/widgets/follow_button.dart';
import 'package:dsanima/ui/widgets/library_seed_block.dart';
import 'package:dsanima/ui/widgets/neo.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

BangumiSubject _sub(int id, String title, {String platform = 'TV', double? score = 8.0}) =>
    BangumiSubject(
      id: id,
      name: 'Name $id',
      nameCn: title,
      date: '2024-01-06',
      eps: 12,
      score: score,
      rank: 100,
      ratingTotal: 1000,
      coverUrl: 'https://lain.bgm.tv/r/100/pic/cover/l/x/$id.jpg',
      tags: const <String>['TV', '奇幻'],
      platform: platform,
      type: 2,
    );

/// 假端口：记下每一次查询，按脚本回答。
class FakeLibraryPort implements BangumiLibraryPort {
  FakeLibraryPort({
    List<BangumiSubject>? items,
    this.total = 100,
    this.fail = false,
    this.fillToLimit = false,
  }) : items = items ?? <BangumiSubject>[_sub(1, '葬送的芙莉莲'), _sub(2, '迷宫饭')];

  List<BangumiSubject> items;
  int total;
  bool fail;

  /// 真端口会**凑满一页**（不够就再要一页）；把这条契约也搬进假端口，
  /// 好让"一页是不是整行"能在页面这一层断言（默认关，免得老用例的条数预期全变）。
  bool fillToLimit;

  final List<({BangumiLibraryQuery query, int offset, int limit})> calls =
      <({BangumiLibraryQuery query, int offset, int limit})>[];

  @override
  bool get isAvailable => true;

  @override
  Future<BangumiLibraryPage> search(
    BangumiLibraryQuery query, {
    int offset = 0,
    int limit = kLibraryDefaultPageSize,
  }) async {
    calls.add((query: query, offset: offset, limit: limit));
    if (fail) {
      throw const PortUnavailableException('动漫库未接通（测试替身）');
    }
    final List<BangumiSubject> page = !fillToLimit
        ? items
        : <BangumiSubject>[
            ...items,
            for (int i = items.length; i < limit; i++) _sub(1000 + i, '填充 $i'),
          ];
    return BangumiLibraryPage(
      items: page,
      total: total,
      startOffset: offset,
      nextOffset: offset + page.length,
      hasMore: offset + page.length < total,
    );
  }

  @override
  Future<BangumiSubject> detail(int id) async => items.firstWhere((BangumiSubject s) => s.id == id);

  /// 角色 / 关联条目（第三十七轮）：这一组用例只看列表与跳转，给空表即可。
  @override
  Future<BangumiSubjectExtra> extras(int id) async => BangumiSubjectExtra.empty;
}

({Widget widget, FakeLibraryPort port, InMemoryKeyValueStore store}) _build({
  List<BangumiSubject>? items,
  int total = 100,
  bool fail = false,
  bool fillToLimit = false,
  List<String> libraryHistory = const <String>[],
}) {
  final FakeLibraryPort port = FakeLibraryPort(
    items: items,
    total: total,
    fail: fail,
    fillToLimit: fillToLimit,
  );
  final InMemoryKeyValueStore store = InMemoryKeyValueStore(<String, Object?>{
    if (libraryHistory.isNotEmpty) kLibrarySearchHistoryKey: libraryHistory,
  });
  final Widget widget = ProviderScope(
    overrides: [
      keyValueStoreProvider.overrideWithValue(store),
      bangumiLibraryProvider.overrideWithValue(port),
    ],
    child: MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: const Scaffold(body: LibraryPage()),
    ),
  );
  return (widget: widget, port: port, store: store);
}

Future<void> _pump(WidgetTester tester, Widget widget) async {
  tester.view.physicalSize = const Size(1400, 950);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(widget);
  await tester.pumpAndSettle();
}

/// 点一个 `NeoDropdown` 触发器（`Key`）再点菜单里的某项。
Future<void> _pick(WidgetTester tester, Key trigger, String item) async {
  await tester.ensureVisible(find.byKey(trigger));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(trigger));
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('进来就按默认条件查一次，结果画成卡片网格', (WidgetTester tester) async {
    final ({Widget widget, FakeLibraryPort port, InMemoryKeyValueStore store}) h =
        _build(total: 100);
    await _pump(tester, h.widget);

    expect(h.port.calls, hasLength(1), reason: '进页面自己查一次（列数变了不会白查一次旧的）');
    expect(h.port.calls.single.query.isDefault, isTrue, reason: '默认 = 全部动画');
    // ⚠️ 第三十四轮：一页 = 列数 × [kLibraryRows]。
    // ⚠️ 第四十四轮：列数按**左栏**宽度算（右栏占掉 8 + 248 + 18 = 274）——
    // 1400 窗 ⇒ 左栏 1126 ⇒ 可用 1090 ⇒ 6 列 ⇒ 24 条，**是 6 的整数倍**。
    // （旧版面没有右栏时这里是 7 列；量整窗宽会多算一列，末行就会缺 4 个。）
    final GridView grid = tester.widget<GridView>(find.byType(GridView));
    final SliverGridDelegateWithFixedCrossAxisCount delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 6, reason: '右栏不计入网格可用宽度');
    expect(h.port.calls.single.limit, libraryPageSize(6));
    expect(h.port.calls.single.limit % delegate.crossAxisCount, 0, reason: '一页必须是整行');
    expect(find.byKey(const Key('library-card-1')), findsOneWidget);
    expect(find.byKey(const Key('library-card-2')), findsOneWidget);
    expect(find.text('葬送的芙莉莲'), findsOneWidget);
    expect(find.textContaining('共 100 部'), findsOneWidget);
  });

  testWidgets('一页永远整行：换到 1920 窗宽（8 列）时每页条数跟着变，末行不再缺几个', (WidgetTester tester) async {
    // 用户报的正是这个形状：写死 24 条时，10 列 ⇒ 2 整行 + 4 条，最后一行空 6 个位置。
    // 第四十四轮之后 1920 窗（减掉右栏 274）= 左栏 1646 ⇒ 可用 1610 ⇒ 8 列 ⇒ 32 条。
    final ({Widget widget, FakeLibraryPort port, InMemoryKeyValueStore store}) h =
        _build(total: 100, fillToLimit: true);
    tester.view.physicalSize = const Size(1920, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(h.widget);
    await tester.pumpAndSettle();

    final GridView grid = tester.widget<GridView>(find.byType(GridView));
    final SliverGridDelegateWithFixedCrossAxisCount delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 8);
    expect(
      h.port.calls.last.limit,
      delegate.crossAxisCount * kLibraryRows,
      reason: '请求的每页条数必须 = 真实列数 × 4 行（这就是"整行"）',
    );
    expect(h.port.calls.last.limit % delegate.crossAxisCount, 0);
    expect(h.port.calls.last.limit, isNot(24), reason: '写死 24 的老行为就是"缺 6 个"的成因');

    expect(find.textContaining('每页 32 条（8 列 × 4 行）'), findsOneWidget);
  });

  testWidgets('量出来的每页条数恰好等于兜底 24 条时，这一次查询也必须照发（否则页面永远转圈）', (WidgetTester tester) async {
    // 1500 窗 ⇒ 左栏 1226 ⇒ 可用 1190 ⇒ 6 列 ⇒ 6 × 4 = 24 = 兜底值。第三十四轮踩过这个坑：
    // 页面只在"尺寸变了"时才发起第一次查询，于是尺寸正好没变时一次都不发。
    final ({Widget widget, FakeLibraryPort port, InMemoryKeyValueStore store}) h =
        _build(total: 100);
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(h.widget);
    await tester.pumpAndSettle();

    final GridView grid = tester.widget<GridView>(find.byType(GridView));
    final SliverGridDelegateWithFixedCrossAxisCount delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 6);
    expect(libraryPageSize(6), kLibraryDefaultPageSize, reason: '这一局要的正是"尺寸没变"这一档');
    expect(h.port.calls, hasLength(1), reason: '第一次查询由页面发起，尺寸没变也必须有这一次');
    expect(h.port.calls.single.limit, kLibraryDefaultPageSize);
    expect(find.byKey(const Key('library-card-1')), findsOneWidget);
    expect(find.textContaining('正在问 Bangumi'), findsNothing, reason: '不许停在加载态');
  });

  testWidgets('筛选：年份 / 季度 / 放送形态 / 排序 / 评分下限 都真的进了查询', (WidgetTester tester) async {
    final ({Widget widget, FakeLibraryPort port, InMemoryKeyValueStore store}) h = _build();
    await _pump(tester, h.widget);

    await _pick(tester, const Key('library-year'), '2024 年');
    expect(h.port.calls.last.query.year, 2024);

    // 季度档：0 全年 / 1 一月 / 2 四月 / 3 七月 / 4 十月（10 月番跨年）。
    await _pick(tester, const Key('library-quarter'), '10 月番');
    expect(h.port.calls.last.query.quarter, 4);
    expect(h.port.calls.last.query.airDate, <String>['>=2024-10-01', '<2025-01-01']);

    await _pick(tester, const Key('library-form'), '剧场版');
    expect(h.port.calls.last.query.form, BangumiLibraryForm.movie);
    expect(h.port.calls.last.query.filter['tag'], <String>['剧场版']);

    await _pick(tester, const Key('library-sort'), '评分');
    expect(h.port.calls.last.query.sort, BangumiLibrarySort.score);
    expect(h.port.calls.last.query.serverSort, 'score', reason: '没有关键词时才用这一档');

    await _pick(tester, const Key('library-score'), '≥8 分');
    expect(h.port.calls.last.query.ratingFilter, <String>['>=8']);

    // 每一次改动都重新从第一页查（不是把筛选条件攒着）。
    for (final ({BangumiLibraryQuery query, int offset, int limit}) call in h.port.calls) {
      expect(call.offset, 0);
    }
  });

  // ── 第四十四轮（用户：「优化动漫库，把搜索与筛选移到右侧，并加入类型的筛选，
  //    比如异世界 玄幻 校园这些」）────────────────────────────────────────────────

  testWidgets('右栏：搜索框与全部筛选都在**结果区右边**，结果区从页面顶部开始', (WidgetTester tester) async {
    final ({Widget widget, FakeLibraryPort port, InMemoryKeyValueStore store}) h = _build();
    await _pump(tester, h.widget);

    final Finder rail = find.byKey(const Key('library-rail'));
    expect(rail, findsOneWidget);
    final Rect railRect = tester.getRect(rail);
    final Rect gridRect = tester.getRect(find.byType(GridView));
    expect(railRect.left, greaterThanOrEqualTo(gridRect.right), reason: '筛选整栏在网格右边');
    expect(railRect.right, closeTo(1400 - 18, 0.5), reason: '右缘与网格的右内边距对齐（不留死白）');

    // 搜索框、类型胶囊、五格下拉**都在右栏里**（不是还留在顶上）。
    Finder inRail(Finder f) => find.descendant(of: rail, matching: f);
    expect(inRail(find.byKey(const Key('library-search-field'))), findsOneWidget);
    expect(inRail(find.widgetWithText(NeoButton, '搜索')), findsOneWidget);
    expect(inRail(find.byKey(const Key('library-genre-all'))), findsOneWidget);
    expect(inRail(find.byKey(const Key('library-genre-异世界'))), findsOneWidget);
    for (final String key in <String>[
      'library-year',
      'library-quarter',
      'library-form',
      'library-sort',
      'library-score',
    ]) {
      expect(inRail(find.byKey(Key(key))), findsOneWidget, reason: '$key 该在右栏');
    }

    // 旧版面把这一整条压在结果**上面**（网格顶部因此被推到 100+）。
    expect(gridRect.top, lessThan(60), reason: '结果区从页面顶部开始，不再被筛选条压着');
    expect(tester.takeException(), isNull);
  });

  testWidgets('类型：点一颗胶囊就按它筛、再点一下取消，「全部」也能取消；其它条件不许被清掉',
      (WidgetTester tester) async {
    final ({Widget widget, FakeLibraryPort port, InMemoryKeyValueStore store}) h = _build();
    await _pump(tester, h.widget);

    // 先在别的格子上放一个条件：类型胶囊**不许**把它清掉（旧实现是整份换查询）。
    await _pick(tester, const Key('library-form'), '剧场版');
    expect(h.port.calls.last.query.form, BangumiLibraryForm.movie);

    await tester.tap(find.byKey(const Key('library-genre-异世界')));
    await tester.pumpAndSettle();
    expect(h.port.calls.last.query.tag, '异世界');
    expect(h.port.calls.last.query.filter['tag'], <String>['剧场版', '异世界'],
        reason: '形态与类型一起进 filter.tag（服务端取交集）');
    expect(h.port.calls.last.query.form, BangumiLibraryForm.movie, reason: '形态那一格不许被清掉');
    expect(h.port.calls.last.offset, 0, reason: '换类型要从第一页重查');
    expect(find.textContaining('类型「异世界」'), findsOneWidget, reason: '结果抬头要说清按什么筛的');

    // 再点一下同一颗 = 取消这一档。
    await tester.tap(find.byKey(const Key('library-genre-异世界')));
    await tester.pumpAndSettle();
    expect(h.port.calls.last.query.tag, isNull);
    expect(h.port.calls.last.query.filter['tag'], <String>['剧场版'], reason: '取消类型不等于取消形态');

    // 「全部」= 不按类型筛。
    await tester.tap(find.byKey(const Key('library-genre-校园')));
    await tester.pumpAndSettle();
    expect(h.port.calls.last.query.tag, '校园');
    await tester.tap(find.byKey(const Key('library-genre-all')));
    await tester.pumpAndSettle();
    expect(h.port.calls.last.query.tag, isNull);
  });

  testWidgets('类型：清单外的标签（从条目详情页点进来的）也显示成选中胶囊，并且能取消',
      (WidgetTester tester) async {
    // 详情页的标签是**条目自带**的，不限于 kLibraryGenreTags（可能是「公路片」「2022年10月」）。
    // 那种标签必须在右栏看得见 —— 否则"结果被筛过、栏里找不到原因"。
    final FakeLibraryPort port = FakeLibraryPort();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
        bangumiLibraryProvider.overrideWithValue(port),
      ],
    );
    addTearDown(container.dispose);
    container.read(libraryQueryProvider.notifier).setTag('公路片');

    tester.view.physicalSize = const Size(1400, 950);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: const Scaffold(body: LibraryPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder chip = find.byKey(const Key('library-genre-公路片'));
    expect(chip, findsOneWidget, reason: '清单外的标签也要出现');
    expect(tester.widget<NeoPill>(chip).selected, isTrue, reason: '它正是当前生效的那一档');
    expect(port.calls.last.query.tag, '公路片');

    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(port.calls.last.query.tag, isNull, reason: '再点一下就取消');
    expect(find.byKey(const Key('library-genre-公路片')), findsNothing, reason: '取消之后不必再占一颗');
  });

  testWidgets('类型胶囊：Tab + 回车也能筛（第四十二轮 UX #40 的同一条口径）', (WidgetTester tester) async {
    // 这一栏一次摆 30 多颗可点的胶囊，如果还是裸 `GestureDetector`，键盘用户整块用不了
    // （Tab 跳过、没有焦点框、回车/空格没反应）—— 上一轮在外观选择器上刚修过同一条。
    // ⚠️ 必须在**测试体内** dispose：`addTearDown` 跑在框架的收尾检查之后。
    final SemanticsHandle handle = tester.ensureSemantics();
    final ({Widget widget, FakeLibraryPort port, InMemoryKeyValueStore store}) h = _build();
    await _pump(tester, h.widget);

    final Finder chip = find.byKey(const Key('library-genre-异世界'));
    // 语义要落在**可点的那一层**上（`NeoPill` 把 `Semantics(button:)` 套在 `InkWell` 外面，
    // 而 Key 挂在 NeoPill 自己身上，取它自己的节点拿到的是外面那层）。
    final Finder chipButton =
        find.descendant(of: chip, matching: find.byType(InkWell)).first;
    expect(tester.getSemantics(chipButton).flagsCollection.isButton, isTrue,
        reason: '读屏要念成"按钮"，不是一段纯文字');
    expect(tester.getSemantics(chipButton).flagsCollection.isSelected, Tristate.isFalse,
        reason: '当前没选它');

    bool chipHasFocus() {
      final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
      if (focused == null) return false;
      return find
          .ancestor(
            of: find.byElementPredicate((Element e) => e == focused),
            matching: chip,
          )
          .evaluate()
          .isNotEmpty;
    }

    // 前面的可聚焦控件（搜索框、全部、奇幻、科幻…）先走过，直到焦点落到这一颗上。
    for (int i = 0; i < 12 && !chipHasFocus(); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(chipHasFocus(), isTrue, reason: 'Tab 必须能落到类型胶囊上（旧写法整块被跳过）');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(h.port.calls.last.query.tag, '异世界', reason: '回车要能真的筛（旧写法完全没反应）');
    handle.dispose();
  });

  testWidgets('关键词搜索：回车就查、进"动漫库"自己那份历史、点历史再查一次', (WidgetTester tester) async {
    final ({Widget widget, FakeLibraryPort port, InMemoryKeyValueStore store}) h = _build();
    await _pump(tester, h.widget);

    await tester.enterText(find.byType(TextField).first, '葬送的芙莉莲');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(h.port.calls.last.query.trimmedKeyword, '葬送的芙莉莲');
    expect(h.port.calls.last.query.serverSort, 'match', reason: '有关键词按相关度');
    expect(h.store.get(kLibrarySearchHistoryKey), <String>['葬送的芙莉莲'],
        reason: '动漫库的搜索历史写进自己那份键');
    expect(h.store.get(kTorrentSearchHistoryKey), isNull, reason: '种子搜索那份不许被写');

    // 清空输入框 → 历史条出现 → 点它再查一次。
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('library-history-bar')), findsOneWidget);
    await tester.tap(find.byKey(const Key('library-history-chip-葬送的芙莉莲')));
    await tester.pumpAndSettle();
    expect(h.port.calls.last.query.trimmedKeyword, '葬送的芙莉莲');
    expect(find.byKey(const Key('library-history-bar')), findsNothing,
        reason: '输入框里又有词了，历史条让位');

    // 单条删除 + 清空（清空要确认）。
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library-history-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library-history-clear-confirm')));
    await tester.pumpAndSettle();
    expect(h.store.get(kLibrarySearchHistoryKey), isNull);
  });

  testWidgets('翻页：游标用端口给的 nextOffset，上一页回到已走过的起点', (WidgetTester tester) async {
    final ({Widget widget, FakeLibraryPort port, InMemoryKeyValueStore store}) h =
        _build(total: 100);
    await _pump(tester, h.widget);
    expect(find.text('第 1 页'), findsOneWidget);

    await tester.tap(find.widgetWithText(NeoButton, '下一页').first);
    await tester.pumpAndSettle();
    expect(h.port.calls.last.offset, 2, reason: '游标 = 上一页的 nextOffset（不是 offset + 每页条数）');
    expect(find.text('第 2 页'), findsOneWidget);

    await tester.tap(find.widgetWithText(NeoButton, '上一页').first);
    await tester.pumpAndSettle();
    expect(h.port.calls.last.offset, 0);
    expect(find.text('第 1 页'), findsOneWidget);
  });

  testWidgets('空结果：说清楚"这一档没有"，并给一条重置的路', (WidgetTester tester) async {
    final ({Widget widget, FakeLibraryPort port, InMemoryKeyValueStore store}) h =
        _build(items: const <BangumiSubject>[], total: 0);
    await _pump(tester, h.widget);

    expect(find.text('这一档没有条目'), findsOneWidget);
    expect(find.textContaining('重置筛选'), findsWidgets);
    // 选了条件之后空态要把条件念出来（用户才知道是哪一条筛没了）。
    await _pick(tester, const Key('library-form'), 'WEB');
    await tester.pumpAndSettle();
    // ⚠️ 第四十四轮：右栏的每格下拉只显示**值**（小标题在它上面一行），
    // 所以这里不再是「形态：WEB」这一串，而是"触发器写着 WEB"+"空态把条件念出来"。
    expect(find.text('WEB'), findsOneWidget, reason: '下拉触发器上就是当前值');
    expect(find.textContaining('条件：WEB'), findsOneWidget, reason: '空态要点名是哪一条筛没了');
  });

  testWidgets('失败：显示"为什么 + 怎么办"，重试按钮再查一次（不假装没有数据）', (WidgetTester tester) async {
    final ({Widget widget, FakeLibraryPort port, InMemoryKeyValueStore store}) h =
        _build(fail: true);
    await _pump(tester, h.widget);

    expect(find.textContaining('动漫库未接通'), findsOneWidget);
    h.port.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('library-card-1')), findsOneWidget);
  });

  testWidgets('点卡片 → 打开条目详情（今日推荐也走同一个落点）', (WidgetTester tester) async {
    final ({Widget widget, FakeLibraryPort port, InMemoryKeyValueStore store}) h = _build();
    await _pump(tester, h.widget);

    await tester.tap(find.byKey(const Key('library-card-1')));
    await tester.pumpAndSettle();

    expect(find.byType(LibraryDetailPage), findsOneWidget);
    expect(find.text('葬送的芙莉莲'), findsWidgets);
    // 第四十五轮：那颗「按这个名字搜种子」按钮换成了页内的种子块（块抬头里才有
    // 「在搜索页打开」）。块要滚到才建（`ListView(children:)` 是懒建的）。
    await tester.scrollUntilVisible(find.byKey(dsDetailSeedsKey), 200);
    expect(find.byKey(dsDetailSeedsKey), findsOneWidget);
    // 详情页的标签点一下就回库里按它筛。
    // ⚠️ 先 `ensureVisible`：1400×950 下标签卡在左栏靠下、**掉到折线以下**了
    //（第三十六轮左栏的"事实"改成一行一条之后又高了几十像素），
    // 直接 tap 会打在那个坐标上的别的东西上（`calls.last` 于是还是进来那一次的空 tag）。
    await tester.ensureVisible(find.byKey(const Key('library-tag-奇幻')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library-tag-奇幻')));
    await tester.pumpAndSettle();
    expect(h.port.calls.last.query.tag, '奇幻');
    // ⚠️ 第三十七轮补上这一条：点标签**也要把详情页关掉**（用户报的是旁边那颗按钮
    //    「按这个名字搜种子」点了详情页不消失 —— 两条路用的是同一套"先 pop 再切"，
    //    所以这里一起钉住，免得以后只修一条）。
    expect(find.byType(LibraryDetailPage), findsNothing, reason: '点标签之后详情页也要自己走');
  });

  // ⚠️ 第三十七轮（用户：「点击按这个名字搜种子，详细页不会消失还要手动关一下」）。
  //    详情页是 rootNavigator push 的**整屏路由**，而 `openRecommendSearch` 只做
  //    「填关键字 + 切 shell tab」—— 路由还压在上面，用户看到的就是"点了没走"。
  testWidgets('详情页的「按这个名字搜种子」：详情页自己关掉 + 关键字进搜索页 + tab 切过去',
      (WidgetTester tester) async {
    final FakeLibraryPort port =
        FakeLibraryPort(items: <BangumiSubject>[_sub(1, '葬送的芙莉莲')], total: 1);
    final ProviderContainer container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
        bangumiLibraryProvider.overrideWithValue(port),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1400, 950);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: const Scaffold(body: LibraryPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library-card-1')));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryDetailPage), findsOneWidget);

    // ⚠️ 这个 harness 直接把 `LibraryPage` 挂在 `home:`（没有 shell），所以 `navProvider`
    //    的初始值就是它的默认值 `home` —— 这里只钉"点完之后到了 search"，不假设起点。
    expect(container.read(navProvider), isNot(ShellTab.search));
    await tester.scrollUntilVisible(find.byKey(dsDetailSeedsSearchPageKey), 200);
    await tester.tap(find.byKey(dsDetailSeedsSearchPageKey));
    await tester.pumpAndSettle();

    expect(find.byType(LibraryDetailPage), findsNothing,
        reason: '用户不该自己按返回 —— 详情页是压在 shell 上的整屏路由，必须自己 pop');
    expect(container.read(navProvider), ShellTab.search, reason: '落到搜索页');
    expect(container.read(searchProvider).keyword, '葬送的芙莉莲', reason: '关键字就是这条目的名字');
  });

  // ── 第五十轮 ────────────────────────────────────────────────────────────────
  // 用户原话：「名字过长就会出现显示不全的问题，然后动漫库右上角应该加个订阅按钮
  // 同主页的那样」；问答选定「动漫库每张海报卡的右上角：悬停出现 ♥（追番），
  // 和主页海报卡一样」。

  testWidgets('第五十轮：长番名两行**整行**看得见（不再被切掉第二行），卡片上悬停看全名',
      (WidgetTester tester) async {
    const String longTitle = '剧场版 关于我转生变成史莱姆这档事 红莲之绊篇';
    final ({Widget widget, FakeLibraryPort port, InMemoryKeyValueStore store}) h =
        _build(items: <BangumiSubject>[_sub(1, longTitle)], total: 1);
    await _pump(tester, h.widget);

    final Finder title = find.text(longTitle);
    expect(title, findsOneWidget);
    final Text text = tester.widget<Text>(title);
    expect(text.maxLines, kLibraryCardTitleLines, reason: '番名仍然是两行上限（超过的收省略号）');

    // 两行实际要多高：拿**同一个 style** 量一行，×2 —— 真字体是 19/行（不是 18.9）。
    final TextPainter painter = TextPainter(
      text: TextSpan(text: '两行', style: text.style),
      textDirection: TextDirection.ltr,
    )..layout();
    final double twoLines = painter.height * kLibraryCardTitleLines;
    expect(
      tester.getSize(title).height,
      greaterThanOrEqualTo(twoLines - 0.01),
      reason: '番名区必须装得下两行（$twoLines）；旧值 30 装不下 → 第二行被切掉半截，'
          '看着就是"名字过长显示不全"',
    );

    // 超过两行的名字收省略号，但**悬停**能看到完整番名（卡片上挂的 Tooltip 就是全名）。
    final Tooltip tip = tester.widget<Tooltip>(
      find.ancestor(of: find.text(longTitle), matching: find.byType(Tooltip)),
    );
    expect(tip.message, longTitle);
  });

  testWidgets('第五十轮：卡片右上角悬停出现追番 ♥（同主页海报卡）；点了只追番、不打开详情',
      (WidgetTester tester) async {
    final ({Widget widget, FakeLibraryPort port, InMemoryKeyValueStore store}) h =
        _build();
    await _pump(tester, h.widget);
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(LibraryPage)),
    );
    expect(find.byType(FollowButton), findsNothing, reason: '不悬停时不挤封面角');

    final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byKey(const Key('library-card-1'))));
    await tester.pumpAndSettle();

    expect(find.byType(FollowButton), findsOneWidget, reason: '悬停 → 卡片右上角出现追番 ♥');
    final Rect heart = tester.getRect(find.byType(FollowButton));
    final Rect card = tester.getRect(find.byKey(const Key('library-card-1')));
    expect(heart.top, lessThan(card.center.dy), reason: '在封面的上半部，不是标题那一侧');
    expect(heart.right, lessThanOrEqualTo(card.right + 1), reason: '贴着卡片右缘（右上角）');

    // 点 ♥ = 追番（本地标记，不建订阅、不下载），**不**顺带把详情页点开。
    await tester.tap(find.byType(FollowButton));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryDetailPage), findsNothing, reason: '点 ♥ 不该连带打开详情页');
    expect(
      container.read(followingProvider).map((FollowingEntry e) => e.id),
      contains('bgm:1'),
      reason: '写进了「正在追」的那条 bgm 记录',
    );
    expect(find.byIcon(Icons.favorite), findsOneWidget, reason: '已追 → 实心 ♥');

    // 已追的卡片：鼠标移开也把那颗 ♥ 留在角上（与主页海报卡同一条规矩）。
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(find.byType(FollowButton), findsOneWidget, reason: '已追的卡不悬停也留着 ♥');
  });
}
