/// 动漫库页面（第三十三轮）。
///
/// 用户：「添加新页面，名为动漫库，调用bangumi，有筛选」+ 问答里选定的：
/// 筛选（年份/季度/放送形态/排序/评分下限）、关键词搜索、点开详情、
/// 独立一份搜索历史、入口排在主页下面（入口顺序在 `shell_widget_test` 里钉）。
///
/// 这里全部用假端口（不联网），断言落在**用户看得见的东西**上：卡片、条数、页码、
/// 空态/错误态、历史胶囊，以及"点了某个筛选之后请求真的变了"。
library;

import 'package:dsanima/domain/bangumi.dart';
import 'package:dsanima/domain/bangumi_library.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/search_history.dart';
import 'package:dsanima/state/library_provider.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/ui/library_detail_page.dart';
import 'package:dsanima/ui/library_page.dart';
import 'package:dsanima/ui/widgets/neo.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter/material.dart';
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
    // ⚠️ 第三十四轮：一页 = 列数 × [kLibraryRows]。1400 窗宽 ⇒ 可用 1364 ⇒ 7 列 ⇒ 28 条，
    // **是 7 的整数倍**（以前写死 24：24 = 3 整行 + 3 条，最后一行缺 4）。
    expect(h.port.calls.single.limit, libraryPageSize(7));
    expect(h.port.calls.single.limit % 7, 0, reason: '一页必须是整行');
    expect(find.byKey(const Key('library-card-1')), findsOneWidget);
    expect(find.byKey(const Key('library-card-2')), findsOneWidget);
    expect(find.text('葬送的芙莉莲'), findsOneWidget);
    expect(find.textContaining('共 100 部'), findsOneWidget);
  });

  testWidgets('一页永远整行：换到 1920 窗宽（10 列）时每页条数跟着变，末行不再缺几个', (WidgetTester tester) async {
    // 用户报的正是这个形状：写死 24 条时，10 列 ⇒ 2 整行 + 4 条，最后一行空 6 个位置。
    final ({Widget widget, FakeLibraryPort port, InMemoryKeyValueStore store}) h =
        _build(total: 100, fillToLimit: true);
    tester.view.physicalSize = const Size(1920, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(h.widget);
    await tester.pumpAndSettle();

    // 可用宽 1920 − 18×2 = 1884 ⇒ 列 = floor((1884+16)/(168+16)) = 10。
    final GridView grid = tester.widget<GridView>(find.byType(GridView));
    final SliverGridDelegateWithFixedCrossAxisCount delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 10);
    expect(
      h.port.calls.last.limit,
      delegate.crossAxisCount * kLibraryRows,
      reason: '请求的每页条数必须 = 真实列数 × 4 行（这就是"整行"）',
    );
    expect(h.port.calls.last.limit % delegate.crossAxisCount, 0);
    expect(h.port.calls.last.limit, isNot(24), reason: '写死 24 的老行为就是"缺 6 个"的成因');

    expect(find.textContaining('每页 40 条（10 列 × 4 行）'), findsOneWidget);
  });

  testWidgets('量出来的每页条数恰好等于兜底 24 条时，这一次查询也必须照发（否则页面永远转圈）', (WidgetTester tester) async {
    // 1200 窗宽 ⇒ 可用 1164 ⇒ 6 列 ⇒ 6 × 4 = 24 = 兜底值。第三十四轮踩过这个坑：
    // 页面只在"尺寸变了"时才发起第一次查询，于是尺寸正好没变时一次都不发。
    final ({Widget widget, FakeLibraryPort port, InMemoryKeyValueStore store}) h =
        _build(total: 100);
    tester.view.physicalSize = const Size(1200, 900);
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
    expect(find.textContaining('形态：WEB'), findsOneWidget);
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
    expect(find.text('按这个名字搜种子'), findsOneWidget);
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
    await tester.tap(find.byKey(const Key('library-detail-search-seeds')));
    await tester.pumpAndSettle();

    expect(find.byType(LibraryDetailPage), findsNothing,
        reason: '用户不该自己按返回 —— 详情页是压在 shell 上的整屏路由，必须自己 pop');
    expect(container.read(navProvider), ShellTab.search, reason: '落到搜索页');
    expect(container.read(searchProvider).keyword, '葬送的芙莉莲', reason: '关键字就是这条目的名字');
  });
}
