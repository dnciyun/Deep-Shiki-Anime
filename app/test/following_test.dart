/// 「正在追」页测试（spec §7.6）：追番标记持久化往返、卡片合成与筛选、空态。
///
/// **不联网、不起引擎**：追番标记用内存 KeyValueStore，引擎/队列用假数据。
library;

import 'package:dsanima/domain/following_store.dart';
import 'package:dsanima/domain/following_view.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/ui/following_page.dart';
import 'package:dsanima/ui/widgets/neo_dropdown.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 测试数据
// ─────────────────────────────────────────────────────────────────────────────

FollowingEntry _entry(
  String id,
  String title, {
  double? score,
  int? totalEpisodes,
  DateTime? watched,
}) => FollowingEntry(
  id: id,
  title: title,
  coverUrl: 'https://mikanani.me/images/Bangumi/202603/x.jpg',
  score: score,
  totalEpisodes: totalEpisodes,
  addedAt: DateTime(2026, 10, 1),
  lastWatchedAt: watched,
);

ScheduleEntryView _slot(int dow, String title, {DateTime? updatedAt}) => ScheduleEntryView(
  bangumiId: '3887',
  dayOfWeek: dow,
  title: title,
  updateText: '2026/10/07 更新',
  updatedAt: updatedAt ?? DateTime(2026, 10, 7),
);

ScheduleView _schedule(List<ScheduleEntryView> entries) => ScheduleView(
  entries: entries,
  byDay: <int, List<ScheduleEntryView>>{
    for (final ScheduleEntryView e in entries) e.dayOfWeek: <ScheduleEntryView>[e],
  },
  fetchedAt: DateTime(2026, 10, 7),
);

QueueJobView _job(String title, JobState state, {int priority = 10}) => QueueJobView(
  id: 'job-$title-$state',
  item: SourceItemView(id: 'i-$title', sourceId: 'mikan', title: title),
  state: state,
  priority: priority,
  createdAt: DateTime(2026, 10, 7),
  updatedAt: DateTime(2026, 10, 7),
);

EngineTorrentView _torrent(
  String name, {
  double progress = 0,
  bool finished = false,
  int bytes = 0,
}) => EngineTorrentView(
  id: name.hashCode.abs() % 1000,
  name: name,
  state: TorrentState.live,
  progress: progress,
  finished: finished,
  totalBytes: bytes,
  files: const <EngineFileView>[
    EngineFileView(index: 0, path: 'a.mkv', length: 1000, isVideo: true, complete: false),
  ],
);

