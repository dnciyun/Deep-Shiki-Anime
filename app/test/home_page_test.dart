/// 主页 widget 测试（spec §7.5）。
///
/// **不联网、不真下封面、不起引擎**：`SchedulePort` / `CoverCachePort` / `EnginePort`
/// 全部用假实现注入；「今天」用 `todayDowProvider` 固定成周三，不依赖跑测试的机器日期。
/// 封面用仓库里真实的 jpg 素材（`test/fixtures/cover_frieren_thumb.jpg`）
/// 走一次真解码，其余卡片一律走「无封面」降级路径。
library;

import 'dart:io';

import 'package:dsanima/domain/bangumi.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/state/carousel_provider.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/theme/tokens.dart';
import 'package:dsanima/ui/home_page.dart';
import 'package:dsanima/ui/library_detail_page.dart';
import 'package:dsanima/ui/search_page.dart';
import 'package:dsanima/ui/widgets/cover.dart';
import 'package:dsanima/ui/widgets/ds_carousel.dart';
import 'package:dsanima/ui/widgets/follow_button.dart';
import 'package:dsanima/ui/widgets/library_seed_block.dart';
import 'package:dsanima/ui/widgets/neo.dart';
import 'package:dsanima/ui/widgets/neo_dropdown.dart';
import 'package:dsanima/ui/widgets/search_sections.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实封面素材（只读，用来验证「有封面 → 真渲染图片」这条路径）。
final File realCover = File('test/fixtures/cover_frieren_thumb.jpg');

// ─────────────────────────────────────────────────────────────────────────────
// 测试替身
// ─────────────────────────────────────────────────────────────────────────────

class FakeSchedulePort implements SchedulePort {
  FakeSchedulePort(this.view, {this.failure});

  final ScheduleView? view;
  final Object? failure;
  int calls = 0;

  @override
  bool get isAvailable => view != null;

  @override
  Future<ScheduleView> schedule() async {
    calls++;
    final Object? error = failure;
    if (error != null) throw error;
    return view!;
  }

  @override
  Future<BangumiDetailView> bangumi(String bangumiId) async =>
      BangumiDetailView(bangumiId: bangumiId, title: '测试番剧');
}

class FakeCoverCache implements CoverCachePort {
  FakeCoverCache({this.file});

  final File? file;
  final List<String> requested = <String>[];

  @override
  Future<File?> fileFor(String url, {String? referer}) async {
    requested.add(url);
    return file;
  }

  /// 第三十七轮：这里**不**走同步那条路，保持这些用例原来的时序（先空一帧、再出图）。
  /// "缓存命中 ⇒ 首帧直出"由 `cover_size_test.dart` 里的假实现单独钉。
  @override
  File? cachedNow(String url) => null;
}

class FakeEnginePort implements EnginePort {
  FakeEnginePort({this.torrents = const <EngineTorrentView>[]});

  final List<EngineTorrentView> torrents;

  @override
  Future<EngineHealthView> health() async => const EngineHealthView(ok: true, version: '0.1.0');

  @override
  Future<EngineTorrentView> addMagnet(
    String magnet, {
    String? name,
    List<int>? onlyFiles,
    bool startPaused = false,
    String? subFolder,
  }) async => throw const PortUnavailableException('测试替身：不加种');

  @override
  Future<List<EngineTorrentView>> list() async => torrents;

  @override
  Future<void> pause(int id) async {}

  @override
  Future<void> resume(int id) async {}

  @override
  Future<void> remove(int id, {bool deleteFiles = false}) async {}

  @override
  Stream<List<EngineTorrentView>> watch() => Stream<List<EngineTorrentView>>.value(torrents);

  @override
  Uri? streamUrl(int id, int fileIndex) => null;
}

class FakeSourcePort implements SourcePort {
  FakeSourcePort(this.items);

  final List<SourceItemView> items;

  @override
  List<SourceOption> get sources => const <SourceOption>[
    SourceOption(id: 'nyaa', displayName: 'nyaa.si 动漫区'),
  ];

  @override
  Future<SourcePageView> latest(String sourceId, {int page = 1}) async =>
      SourcePageView(items: items, page: page, fetchedAt: DateTime(2026, 10, 9, 12));

  @override
  Future<SourcePageView> search(String sourceId, String keyword, {int page = 1}) async =>
      latest(sourceId, page: page);
}

/// 假推荐端口：记录每次用的种子（验证「换一批」真的换了种子）。
class FakeRecommendPort implements RecommendPort {
  FakeRecommendPort(this.items);

  final List<BangumiSubject> items;
  final List<int> seeds = <int>[];

  @override
  bool get isAvailable => true;

  @override
  Future<List<BangumiSubject>> recommend({required int seed, int? count}) async {
    seeds.add(seed);
    return items;
  }
}

BangumiSubject _subject(int id, String title, {double? score, String date = '2014-07-06'}) =>
    BangumiSubject(
      id: id,
      name: 'Name $id',
      nameCn: title,
      date: date,
      score: score,
      eps: 12,
      coverUrl: 'https://lain.bgm.tv/r/100/pic/cover/l/x/$id.jpg',
    );

// ─────────────────────────────────────────────────────────────────────────────
// 数据构造
// ─────────────────────────────────────────────────────────────────────────────

ScheduleEntryView _entry(
  int dow,
  int index,
  String title, {
  String? cover,
  bool subscribed = false,
  String update = '2026/10/07 更新',
  DateTime? updatedAt,
}) => ScheduleEntryView(
  bangumiId: '${4000 + index}',
  dayOfWeek: dow,
  title: title,
  coverUrl: cover,
  updateText: update,
  updatedAt: updatedAt ?? DateTime(2026, 10, 7),
  index: index,
  subscribed: subscribed,
);

/// 测试用的「今天」：2026-10-07 是星期三（与设计基线的周三 8 部一致）。
final DateTime testToday = DateTime(2026, 10, 7);