void main() {
  group('追番标记持久化（FollowingStore）', () {
    test('toggle 往返：追 → 在列表里 → 再点取消 → 清空', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore();
      final FollowingStore following = FollowingStore(store);
      final FollowingEntry entry = _entry('mikan:3887', '转生就是剑 第二季');

      expect(following.load(), isEmpty);
      expect(await following.toggle(entry), isTrue);
      expect(following.isFollowing('mikan:3887'), isTrue);
      final List<FollowingEntry> loaded = following.load();
      expect(loaded, hasLength(1));
      expect(loaded.single.title, '转生就是剑 第二季');
      expect(loaded.single.coverUrl, contains('/images/Bangumi/'));

      expect(await following.toggle(entry), isFalse);
      expect(following.load(), isEmpty);
    });

    test('重启后仍在（同一份 KeyValueStore 再读一次）', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore();
      await FollowingStore(
        store,
      ).toggle(_entry('bgm:400602', '葬送的芙莉莲', score: 8.5, totalEpisodes: 28));

      final FollowingStore reopened = FollowingStore(store);
      final FollowingEntry entry = reopened.load().single;
      expect(entry.title, '葬送的芙莉莲');
      expect(entry.score, 8.5);
      expect(entry.totalEpisodes, 28);
      expect(entry.bgmId, isNull);
    });

    test('坏数据不让整份列表报废；touch 只更新最近观看', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore(<String, Object?>{
        FollowingStore.defaultKey: <Object?>[
          <String, Object?>{'id': '', 'title': '空 id 的坏记录'},
          'not-a-map',
          _entry('mikan:1', '正常的番').toJson(),
        ],
      });
      final FollowingStore following = FollowingStore(store);
      expect(following.load(), hasLength(1));
      await following.touch('mikan:1');
      expect(following.load().single.lastWatchedAt, isNotNull);
      await following.remove('mikan:1');
      expect(following.load(), isEmpty);
    });

    test('追番 id 稳定：同番不同入口 → 同一条记录', () {
      expect(followingIdFor(mikanBangumiId: '3887', title: 'X'), 'mikan:3887');
      expect(followingIdFor(bgmId: 400602, title: 'X'), 'bgm:400602');
      expect(followingIdFor(title: '葬送的芙莉莲 第二季'), followingIdFor(title: '葬送的芙莉莲第二季'));
    });
  });

  group('卡片合成（buildFollowingCards）', () {
    final DateTime now = DateTime(2026, 10, 7, 20);

    test('在播 + 今天真的更了 → 有更新角标、下次更新写周三', () {
      final List<FollowingCard> cards = buildFollowingCards(
        entries: <FollowingEntry>[_entry('mikan:1', '转生就是剑 第二季')],
        schedule: _schedule(<ScheduleEntryView>[_slot(3, '转生就是剑 第二季', updatedAt: now)]),
        jobs: const <QueueJobView>[],
        torrents: const <EngineTorrentView>[],
        now: now,
        todayDow: 3,
      );
      expect(cards, hasLength(1));
      expect(cards.single.hasUpdate, isTrue);
      expect(cards.single.nextUpdate, '周三 更新');
      expect(cards.single.isFinished, isFalse);
      expect(cards.single.status, FollowingStatus.watching);
      expect(cards.single.daysUntilUpdate, 0);
      // 没有引擎数据 → 不编「已缓存 0 集」这种行
      expect(cards.single.stateText, isNull);
    });

    test('不在本周追番表里 → **不是**「已完结」，而是中性的「无档期」', () {
      final List<FollowingCard> cards = buildFollowingCards(
        entries: <FollowingEntry>[_entry('bgm:1', '老番')],
        schedule: _schedule(<ScheduleEntryView>[_slot(3, '别的番')]),
        jobs: const <QueueJobView>[],
        torrents: const <EngineTorrentView>[],
        now: now,
      );
      expect(cards.single.hasNoSlot, isTrue);
      expect(cards.single.nextUpdate, '无档期', reason: 'mikan 首页只放正在播的：老番/未开播/停播都会落到这一支，不能说成已完结');
      expect(cards.single.isFinished, isFalse, reason: '没有证据就不能声称已完结');
      expect(cards.single.hasUpdate, isFalse);

      // 有上映日期 + 总话数、且最后一话早就播完 → 才允许显示「已完结」
      final List<FollowingCard> finished = buildFollowingCards(
        entries: <FollowingEntry>[
          _entry('bgm:2', '早完结的番', totalEpisodes: 12).copyWith(airDate: '2015-04-05'),
        ],
        schedule: _schedule(<ScheduleEntryView>[_slot(3, '别的番')]),
        jobs: const <QueueJobView>[],
        torrents: const <EngineTorrentView>[],
        now: now,
      );
      expect(finished.single.isFinished, isTrue);
      expect(finished.single.nextUpdate, '已完结');

      // 证据不足（只有日期没有话数）→ 还是「无档期」
      final List<FollowingCard> half = buildFollowingCards(
        entries: <FollowingEntry>[_entry('bgm:3', '只有日期的番').copyWith(airDate: '2015-04-05')],
        schedule: _schedule(<ScheduleEntryView>[_slot(3, '别的番')]),
        jobs: const <QueueJobView>[],
        torrents: const <EngineTorrentView>[],
        now: now,
      );
      expect(half.single.nextUpdate, '无档期');
    });

    test('inferFinished：证据不足一律 null（不猜）', () {
      final DateTime now = DateTime(2026, 10, 7);
      expect(inferFinished(airDate: null, eps: 12, now: now), isNull);
      expect(inferFinished(airDate: '2015-04-05', eps: null, now: now), isNull);
      expect(inferFinished(airDate: '2015-04-05', eps: 0, now: now), isNull);
      expect(inferFinished(airDate: '乱码', eps: 12, now: now), isNull);
      expect(inferFinished(airDate: '2015-04-05', eps: 12, now: now), isTrue);
      // 刚开播的番：不能算完结
      expect(inferFinished(airDate: '2026-10-01', eps: 12, now: now), isFalse);
      // 正在播的番本来就该「没档期」→ 也不会走到这里
      expect(inferFinished(airDate: '2026-08-01', eps: 12, now: now), isFalse);
    });

    test('引擎里正在下 → 下载中 + 百分比；队列里排队 → 队列中', () {
      final List<FollowingCard> downloading = buildFollowingCards(
        entries: <FollowingEntry>[_entry('mikan:1', '迷宫饭')],
        schedule: _schedule(<ScheduleEntryView>[_slot(3, '迷宫饭')]),
        jobs: const <QueueJobView>[],
        torrents: <EngineTorrentView>[_torrent('[ANi] 迷宫饭 - 12 [1080p]', progress: 0.62)],
        now: now,
      );
      expect(downloading.single.status, FollowingStatus.downloading);
      expect(downloading.single.stateText, '下载中 62%');
      expect(downloading.single.progressLabel, '第 12 话');
      expect(downloading.single.playableFile, isNotNull, reason: '有可播文件才能点「继续观看」');

      final List<FollowingCard> queued = buildFollowingCards(
        entries: <FollowingEntry>[_entry('mikan:2', '青之箱', totalEpisodes: 25)],
        schedule: _schedule(<ScheduleEntryView>[_slot(4, '青之箱')]),
        jobs: <QueueJobView>[_job('青之箱 - 11', JobState.queued)],
        torrents: const <EngineTorrentView>[],
        now: now,
      );
      expect(queued.single.status, FollowingStatus.queued);
      expect(queued.single.stateText, '队列中 · 等待下载');
      expect(queued.single.progressLabel, '第 11 话 / 共 25 话');
    });

    test('已下完 → 显示缓存集数与体积；筛选「已完结」只留没档期的', () {
      final List<FollowingEntry> entries = <FollowingEntry>[
        _entry('mikan:1', '葬送的芙莉莲', score: 8.5),
        _entry('bgm:2', '早就完结的番'),
      ];
      final List<FollowingCard> all = buildFollowingCards(
        entries: entries,
        schedule: _schedule(<ScheduleEntryView>[_slot(3, '葬送的芙莉莲')]),
        jobs: const <QueueJobView>[],
        torrents: <EngineTorrentView>[
          _torrent(
            '[ANi] 葬送的芙莉莲 第二季 - 28 [1080p]',
            progress: 1,
            finished: true,
            bytes: 41000000000,
          ),
        ],
        now: now,
      );
      final FollowingCard frieren = all.firstWhere((FollowingCard c) => c.entry.title == '葬送的芙莉莲');
      expect(frieren.stateText, contains('已缓存 1 个种子'));
      expect(frieren.stateText, contains('GiB'));
      expect(frieren.playableFile, isNotNull);
      expect(frieren.entry.score, 8.5);

      final List<FollowingCard> unslotted = buildFollowingCards(
        entries: entries,
        schedule: _schedule(<ScheduleEntryView>[_slot(3, '葬送的芙莉莲')]),
        jobs: const <QueueJobView>[],
        torrents: const <EngineTorrentView>[],
        now: now,
        filter: FollowingFilter.unslotted,
      );
      expect(unslotted.map((FollowingCard c) => c.entry.title), <String>['早就完结的番']);

      final List<FollowingCard> updated = buildFollowingCards(
        entries: entries,
        schedule: _schedule(<ScheduleEntryView>[_slot(3, '葬送的芙莉莲', updatedAt: now)]),
        jobs: const <QueueJobView>[],
        torrents: const <EngineTorrentView>[],
        now: now,
        todayDow: 3,
        filter: FollowingFilter.updated,
      );
      expect(updated, hasLength(1));
      expect(updated.single.entry.title, '葬送的芙莉莲');
    });

    test('排序：今天更新的排最前（其次距下次更新最近）', () {
      final List<FollowingCard> cards = buildFollowingCards(
        entries: <FollowingEntry>[_entry('mikan:1', '周五的番'), _entry('mikan:2', '今天更新的番')],
        schedule: _schedule(<ScheduleEntryView>[
          ScheduleEntryView(
            bangumiId: '1',
            dayOfWeek: 5,
            title: '周五的番',
            updateText: '2026/09/30 更新',
            updatedAt: DateTime(2026, 9, 30),
          ),
          ScheduleEntryView(
            bangumiId: '2',
            dayOfWeek: 3,
            title: '今天更新的番',
            updateText: '2026/10/07 更新',
            updatedAt: now,
          ),
        ]),
        jobs: const <QueueJobView>[],
        torrents: const <EngineTorrentView>[],
        now: now,
        todayDow: 3,
      );
      expect(cards.first.entry.title, '今天更新的番');
      expect(cards.first.daysUntilUpdate, 0);
    });
  });

  group('「正在追」页 widget', () {
    Widget harness(
      Widget child, {
      List<FollowingEntry> following = const <FollowingEntry>[],
      ScheduleView? schedule,
    }) => ProviderScope(
      overrides: [
        keyValueStoreProvider.overrideWithValue(
          InMemoryKeyValueStore(<String, Object?>{
            SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
            if (following.isNotEmpty)
              FollowingStore.defaultKey: following
                  .map((FollowingEntry e) => e.toJson())
                  .toList(growable: false),
          }),
        ),
        schedulePortProvider.overrideWithValue(_FakeSchedulePort(schedule)),
        enginePortProvider.overrideWithValue(const UnavailableEnginePort()),
        queuePortProvider.overrideWithValue(const UnavailableQueuePort()),
        subsPortProvider.overrideWithValue(const UnavailableSubsPort()),
        playerPortProvider.overrideWithValue(const UnavailablePlayerPort()),
        pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
        sourcePortProvider.overrideWithValue(const UnavailableSourcePort()),
        todayProvider.overrideWithValue(DateTime(2026, 10, 7, 20)),
      ],
      child: MaterialApp(
        theme: buildDsanimaTheme(),
        home: Scaffold(body: child),
      ),
    );

    testWidgets('空态：说明去哪里追番，并给「去主页看看」', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness(const FollowingPage()));
      await tester.pumpAndSettle();

      expect(find.text('还没有追番'), findsOneWidget);
      expect(find.textContaining('不会自动下载'), findsOneWidget);
      expect(find.text('去主页看看'), findsOneWidget);
      // 筛选收成了下拉（用户 2026-10-10 第 3 轮问答）。
      expect(find.textContaining('筛选 ·'), findsOneWidget);
    });

    testWidgets('有追番：渲染封面卡（形态同「已完成」）+ 总勾 + 筛选只留没档期的', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1500, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final List<FollowingEntry> following = <FollowingEntry>[
        _entry('mikan:1', '在播的番', score: 8.5, totalEpisodes: 24),
        _entry('mikan:2', '没档期的番'),
      ];
      final ScheduleView schedule = _schedule(<ScheduleEntryView>[
        ScheduleEntryView(
          bangumiId: '1',
          dayOfWeek: 3,
          title: '在播的番',
          updateText: '2026/10/07 更新',
          updatedAt: DateTime(2026, 10, 7, 20),
        ),
      ]);

      await tester.pumpWidget(
        harness(const FollowingPage(), following: following, schedule: schedule),
      );
      await tester.pumpAndSettle();

      expect(find.text('在播的番'), findsOneWidget);
      expect(find.text('没档期的番'), findsOneWidget);
      expect(find.text('2 部 · 1 部有更新'), findsOneWidget);
      expect(find.text('周三 更新'), findsOneWidget);
      // 没有档期 ≠ 已完结：中性文案「无档期」（卡片状态行）
      expect(find.text('无档期'), findsWidgets);
      expect(find.text('已完结'), findsNothing, reason: '没有证据（上映日期+总话数）就不能说已完结');
      expect(find.textContaining('★8.5'), findsOneWidget);
      expect(find.text('在追'), findsWidgets);
      // 第二十七轮：卡上给出"这一部订了几个字幕组"（没有订阅时是提示语）。
      expect(find.textContaining('未订阅字幕组'), findsWidgets);
      // 「继续观看」按用户要求去掉了（点整张卡进点开层）。
      expect(find.text('继续观看'), findsNothing);

      // 点「无档期」筛选（下拉）→ 只剩没档期的那部。
      // 下拉已换成 `NeoDropdown`（用户 2026-10-11：DropdownButton 展开有撕裂感）。
      await tester.tap(find.byType(NeoDropdown<FollowingFilter>));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('筛选 · 无档期').last);
      await tester.pumpAndSettle();
      expect(find.text('没档期的番'), findsOneWidget);
      expect(find.text('在播的番'), findsNothing);
    });

    testWidgets('封面卡在**网格槽尺寸**下不溢出（独立复核抓到的 3.0px 溢出）', (WidgetTester tester) async {
      // 为什么单独一条：卡片高度是常量，而"内容和常量是不是配得上"只有真的把它塞进
      // 那个尺寸才看得出来。上一版 `kFollowingGridExtent = 232` 时列里溢 3.0px
      //（`FlutterError.onError` 报 "A RenderFlex overflowed by 3.0 pixels on the bottom"），
      // 网格页看起来只是"某张卡下面的字被切了一点"，很容易漏掉。
      final List<String> overflows = <String>[];
      final void Function(FlutterErrorDetails)? old = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        overflows.add(details.exceptionAsString());
      };
      addTearDown(() => FlutterError.onError = old);

      tester.view.physicalSize = const Size(1500, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness(
          Scaffold(
            body: SizedBox(
              width: kFollowingGridMaxExtent,
              height: kFollowingGridExtent,
              child: FollowingGridCard(
                card: buildFollowingCards(
                  entries: <FollowingEntry>[_entry('mikan:1', '葬送的芙莉莲 第二季 黄金乡篇', score: 8.5)],
                  schedule: _schedule(const <ScheduleEntryView>[]),
                  jobs: const <QueueJobView>[],
                  torrents: const <EngineTorrentView>[],
                  now: DateTime(2026, 10, 7, 20),
                ).single,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(overflows, isEmpty,
          reason: '卡片必须在网格槽尺寸里放得下（含两行番名）；溢出会被 FlutterError 收到');
    });
  });
}

/// 只提供 mikan 追番表的假端口（不联网）。
class _FakeSchedulePort implements SchedulePort {
  _FakeSchedulePort(this.view);

  final ScheduleView? view;

  @override
  bool get isAvailable => view != null;

  @override
  Future<ScheduleView> schedule() async => view!;

  @override
  Future<BangumiDetailView> bangumi(String bangumiId) async =>
      BangumiDetailView(bangumiId: bangumiId);
}