/// 日期切换（「今日更新」旁边那一排里的某一项）：直接点它的名字。
///
/// ⚠️ 2026-10-14 第二十八轮（用户：「主页日期改成，在今日更新旁边一排周一到周日+
/// 剧场版+ova，细体淡色」）：这里**不再有下拉**（下拉是 2026-10-10 第 1 轮问答的产物），
/// 每一项就是一个可点的文字，所以不用再"点开、再点菜单项"。
Future<void> _selectDay(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

/// 这一排里某个名字的样式（「细体淡色」是这一轮的硬指标，所以直接断言样式）。
TextStyle _dayTabStyle(WidgetTester tester, String label) =>
    tester.widget<Text>(find.text(label)).style!;

/// 这一排里某个名字的 tooltip 文案。部数（`周三（今天） · 8 部`）挂在 tooltip 里 ——
/// 第二十八轮把这一排做成"只有名字"的细体淡色，计数没有丢，只是不再占版面。
String? _dayTabTooltip(WidgetTester tester, String label) => tester
    .widget<Tooltip>(find.ancestor(of: find.text(label), matching: find.byType(Tooltip)))
    .message;

/// 这一排的全部日期名（顺序就是界面上的顺序）。
const List<String> _dayTabLabels = <String>[
  '周一',
  '周二',
  '周三',
  '周四',
  '周五',
  '周六',
  '周日',
  '剧场版',
  'OVA',
];

/// 8 部周三 + 1 部周四 + 剧场版 2 部 + OVA 1 部（贴近设计基线的密度：周三 8 部 → 244px 一档）。
///
/// 只有第一部是「今天更新」（mikan 的 date-text 就是今天），其余是上周三更新的。
///
/// ⚠️ 第二十五轮：mikan 的两个专档（dow 7/8）以前在这份夹具里叫「未定档甲/乙」，
/// 现在按站点自己的名字叫 **剧场版 / OVA**。
ScheduleView fixtureSchedule() {
  final Map<int, List<ScheduleEntryView>> byDay = <int, List<ScheduleEntryView>>{
    3: <ScheduleEntryView>[
      _entry(3, 1, '转生就是剑 第二季'),
      _entry(3, 2, '归还者的魔法要特别 第二季', updatedAt: DateTime(2026, 9, 30), update: '2026/09/30 更新'),
      _entry(3, 3, '默王武神开斋祭', updatedAt: DateTime(2026, 9, 30), update: '2026/09/30 更新'),
      for (int i = 4; i <= 8; i++)
        _entry(3, i, '周三第 $i 部', updatedAt: DateTime(2026, 9, 30), update: '2026/09/30 更新'),
    ],
    4: <ScheduleEntryView>[
      _entry(4, 1, '周四唯一一部', updatedAt: DateTime(2026, 9, 30), update: '2026/09/30 更新'),
    ],
    7: <ScheduleEntryView>[_entry(7, 1, '剧场版甲'), _entry(7, 2, '剧场版乙')],
    8: <ScheduleEntryView>[_entry(8, 1, 'OVA 一部')],
  };
  return ScheduleView(
    entries: byDay.values.expand((List<ScheduleEntryView> e) => e).toList(),
    byDay: byDay,
    fetchedAt: DateTime.now().subtract(const Duration(minutes: 3)),
  );
}

Widget harness(
  Widget child, {
  SchedulePort? schedule,
  CoverCachePort? covers,
  EnginePort? engine,
  SourcePort? source,
  RecommendPort? recommend,
  DateTime? today,
  // 决策 F23/F24 的三个设置：不传就按默认（中档封面 / 横版轮播 / 中档轮播），
  // 传了就覆盖对应 provider（Task 8 与截图探针都用它）。
  DsCoverSize? coverSize,
  DsCarouselShape? carouselShape,
  DsCarouselSize? carouselSize,
  bool? carouselAutoPlay,
  // 截图探针用：换一套外观（token + 设置里的 themeId 一起给）。
  DsTokens? themeTokens,
  AppSettings? settings,
}) => ProviderScope(
  overrides: [
    if (coverSize != null) homeCoverSizeProvider.overrideWithValue(coverSize),
    if (carouselShape != null)
      carouselShapeProvider.overrideWithValue(carouselShape),
    if (carouselSize != null)
      carouselSizeProvider.overrideWithValue(carouselSize),
    if (carouselAutoPlay != null)
      carouselAutoPlayProvider.overrideWithValue(carouselAutoPlay),
    keyValueStoreProvider.overrideWithValue(
      InMemoryKeyValueStore(<String, Object?>{
        SettingsController.storageKey:
            (settings ?? const AppSettings(firstRunCompleted: true)).toJson(),
      }),
    ),
    schedulePortProvider.overrideWithValue(schedule ?? FakeSchedulePort(fixtureSchedule())),
    coverCacheProvider.overrideWithValue(covers ?? FakeCoverCache()),
    enginePortProvider.overrideWithValue(engine ?? FakeEnginePort()),
    sourcePortProvider.overrideWithValue(source ?? FakeSourcePort(const <SourceItemView>[])),
    recommendPortProvider.overrideWithValue(
      recommend ?? FakeRecommendPort(const <BangumiSubject>[]),
    ),
    subsPortProvider.overrideWithValue(const UnavailableSubsPort()),
    queuePortProvider.overrideWithValue(const UnavailableQueuePort()),
    playerPortProvider.overrideWithValue(const UnavailablePlayerPort()),
    pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
    todayProvider.overrideWithValue(today ?? testToday),
  ],
  child: MaterialApp(
    theme: buildDsanimaTheme(tokens: themeTokens ?? DsTokens.whiteInk),
    home: Scaffold(body: child),
  ),
);

void sizeTo(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('主页默认选中今天（周三），只渲染当天的条目', (WidgetTester tester) async {
    sizeTo(tester, const Size(1600, 1000));

    await tester.pumpWidget(harness(const HomePage()));
    await tester.pumpAndSettle();

    // 「今日更新」只出现 1 次 = 页面标题。角标在第二十九轮从**文字胶囊**改成了
    // **6px 色点**（决策 F17），所以"今天更新的那部"不再贡献一处文字。
    expect(find.text('今日更新'), findsOneWidget);
    expect(find.byKey(const Key('badge-today')), findsOneWidget,
        reason: '首卡是今天更新的 → 左上角一颗 success 色点（文字在 tooltip 里）');
    // 用户 2026-10-10 第 1 轮问答：「数据 3 分钟前」「下次刷新 MM:SS 后」两处时间全删，
    // 只留一颗刷新按钮（自动刷新照旧）。
    expect(find.textContaining('数据 '), findsNothing);
    expect(find.textContaining('下次刷新'), findsNothing);
    // ⚠️ 2026-10-14 第二十八轮：刷新改成**圆形按钮 + 只有矢量图**——
    // 「刷新」两个字从界面上消失了，只剩 Icons.refresh。
    expect(find.text('刷新'), findsNothing, reason: '圆形按钮上不再有文字（用户第二十八轮）');
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    // 用户 2026-10-12 第十一轮：顶栏整行删掉（「今晚想看点什么」+ 同一行的刷新），
    // 刷新挪到日期那一排旁边（见下面那条层级用例）。
    expect(find.text('今晚想看点什么'), findsNothing);

    // ⚠️ 第二十八轮：日期切换从**下拉**改回**一排**：周一到周日 + 剧场版 + OVA，共 9 项。
    expect(find.byType(NeoDropdown<int>), findsNothing, reason: '下拉已改回一排（用户第二十八轮）');
    for (final String label in _dayTabLabels) {
      expect(find.text(label), findsOneWidget, reason: '这一排必须有「$label」');
    }
    // 细体淡色：没选中的 = caption 字号 + w300 + 三级色；选中的（今天，周三）才走强调色。
    for (final String label in <String>['周一', '周二', '周四', '周五', '周六', '周日', '剧场版', 'OVA']) {
      expect(_dayTabStyle(tester, label).fontSize, DsTypeScale.caption);
      expect(_dayTabStyle(tester, label).fontWeight, FontWeight.w300, reason: '「$label」要细体');
      expect(_dayTabStyle(tester, label).color, DsTokens.whiteInk.text3, reason: '「$label」要淡色');
    }
    expect(_dayTabStyle(tester, '周三').color, DsTokens.whiteInk.accent, reason: '选中项走强调色');
    expect(_dayTabStyle(tester, '周三').fontWeight, FontWeight.w500);
    // 部数没有丢：改挂在 tooltip 上；「今天」写在 tooltip 里（那一排本身只有名字）。
    expect(_dayTabTooltip(tester, '周三'), '周三（今天） · 8 部');
    expect(_dayTabTooltip(tester, '周四'), '周四 · 1 部');
    expect(_dayTabTooltip(tester, '剧场版'), '剧场版 · 2 部');

    // 当天 8 部在，其它档的不在
    expect(find.text('转生就是剑 第二季'), findsOneWidget);
    expect(find.text('周三第 8 部'), findsOneWidget);
    expect(find.text('周四唯一一部'), findsNothing);
    expect(find.text('剧场版甲'), findsNothing);
    expect(find.text('OVA 一部'), findsNothing);

    // 海报卡：封面上的日期角标还在；卡上的「mikan · 更新日期」整行已删
    //（用户 2026-10-10 第 3 轮问答）。
    expect(find.text('mikan'), findsNothing);
    expect(find.text('2026/10/07 更新'), findsOneWidget);
    expect(find.text('2026/09/30 更新'), findsNWidgets(7));
  });

  testWidgets('切到周四：只换网格，**不重新拉数据**', (WidgetTester tester) async {
    sizeTo(tester, const Size(1600, 1000));

    final FakeSchedulePort port = FakeSchedulePort(fixtureSchedule());
    await tester.pumpWidget(harness(const HomePage(), schedule: port));
    await tester.pumpAndSettle();
    expect(port.calls, 1);

    await _selectDay(tester, '周四');
    await tester.pumpAndSettle();

    expect(port.calls, 1, reason: '一次 schedule() 拿全周，切星期不该再打站点');
    expect(find.text('周四唯一一部'), findsOneWidget);
    expect(find.text('转生就是剑 第二季'), findsNothing);
    // 顶部标题跟着切（今天不是周四 → 不写「今日更新」）
    expect(find.text('今日更新'), findsNothing);
    expect(find.text('周四更新'), findsOneWidget);
    // 这一排的高亮跟着走：周四 = 强调色，周三退回淡色。
    expect(_dayTabStyle(tester, '周四').color, DsTokens.whiteInk.accent);
    expect(_dayTabStyle(tester, '周三').color, DsTokens.whiteInk.text3);
  });

  testWidgets('当天没有更新 → 空态文案（spec 原文，不留白屏）', (WidgetTester tester) async {
    sizeTo(tester, const Size(1400, 900));

    final Map<int, List<ScheduleEntryView>> byDay = <int, List<ScheduleEntryView>>{
      4: <ScheduleEntryView>[_entry(4, 1, '周四唯一一部')],
    };
    final ScheduleView view = ScheduleView(
      entries: byDay.values.expand((List<ScheduleEntryView> e) => e).toList(),
      byDay: byDay,
      fetchedAt: DateTime.now(),
    );
    await tester.pumpWidget(harness(const HomePage(), schedule: FakeSchedulePort(view)));
    await tester.pumpAndSettle();

    expect(find.text('今天没有更新的番剧。可以点上方的星期切换看看其它日子。'), findsOneWidget);
  });

  testWidgets('追番表为空（0 条）→ 说清楚是站点没给数据，不装成「今天没更新」', (WidgetTester tester) async {
    sizeTo(tester, const Size(1400, 900));

    final ScheduleView empty = ScheduleView(
      entries: const <ScheduleEntryView>[],
      byDay: const <int, List<ScheduleEntryView>>{},
      fetchedAt: DateTime.now(),
      skipped: 3,
    );
    await tester.pumpWidget(harness(const HomePage(), schedule: FakeSchedulePort(empty)));
    await tester.pumpAndSettle();

    expect(find.textContaining('返回了 0 条番剧'), findsOneWidget);
    expect(find.text('今天没有更新的番剧。可以点上方的星期切换看看其它日子。'), findsNothing);
  });

  testWidgets('追番表端口未接通 → 可行动错误（不是空表）', (WidgetTester tester) async {
    sizeTo(tester, const Size(1400, 900));

    // isAvailable=false 的端口 = 未接通（等价 UnavailableSchedulePort）
    final FakeSchedulePort offline = FakeSchedulePort(
      null,
      failure: const PortUnavailableException('追番表未接通：mikan 首页解析尚未装配', hint: '源层没注入'),
    );
    await tester.pumpWidget(harness(const HomePage(), schedule: offline));
    await tester.pumpAndSettle();

    expect(find.textContaining('追番表未接通'), findsWidgets);
    expect(find.textContaining('怎么办：'), findsWidgets);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('今天没有更新的番剧。可以点上方的星期切换看看其它日子。'), findsNothing);
  });

  testWidgets('⚠️ 追番表还没到时：这一排不许写「· 0 部」（0 部 = 编了一个数字）', (WidgetTester tester) async {
    // 审查发现：`count: view?.day(dow).length ?? 0` 把"数据还没到/拿不到"说成了"这天 0 部"，
    // 与 spec 里"不编数据"的口径冲突（首页其它地方宁可留空/明说没拿到）。
    // ⚠️ 第二十八轮之后部数改挂在 tooltip 上，所以这条断言查的是 tooltip 的内容。
    sizeTo(tester, const Size(1400, 900));
    final FakeSchedulePort offline = FakeSchedulePort(
      null,
      failure: const PortUnavailableException('追番表未接通：mikan 首页解析尚未装配', hint: '源层没注入'),
    );
    await tester.pumpWidget(harness(const HomePage(), schedule: offline));
    await tester.pumpAndSettle();

    expect(find.textContaining('· 0 部'), findsNothing, reason: '没有数据 ≠ 0 部');
    expect(
      find.text('周三'),
      findsWidgets,
      reason: '这一排照旧可用（名字都在，只是不报部数）',
    );
    expect(_dayTabTooltip(tester, '周三'), '周三（今天）', reason: '拿不到数据就只写星期，不许编 0 部');
    expect(_dayTabTooltip(tester, '周四'), '周四');
  });

  testWidgets('封面：站点没给 → 灰框「无封面」；有封面 → 真解码渲染图片', (WidgetTester tester) async {
    sizeTo(tester, const Size(1400, 900));
    expect(
      realCover.existsSync(),
      isTrue,
      reason: '缺封面素材 ${realCover.path}（仓库里的 test/fixtures/）',
    );

    final Map<int, List<ScheduleEntryView>> byDay = <int, List<ScheduleEntryView>>{
      3: <ScheduleEntryView>[
        _entry(3, 1, '没有封面的一部'), // coverUri = null
      ],
    };
    final ScheduleView view = ScheduleView(
      entries: byDay.values.expand((List<ScheduleEntryView> e) => e).toList(),
      byDay: byDay,
      fetchedAt: DateTime.now(),
    );

    // ① 无封面：降级成灰框，且**不去请求任何 URL**
    final FakeCoverCache covers = FakeCoverCache(file: realCover);
    await tester.pumpWidget(
      harness(const HomePage(), schedule: FakeSchedulePort(view), covers: covers),
    );
    await tester.pumpAndSettle();
    expect(find.text('无封面'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(covers.requested, isEmpty, reason: '没有封面 URL 就不该发起任何封面请求');

    // ② 有封面：缓存命中真实 jpg → 渲染成图片，不再显示「无封面」
    final Map<int, List<ScheduleEntryView>> withCover = <int, List<ScheduleEntryView>>{
      3: <ScheduleEntryView>[
        _entry(
          3,
          1,
          '有封面的一部',
          cover: 'https://mikanani.me/images/Bangumi/202603/x.jpg?format=webp',
        ),
      ],
    };
    final ScheduleView view2 = ScheduleView(
      entries: withCover.values.expand((List<ScheduleEntryView> e) => e).toList(),
      byDay: withCover,
      fetchedAt: DateTime.now(),
    );
    await tester.pumpWidget(
      harness(const HomePage(), schedule: FakeSchedulePort(view2), covers: covers),
    );
    await tester.pumpAndSettle();

    expect(covers.requested, hasLength(1));
    expect(covers.requested.single, contains('/images/Bangumi/'));
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('无封面'), findsNothing);
  });

  testWidgets('角标优先级：已订阅 > 已缓存 > 今日更新（都不是就不显示）', (WidgetTester tester) async {
    sizeTo(tester, const Size(1400, 900));

    final Map<int, List<ScheduleEntryView>> byDay = <int, List<ScheduleEntryView>>{
      3: <ScheduleEntryView>[
        _entry(3, 1, '普通番', updatedAt: DateTime(2026, 9, 30)),
        _entry(3, 2, '今天更新了', updatedAt: testToday),
        _entry(3, 3, '我订阅了', subscribed: true, updatedAt: testToday),
        _entry(3, 4, '引擎里已下完 [1080p]', updatedAt: testToday),
      ],
    };
    final ScheduleView view = ScheduleView(
      entries: byDay.values.expand((List<ScheduleEntryView> e) => e).toList(),
      byDay: byDay,
      fetchedAt: DateTime.now(),
    );
    // 引擎里已有一个名字包含「引擎里已下完」的 torrent
    final FakeEnginePort engine = FakeEnginePort(
      torrents: <EngineTorrentView>[
        const EngineTorrentView(
          id: 7,
          name: '[ANi] 引擎里已下完 1080p',
          state: TorrentState.live,
          progress: 1,
          finished: true,
        ),
      ],
    );

    await tester.pumpWidget(
      harness(const HomePage(), schedule: FakeSchedulePort(view), engine: engine),
    );
    await tester.pumpAndSettle();

    // 标题 1 次；角标是色点（F17），优先级 已订阅 > 已缓存 > 今日更新，文字只在 tooltip 里。
    expect(find.text('今日更新'), findsOneWidget);
    expect(find.byKey(const Key('badge-subscribed')), findsOneWidget);
    expect(find.byKey(const Key('badge-cached')), findsOneWidget);
    expect(find.byKey(const Key('badge-today')), findsOneWidget);
    // tooltip 仍然说人话（色点没有文字，语义只能靠它）。
    final Tooltip subscribedTip = tester.widget<Tooltip>(
      find.ancestor(
        of: find.byKey(const Key('badge-subscribed')),
        matching: find.byType(Tooltip),
      ),
    );
    expect(subscribedTip.message, '已订阅');
  });

  testWidgets('角标判据是纯函数：低置信度/无信号一律不显示', (WidgetTester tester) async {
    final ScheduleEntryView plain = _entry(3, 1, '普通番', updatedAt: DateTime(2026, 9, 30));
    expect(
      scheduleBadgeFor(entry: plain, updatedToday: false, cached: false, subscribed: false),
      isNull,
    );
    expect(
      scheduleBadgeFor(entry: plain, updatedToday: true, cached: false, subscribed: false),
      ScheduleBadge.today,
    );
    expect(
      scheduleBadgeFor(entry: plain, updatedToday: true, cached: true, subscribed: false),
      ScheduleBadge.cached,
    );
    expect(
      scheduleBadgeFor(entry: plain, updatedToday: true, cached: true, subscribed: true),
      ScheduleBadge.subscribed,
    );
  });

  testWidgets('搜索页是纯列表：没有封面组件，也没有任何图片', (WidgetTester tester) async {
    sizeTo(tester, const Size(1500, 1200));

    await tester.pumpWidget(
      harness(
        const SearchPage(),
        source: FakeSourcePort(<SourceItemView>[
          SourceItemView(
            id: 'nyaa:1',
            sourceId: 'nyaa',
            title: '葬送的芙莉莲 - 第 01 话 [1080p]',
            magnet: 'magnet:?xt=urn:btih:abc',
            seeders: 42,
            sizeBytes: 734003200,
            publishedAt: DateTime(2026, 10, 8, 12),
          ),
        ]),
      ),
    );
    // 搜索页默认不加载（用户 2026-10-12）：点一下「搜索」把结果弄出来，
    // 这条用例才有东西可查"是不是纯列表"。
    await tester.tap(find.widgetWithText(NeoButton, '搜索'));
    await tester.pumpAndSettle();

    expect(find.byType(SearchResultsTable), findsOneWidget);
    expect(find.textContaining('葬送的芙莉莲 - 第 01 话'), findsWidgets);
    // spec §7.5：搜索页**不要封面**（那条「34×48 缩略图」的要求已作废）
    expect(find.byType(DsCover), findsNothing);
    expect(find.byType(Image), findsNothing);
  });

  test('封面尺寸固定一档、且有上限（用户 2026-10-10 固定档 + 2026-10-11「图太大」）', () {
    expect(coverSizeForDay(8), kHomeCoverMaxWidth);
    expect(coverSizeForDay(7), kHomeCoverMaxWidth);
    expect(coverSizeForDay(5), kHomeCoverMaxWidth);
    expect(coverSizeForDay(4), kHomeCoverMaxWidth);
    expect(coverSizeForDay(0), kHomeCoverMaxWidth);
    expect(
      kHomeCoverMaxWidth,
      lessThanOrEqualTo(220),
      reason: '今日更新的封面不许再被均分逻辑撑大（用户 2026-10-11：图太大）',
    );
  });

  // ── 第三十一轮：用户 2026-10-15「今日更新的封面图还是显示不全」 ────────────────
  //
  // 两层原因各钉一条：① 站点给的 `data-src` 带 `height`，图床按正方形裁剪
  // （真机实测原图 1429×2000 → 400×400）；② 真封面里有一小部分不是 0.705 的竖版
  // （当天 24 张实测：中位 0.7067，最大 0.926），固定框里用 `cover` 仍会裁。
  testWidgets('今日更新的封面：请求里不带 height，且海报槽用 contain（不裁图）',
      (WidgetTester tester) async {
    sizeTo(tester, const Size(1600, 1000));

    const String square =
        'https://mikanani.me/images/Bangumi/202610/abc.jpg?width=400&height=400&format=webp';
    final FakeCoverCache covers = FakeCoverCache(file: realCover);
    final Map<int, List<ScheduleEntryView>> byDay = <int, List<ScheduleEntryView>>{
      3: <ScheduleEntryView>[
        _entry(3, 1, '转生就是剑 第二季', cover: square),
      ],
    };
    await tester.pumpWidget(
      harness(
        const HomePage(),
        covers: covers,
        schedule: FakeSchedulePort(ScheduleView(
          entries: byDay.values.expand((List<ScheduleEntryView> e) => e).toList(),
          byDay: byDay,
          fetchedAt: DateTime.now(),
        )),
      ),
    );
    await tester.pumpAndSettle();

    expect(covers.requested, isNotEmpty, reason: '有封面就该去取');
    for (final String url in covers.requested) {
      expect(url, isNot(contains('height=')),
          reason: '带 height 就是被图床裁成正方形的那张（封面显示不全的真身）');
    }
    expect(covers.requested.first, contains('width=400&format=webp'));

    final Iterable<DsCover> grid = tester
        .widgetList<DsCover>(find.byType(DsCover))
        .where((DsCover c) => (c.url ?? '').contains('/images/Bangumi/'));
    expect(grid, isNotEmpty, reason: '当天网格里应该有这张海报卡');
    for (final DsCover cover in grid) {
      expect(cover.fit, kPosterFit,
          reason: '固定按 0.705 开的海报槽必须 contain，否则偏宽的封面还是被裁一截');
    }
  });

  // ── spec §7.7（第三个用户修正）：推荐在「今日更新」之上，星期切换是更新区头行内 ──

  testWidgets('主页层级：顶栏那一行已删；一排日期与刷新按钮同在更新区头行内', (WidgetTester tester) async {
    sizeTo(tester, const Size(1600, 1000));

    final FakeRecommendPort recommend = FakeRecommendPort(<BangumiSubject>[
      for (int i = 1; i <= 5; i++) _subject(i, '推荐番 $i', score: 7.0 + i / 10),
    ]);
    await tester.pumpWidget(harness(const HomePage(), recommend: recommend));
    await tester.pumpAndSettle();

    // 用户 2026-10-12 第十一轮：删掉顶栏（「今晚想看点什么」+ 同一行的刷新）。
    expect(find.text('今晚想看点什么'), findsNothing, reason: '顶栏整行删掉');

    final double yRecommend = tester.getCenter(find.text('今日推荐')).dy;
    // 「今日更新」在页面上出现两次（区头 + 首卡的角标），区头在树里排前面。
    final Offset updateTitle = tester.getCenter(find.text('今日更新').first);
    // ⚠️ 第二十八轮：日期是「今日更新」旁边**一排**（周一到周日 + 剧场版 + OVA）。
    final Offset firstTab = tester.getCenter(find.text('周一'));
    final Offset lastTab = tester.getCenter(find.text('OVA'));
    final Offset refresh = tester.getCenter(find.byIcon(Icons.refresh));

    expect(yRecommend, lessThan(updateTitle.dy), reason: '今日推荐必须在今日更新**之上**');
    expect(yRecommend, lessThan(firstTab.dy), reason: '页面最上面现在是推荐（顶栏位置空出来了）');
    // 行内：这一排与「今日更新」区头同一行，且就在标题右边（不是行尾的下拉，也不是页面顶部筛选条）
    expect((firstTab.dy - updateTitle.dy).abs(), lessThan(16), reason: '这一排要与「今日更新」同一行');
    expect(firstTab.dx, greaterThan(updateTitle.dx), reason: '这一排在「今日更新」右边');
    expect(
      firstTab.dx - updateTitle.dx,
      lessThan(160),
      reason: '「旁边」= 贴着标题，不是被 Spacer 推到行尾',
    );
    // 刷新：同一行、在这一排的最右端（用户第十一轮：刷新就在这一排旁边）。
    expect((refresh.dy - firstTab.dy).abs(), lessThan(16), reason: '刷新要与这一排同一行');
    expect(refresh.dx, greaterThan(lastTab.dx), reason: '刷新在这一排右端');
    // 一排顺序：周一到周日 + 剧场版 + OVA，从左到右
    double previous = -1;
    for (final String label in _dayTabLabels) {
      final double dx = tester.getCenter(find.text(label)).dx;
      expect(dx, greaterThan(previous), reason: '这一排的顺序必须按 $_dayTabLabels 来');
      previous = dx;
    }

    // 日期只作用于更新区：切到周四后推荐 rail 一个字都不变，也不重新拉推荐
    final int callsBefore = recommend.seeds.length;
    await _selectDay(tester, '周四');
    await tester.pumpAndSettle();
    // 轮播只给**当前项**画文字块（邻卡是同一张封面的半露），所以这里断言主卡的标题 +
    // 圆点数量（= 推荐条数），而不是"5 个标题都在树上"。
    expect(find.text('推荐番 1'), findsOneWidget);
    expect(find.byKey(const Key('carousel-dot-4')), findsOneWidget);
    expect(find.byKey(const Key('carousel-dot-5')), findsNothing);
    expect(recommend.seeds.length, callsBefore, reason: '切星期不该重新拉推荐（推荐与星期几无关）');
    expect(find.text('周四唯一一部'), findsOneWidget);
  });

  testWidgets('窄窗口（760px）下更新区头不溢出：一排日期仍是行内', (WidgetTester tester) async {
    sizeTo(tester, const Size(760, 800));
    await tester.pumpWidget(harness(const HomePage()));
    await tester.pumpAndSettle();

    // 溢出会让 widget 测试直接红（RenderFlex overflow 会被 flutter_test 当错误报出来）。
    expect(find.text('今晚想看点什么'), findsNothing);
    final Offset tabs = tester.getCenter(find.text('周一'));
    final Offset refresh = tester.getCenter(find.byIcon(Icons.refresh));
    expect((refresh.dy - tabs.dy).abs(), lessThan(16), reason: '窄窗口下也要同一行');
    expect(refresh.dx, greaterThan(tabs.dx), reason: '刷新在这一排右侧');
    expect(find.text('今日更新'), findsWidgets);
  });

  testWidgets('极窄窗口（520px）下这一排折行也不溢出：不抛 RenderFlex overflow', (WidgetTester tester) async {
    // 这一排在窄窗口下用 `Wrap` 折行（横向滚动条在桌面端不跟滚轮走，折行更稳）：
    // 折成两行也**不许**抛 overflow —— 抛了 flutter_test 会直接把这条用例判红。
    sizeTo(tester, const Size(520, 800));
    await tester.pumpWidget(harness(const HomePage()));
    await tester.pumpAndSettle();

    for (final String label in _dayTabLabels) {
      expect(find.text(label), findsOneWidget, reason: '折行之后「$label」也得在');
    }
    expect(find.byIcon(Icons.refresh), findsOneWidget, reason: '刷新按钮照旧在');
  });

  testWidgets('今日推荐：轮播（圆点数 = 条数）· 文字块跟着当前项 · 没有「换一批」（F13/F14）',
      (WidgetTester tester) async {
    sizeTo(tester, const Size(1600, 1000));

    final FakeRecommendPort recommend = FakeRecommendPort(<BangumiSubject>[
      _subject(1, '葬送的芙莉莲', score: 8.5, date: '2023-09-29'),
      _subject(2, '还没有评分的番', score: null, date: '2004-05-19'),
    ]);
    await tester.pumpWidget(harness(const HomePage(), recommend: recommend));
    await tester.pumpAndSettle();

    // 区头只有标题：没有副标题、没有「换一批」按钮（决策 F13/F16）。
    expect(find.textContaining('Bangumi 全年代随机'), findsNothing);
    expect(find.text('换一批 ↻'), findsNothing);
    expect(find.byIcon(Icons.shuffle), findsNothing, reason: '「换一批」整块删除（F13）');
    // 圆点不是按钮：推荐区头没有任何常驻按钮（刷新按钮在下面的更新区头）。
    expect(
      find.descendant(
        of: find.byType(NeoCircleButton),
        matching: find.byIcon(Icons.shuffle),
      ),
      findsNothing,
      reason: '推荐区头不再有「换一批」',
    );

    // 圆点数量 = 推荐条数；文字块只画当前项。
    expect(find.byKey(const Key('carousel-dot-0')), findsOneWidget);
    expect(find.byKey(const Key('carousel-dot-1')), findsOneWidget);
    expect(find.byKey(const Key('carousel-dot-2')), findsNothing);
    expect(find.text('葬送的芙莉莲'), findsOneWidget);
    expect(find.text('★8.5'), findsOneWidget);
    expect(find.text('暂无评分'), findsNothing, reason: '当前项有评分，第二项的文字块没画出来');
    expect(recommend.seeds, hasLength(1), reason: '当天只拉一次，没有任何手动重拉入口');

    // 点第 2 颗圆点 → 文字块换成第二项（null 评分必须显示「暂无评分」）。
    await tester.tap(find.byKey(const Key('carousel-dot-1')));
    await tester.pumpAndSettle();
    expect(find.text('还没有评分的番'), findsOneWidget);
    expect(find.text('暂无评分'), findsOneWidget, reason: 'null 不能渲染成 0 或空白');
    expect(recommend.seeds, hasLength(1), reason: '切页不重新拉数据');
  });

  testWidgets('第二十八轮：刷新是圆形按钮（只有矢量图）；点它仍然立即重拉追番表', (WidgetTester tester) async {
    sizeTo(tester, const Size(1600, 1000));

    final FakeSchedulePort port = FakeSchedulePort(fixtureSchedule());
    await tester.pumpWidget(harness(const HomePage(), schedule: port));
    await tester.pumpAndSettle();
    expect(port.calls, 1);

    // 第二十九轮后主页**只剩一颗**圆形按钮：更新区头的刷新（推荐区头的「换一批」已删）。
    expect(find.byType(NeoCircleButton), findsOneWidget);
    // **仅保留矢量图、去除文字**：这颗按钮里一个 Text 都不许有。
    expect(
      find.descendant(
        of: find.byType(NeoCircleButton),
        matching: find.byType(Text),
      ),
      findsNothing,
      reason: '圆形按钮里不许有文字（用户第二十八轮）',
    );

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(port.calls, 2, reason: '点圆形刷新按钮 = 立即重拉（自动刷新逻辑不变）');
  });

  testWidgets('推荐未接通 → 给出可行动说明，不影响追番表（不是白屏/假番）', (WidgetTester tester) async {
    sizeTo(tester, const Size(1400, 1000));

    await tester.pumpWidget(harness(const HomePage(), recommend: const UnavailableRecommendPort()));
    await tester.pumpAndSettle();

    expect(find.textContaining('今日推荐未接通'), findsOneWidget);
    // 追番表照常渲染（「今日更新」= 区头；角标已经是色点，不再贡献文字）。
    expect(find.text('转生就是剑 第二季'), findsOneWidget);
    expect(find.text('今日更新'), findsOneWidget);
    expect(find.byKey(const Key('badge-today')), findsOneWidget);
  });

  testWidgets('主页海报卡悬停出现「追番」按钮（spec §7.6）', (WidgetTester tester) async {
    sizeTo(tester, const Size(1600, 1000));

    await tester.pumpWidget(harness(const HomePage()));
    await tester.pumpAndSettle();
    expect(find.byType(FollowButton), findsNothing, reason: '不悬停时不挤封面角');

    final TestGesture gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(DsCover).first));
    await tester.pumpAndSettle();

    expect(find.byType(FollowButton), findsWidgets);
    // 点一下 = 追番（本地标记，不建订阅、不下载）
    await tester.tap(find.byType(FollowButton).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('已加入「正在追」'), findsOneWidget);
  });

  // ── 第五十轮（用户：「名字过长就会出现显示不全的问题」）────────────────────────
  testWidgets('第五十轮：两行番名整行看得见（不再切掉第二行），悬停标题看全名', (WidgetTester tester) async {
    sizeTo(tester, const Size(1600, 1000));
    const String longTitle = '剧场版 关于我转生变成史莱姆这档事 红莲之绊篇';
    final Map<int, List<ScheduleEntryView>> byDay = <int, List<ScheduleEntryView>>{
      3: <ScheduleEntryView>[_entry(3, 1, longTitle)],
    };
    await tester.pumpWidget(
      harness(
        const HomePage(),
        schedule: FakeSchedulePort(
          ScheduleView(
            entries: byDay.values.expand((List<ScheduleEntryView> e) => e).toList(),
            byDay: byDay,
            fetchedAt: DateTime.now(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder title = find.text(longTitle);
    expect(title, findsOneWidget);
    final Text text = tester.widget<Text>(title);
    expect(text.maxLines, 2, reason: '番名仍然是两行上限（超过的收省略号）');

    // 两行实际要多高：拿**同一个 style** 量一行再 ×2 —— 真字体是 19/行（不是 18.9×2=37.8）。
    final TextPainter painter = TextPainter(
      text: TextSpan(text: '两行', style: text.style),
      textDirection: TextDirection.ltr,
    )..layout();
    expect(
      tester.getSize(title).height,
      greaterThanOrEqualTo(painter.height * 2 - 0.01),
      reason: '番名区必须装得下两行（${painter.height * 2}）；旧值 32 装不下 → '
          '第二行被切掉半截，看着就是"名字过长显示不全"',
    );

    // 超过两行的名字收省略号，但**悬停**能看到完整番名。
    final Tooltip tip = tester.widget<Tooltip>(
      find.ancestor(of: find.text(longTitle), matching: find.byType(Tooltip)),
    );
    expect(tip.message, longTitle);
    // 悬停一下确认 tooltip 真的会弹（不是挂在那儿没人触发）。
    final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(title));
    await tester.pumpAndSettle();
    expect(find.text(longTitle), findsNWidgets(2), reason: '卡片上一份 + tooltip 浮层一份');
  });

  testWidgets('点推荐卡 → 打开动漫库详情；详情里「搜种子」才去搜索页（第三十三轮）',
      (WidgetTester tester) async {
    sizeTo(tester, const Size(1400, 1000));

    final FakeRecommendPort recommend = FakeRecommendPort(<BangumiSubject>[
      _subject(1, '葬送的芙莉莲', score: 8.5),
    ]);
    await tester.pumpWidget(harness(const HomePage(), recommend: recommend));
    await tester.pumpAndSettle();

    // push 详情页之后主页会变成 offstage（Finder 默认跳过 offstage），所以容器先拿。
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(HomePage)),
    );

    // ⚠️ 第三十三轮（用户：「点今日推荐也会跳到这里面」）：落点从"直接搜种子"改成
    // **动漫库详情页** —— 先看到评分/简介/标签，再决定要不要找种子。
    await tester.tap(find.text('葬送的芙莉莲'));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryDetailPage), findsOneWidget);
    expect(container.read(navProvider), ShellTab.home, reason: '不再直接跳到搜索页');
    expect(container.read(searchProvider).keyword, isEmpty, reason: '也不许偷偷把番名丢进搜索');

    // 详情页里的**种子块**才是原来那条链路（番名 → 搜索页 → 搜种子）。
    // ⚠️ 第四十五轮：原来那颗「按这个名字搜种子」按钮换成了页内的种子块，
    //    「去搜索页」降级成块抬头里的一颗小链接；块在折线以下时 ListView 还没建它，
    //    所以先滚到它。
    await tester.scrollUntilVisible(find.byKey(dsDetailSeedsSearchPageKey), 200);
    await tester.tap(find.byKey(dsDetailSeedsSearchPageKey));
    await tester.pumpAndSettle();
    expect(container.read(searchProvider).keyword, '葬送的芙莉莲');
    expect(container.read(navProvider), ShellTab.search);
  });

  testWidgets('「今日推荐」与「今日更新」之间的间距 = 30（第三十二轮 +5）', (WidgetTester tester) async {
    sizeTo(tester, const Size(1400, 1000));

    await tester.pumpWidget(
      harness(
        const HomePage(),
        recommend: FakeRecommendPort(<BangumiSubject>[_subject(1, '推荐番 1')]),
        carouselAutoPlay: false,
      ),
    );
    await tester.pumpAndSettle();

    // 真正的间距 = 推荐区底部留白 + 更新区头自带的上边距（两处相加）。
    final Padding railPad = tester.widget<Padding>(
      find.ancestor(of: find.byType(DsCarousel), matching: find.byType(Padding)).first,
    );
    expect((railPad.padding as EdgeInsets).bottom, 18, reason: '第三十二轮：13 → 18');
    final double gap = tester.getRect(find.text('今日更新')).top -
        tester.getRect(find.byType(DsCarousel)).bottom;
    expect(
      gap,
      greaterThanOrEqualTo(30),
      reason: '18（推荐区底部）+ 12（区头顶部）= 30 起；区头那一行更高时文字还会再居中一点',
    );
  });

  testWidgets('网格不按条目数硬算列数：列数由宽度决定；网格宽度刚好放下 N 张卡（右边留白）', (WidgetTester tester) async {
    sizeTo(tester, const Size(1600, 1000));

    await tester.pumpWidget(harness(const HomePage()));
    await tester.pumpAndSettle();

    // 第二十五轮：网格搬进了页面的 `CustomScrollView` → 现在是 `SliverGrid`
    //（不再是自带滚动的 `GridView`）。
    final SliverGrid grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    final SliverGridDelegateWithFixedCrossAxisCount delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    // 外壳侧栏 184 + 工具条；这里直接用主页自身宽度断言「列数由宽度决定」
    expect(delegate.crossAxisCount, greaterThanOrEqualTo(3));
    expect(delegate.mainAxisSpacing, kHomeGridGap);
    expect(delegate.crossAxisSpacing, kHomeGridGap);
    // 卡片高度 = **竖版封面高** + 文字块（决策 F22：高 = 宽 ÷ 0.705，不再是正方）。
    expect(delegate.mainAxisExtent, isNotNull);
    final double coverH = delegate.mainAxisExtent! - kHomeCardTextHeight;
    final double cardW = coverH * kPosterAspect;
    expect(coverH, closeTo(coverSizeForDay(8) / kPosterAspect, 0.5));
    // 均分宽度封顶：不管窗口多宽，封面不会超过这一档（用户 2026-10-11「图太大」）。
    expect(cardW, lessThanOrEqualTo(kHomeCoverMaxWidth + 0.5));

    // ⚠️ 网格**自身**的可用宽度必须「刚好放下 N 张封顶宽度的卡」：delegate 会把单元格均分
    // 铺满它拿到的宽度，铺满就会把封面撑到超过封顶值，而卡高是按封顶值算的 → 标题两行被裁掉。
    // 改造前靠 `Align + SizedBox(gridWidth)` 收窄，现在靠 `SliverPadding` 的右内边距。
    final SliverPadding pad = tester.widget<SliverPadding>(find.byType(SliverPadding).first);
    final EdgeInsets padding = pad.padding.resolve(TextDirection.ltr);
    final double pageWidth = tester.getSize(find.byType(HomePage)).width;
    expect(padding.left, kHomeGridPadding);
    expect(padding.right, greaterThanOrEqualTo(kHomeGridPadding));
    expect(
      pageWidth - padding.left - padding.right,
      closeTo(
        cardW * delegate.crossAxisCount + kHomeGridGap * (delegate.crossAxisCount - 1),
        0.5,
      ),
      reason: '网格宽度要按封顶宽度算（多出来的空间留白，而不是把卡片撑宽）',
    );
    // 页面与纯函数用同一套算法（改一边不会只改一边）。
    expect(delegate.crossAxisCount, homeGridColumns(pageWidth, kHomeCoverMaxWidth));
    expect(cardW, closeTo(homeCardWidthFor(pageWidth), 0.5));
    // 封顶来自设置（决策 F23）：默认中档 = 208，所以不传 cap 的旧调用形式等价。
    expect(homeCardWidthFor(pageWidth), homeCardWidthFor(pageWidth, kHomeCoverMaxWidth));
  });

  // ── 第二十五轮：今日推荐 + 今日更新「做成一体的」 ─────────────────────────────

  testWidgets('今日推荐 + 今日更新合成一条整页滚动条：往下拖时推荐跟着滚（不再钉在上面）', (WidgetTester tester) async {
    // 窗口要小到"内容比视口长"，否则根本没有可滚的余量（这条用例前半段就是在证明这一点）。
    sizeTo(tester, const Size(1200, 640));

    final FakeRecommendPort recommend = FakeRecommendPort(<BangumiSubject>[
      for (int i = 1; i <= 5; i++) _subject(i, '推荐番 $i', score: 7.0 + i / 10),
    ]);
    await tester.pumpWidget(harness(const HomePage(), recommend: recommend));
    await tester.pumpAndSettle();

    // 一条滚动条：整页一个 CustomScrollView，网格**不再**自带滚动。
    expect(find.byType(CustomScrollView), findsOneWidget);
    expect(find.byType(GridView), findsNothing, reason: '网格不再是自带滚动的 GridView');

    final double recommendBefore = tester.getTopLeft(find.text('今日推荐')).dy;
    final double updateBefore = tester.getTopLeft(find.text('今日更新').first).dy;

    // 在网格上往上拖 220px（窗口里的内容一起动）。
    await tester.dragFrom(const Offset(700, 480), const Offset(0, -220));
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('今日推荐')).dy,
      lessThan(recommendBefore),
      reason: '推荐区跟着一起滚（问答选定：整页一条滚动条）',
    );
    expect(
      tester.getTopLeft(find.text('今日更新').first).dy,
      lessThan(updateBefore),
      reason: '更新区头也跟着滚（推荐与更新是一体的）',
    );
    // 滚完推荐区已经在上方（滚出屏幕后不再占位置）。
    expect(tester.getTopLeft(find.text('今日推荐')).dy, lessThan(0));
  });

  testWidgets('两个专档（剧场版 / OVA）按站点原文名常驻在这一排里', (WidgetTester tester) async {
    sizeTo(tester, const Size(1600, 1000));

    await tester.pumpWidget(harness(const HomePage()));
    await tester.pumpAndSettle();

    // ⚠️ 第二十八轮：它们不再"有内容才出现在下拉里"，而是跟星期一样**常驻这一排**
    //（用户点名的就是「周一到周日+剧场版+OVA」）。部数照样挂在 tooltip 上。
    expect(find.text('剧场版'), findsOneWidget);
    expect(find.text('OVA'), findsOneWidget);
    expect(find.textContaining('未定档'), findsNothing, reason: '第二十五轮：不再叫未定档');
    expect(_dayTabTooltip(tester, '剧场版'), '剧场版 · 2 部');
    expect(_dayTabTooltip(tester, 'OVA'), 'OVA · 1 部');

    // 点开就能看那两档的条目（选择只作用于「今日更新」这一块）。
    await _selectDay(tester, 'OVA');
    await tester.pumpAndSettle();
    expect(find.text('OVA 一部'), findsOneWidget);
    expect(find.text('OVA更新'), findsOneWidget, reason: '区头标题跟着走');
  });
}
