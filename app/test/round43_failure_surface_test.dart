/// 第四十二/四十三轮「失败必须浮出来」的回归钉。
///
/// 这一批缺陷有同一个签名：**只测了成功路**（写盘成功、provider 有数据、输入合法），
/// 于是失败路静默了整整四十二轮。所以下面每条用例都成对——成功一条、失败一条，
/// 或者直接构造失败态断言"用户看得见"。
///
/// 不联网、不起引擎、不碰用户数据（HANDOFF §7）：全部走内存 KV 与不可用端口。
library;

import 'dart:async';
import 'dart:ui' show Tristate;
import 'dart:io' show FileSystemException;

import 'package:dsanima/domain/aggregate.dart';
import 'package:dsanima/domain/bangumi.dart';
import 'package:dsanima/domain/error_text.dart';
import 'package:dsanima/domain/following_store.dart';
import 'package:dsanima/domain/following_subscription.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/domain/watch_history.dart';
import 'package:dsanima/state/global_failure.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/theme/tokens.dart';
import 'package:dsanima/ui/history_page.dart';
import 'package:dsanima/ui/widgets/follow_button.dart';
import 'package:dsanima/ui/widgets/neo_appearance_picker.dart';
import 'package:dsanima/ui/widgets/state_views.dart';
import 'package:dsanima_core/sources/kv.dart'
    show InMemoryKeyValueStore, KeyValueStore;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 落盘一定失败的 KV：用来验证"内存态要回滚、异常要抛给调用方"。
class _FailingStore implements KeyValueStore {
  _FailingStore(this._inner);

  final KeyValueStore _inner;
  int attempts = 0;

  @override
  Object? get(String key) => _inner.get(key);

  @override
  Iterable<String> get keys => _inner.keys;

  @override
  Future<void> put(String key, Object? value) async {
    attempts++;
    throw const FileSystemException('模拟落盘失败');
  }

  @override
  Future<void> delete(String key) async {
    attempts++;
    throw const FileSystemException('模拟落盘失败');
  }

  @override
  Future<void> clear() async {
    attempts++;
    throw const FileSystemException('模拟落盘失败');
  }
}

WatchRecord _record({String id = 'r1', String title = '葬送的芙莉莲'}) => WatchRecord(
  id: id,
  title: title,
  group: 'ANi',
  episode: 8,
  watchedAt: DateTime(2026, 10, 14, 12),
  positionMs: 600000,
  durationMs: 1440000,
);

ProviderContainer _container(KeyValueStore store) => ProviderContainer(
  overrides: [
    keyValueStoreProvider.overrideWithValue(store),
    enginePortProvider.overrideWithValue(const UnavailableEnginePort()),
    queuePortProvider.overrideWithValue(const UnavailableQueuePort()),
    subsPortProvider.overrideWithValue(const UnavailableSubsPort()),
    playerPortProvider.overrideWithValue(const UnavailablePlayerPort()),
    pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
    sourcePortProvider.overrideWithValue(const UnavailableSourcePort()),
  ],
);

Widget _historyHarness(InMemoryKeyValueStore store) => ProviderScope(  overrides: [
    keyValueStoreProvider.overrideWithValue(store),
    enginePortProvider.overrideWithValue(const UnavailableEnginePort()),
    queuePortProvider.overrideWithValue(const UnavailableQueuePort()),
    subsPortProvider.overrideWithValue(const UnavailableSubsPort()),
    playerPortProvider.overrideWithValue(const UnavailablePlayerPort()),
    pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
    sourcePortProvider.overrideWithValue(const UnavailableSourcePort()),
  ],
  child: MaterialApp(
    theme: buildDsanimaTheme(),
    home: const Scaffold(body: HistoryPage()),
  ),
);

// ─────────────────────────────────────────────────────────────────────────────
// 搜索并发守卫用的替身（UX #6）
// ─────────────────────────────────────────────────────────────────────────────

SourcePageView _pageWith(String tag, int n) => SourcePageView(
  items: <SourceItemView>[
    for (int i = 1; i <= n; i++)
      SourceItemView(id: '$tag-$i', sourceId: tag, title: '$tag-$i'),
  ],
  page: 1,
  hasNext: false,
  fetchedAt: DateTime(2026, 10, 15, 12),
);

/// 可控假源：每个请求都记下来；[gated] 打开后每条请求都挂在一个 Completer 上，
/// 由测试决定**谁先回来**（真实网络的乱序就是这么来的）。
class _GatedSource implements SourcePort {
  final List<String> calls = <String>[];
  final List<Completer<SourcePageView>> _gates = <Completer<SourcePageView>>[];

  bool gated = false;

  @override
  List<SourceOption> get sources => const <SourceOption>[
    SourceOption(id: 'mikan', displayName: 'mikanani.me'),
    SourceOption(id: 'nyaa', displayName: 'nyaa.si 动漫区'),
  ];

  @override
  Future<SourcePageView> latest(String sourceId, {int page = 1}) =>
      _serve(sourceId, '', page);

  @override
  Future<SourcePageView> search(String sourceId, String keyword, {int page = 1}) =>
      _serve(sourceId, keyword, page);

  Future<SourcePageView> _serve(String sourceId, String keyword, int page) {
    calls.add('$sourceId|$keyword|$page');
    if (!gated) return Future<SourcePageView>.value(_pageWith(sourceId, 1));
    final Completer<SourcePageView> gate = Completer<SourcePageView>();
    _gates.add(gate);
    return gate.future;
  }

  /// 放行第 [index] 个请求（调用顺序即下标）。
  void release(int index, SourcePageView page) => _gates[index].complete(page);
}

/// 可分页、可注入失败的假源（UX #21：翻页失败与重试）。
class _PagedSource implements SourcePort {
  _PagedSource(this.pages);

  final Map<int, List<SourceItemView>> pages;
  final List<int> requested = <int>[];

  /// 这一页的请求直接抛错（模拟"翻页时网络断了"）。
  int? failPage;

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
    if (failPage == page) {
      throw const PortUnavailableException('源暂时不可用', hint: '稍后重试');
    }
    return SourcePageView(
      items: pages[page] ?? const <SourceItemView>[],
      page: page,
      hasNext: pages.containsKey(page + 1),
      fetchedAt: DateTime(2026, 10, 15, 12),
    );
  }
}

List<SourceItemView> _pagedItems(int from, int to) => <SourceItemView>[
  for (int i = from; i <= to; i++)
    SourceItemView(id: 'id$i', sourceId: 'mikan', title: '第 $i 话'),
];

/// 订阅端口替身：只做这一组用例要的两件事（发出订阅列表、记录 remove）。
class _FakeSubsPort extends UnavailableSubsPort implements SubsPort {
  _FakeSubsPort(this.subs);

  final List<SubscriptionView> subs;
  final List<String> removed = <String>[];

  @override
  Stream<List<SubscriptionView>> watch() =>
      Stream<List<SubscriptionView>>.value(subs);

  @override
  Future<void> remove(String id) async => removed.add(id);
}

ProviderContainer _searchContainer(SourcePort source) {  final ProviderContainer c = ProviderContainer(
    overrides: [
      keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
      sourcePortProvider.overrideWithValue(source),
    ],
  );
  // 本组用例盯的是"单独源"那条路：聚合那条路会同时问多个源，看不出换源错配。
  c.read(searchProvider.notifier).setMode(SearchMode.single);
  return c;
}

void main() {
  group('describeFailure：Bangumi 异常不再把技术文本当主标题（UX #15）', () {
    test('404 → 说"没有这一条"，不是 `BangumiException(… · HTTP 404 · url)`', () {
      final DsFailure f = describeFailure(BangumiException(
        'subject not found',
        statusCode: 404,
        url: Uri.parse('https://api.bgm.tv/v0/subjects/999999'),
      ));
      expect(f.message, contains('没有这一条'));
      expect(f.message, isNot(contains('BangumiException')));
      expect(f.hint, isNotNull, reason: '每一条失败都要有"怎么办"');
    });

    test('401/403 → 指向限流与代理；5xx → 说明是对面挂了', () {
      final DsFailure limited =
          describeFailure(BangumiException('forbidden', statusCode: 403));
      expect(limited.message, contains('403'));
      expect(limited.hint, contains('限流'));

      final DsFailure down =
          describeFailure(BangumiException('bad gateway', statusCode: 502));
      expect(down.message, contains('502'));
      expect(down.hint, contains('对面'));
    });

    test('52x（Cloudflare 源站连不上）→ 点名"是他们那边挂了、换 IP 没用"', () {
      // 第五十一轮：用户看到 "动漫库接口返不回来" 时第一反应就是"是不是封我 IP 了"，
      // 实测当天 api.bgm.tv / bgm.tv 整片 522（第三方多地区监控同样复现）——
      // 文案必须把这个误会一次说清，否则用户会去折腾代理/多 IP。
      for (final int code in <int>[520, 521, 522, 523, 524]) {
        final DsFailure f = describeFailure(BangumiException(
          'error code: $code',
          statusCode: code,
          url: Uri.parse('https://api.bgm.tv/v0/subjects'),
        ));
        expect(f.message, contains('$code'));
        expect(f.message, contains('连不上'));
        expect(f.hint, contains('不是你这边'), reason: '不能把官方宕机说成用户的网络问题');
        expect(f.hint, contains('换 IP'));
      }

      // 502 是通用「上游挂了」，不是 Cloudflare 的源站错误 —— 走原来那条文案。
      final DsFailure gateway =
          describeFailure(BangumiException('bad gateway', statusCode: 502));
      expect(gateway.message, contains('服务器出错'));
    });

    test('429 → 说"被限流、等一会"，并明说别用多 IP 轮换', () {
      final DsFailure f =
          describeFailure(BangumiException('too many requests', statusCode: 429));
      expect(f.message, contains('429'));
      expect(f.hint, contains('限流'));
      expect(f.hint, contains('轮换'), reason: '防呆：多 IP 轮换会被官方按滥用处理');
    });

    test('未知异常：detail 里不出现本机绝对路径（堆栈被压成函数名）', () {
      final DsFailure f = describeFailure(
        StateError('boom'),
        stackTrace: StackTrace.fromString(
          '#0      Foo.bar (package:dsanima/ui/x.dart:12:3)\n'
          '#1      Baz.qux (file:///C:/Users/someone/secret/app/lib/y.dart:9:1)\n'
          '#2      main (file:///C:/Users/someone/secret/app/lib/main.dart:1:1)\n',
        ),
      );
      expect(f.message, contains('操作失败'));
      expect(f.detail, isNotNull);
      expect(f.detail, contains('Foo.bar'), reason: '定位价值要保留');
      expect(f.detail, isNot(contains('C:/Users')), reason: '不许把用户名和目录发出去');
      expect(f.detail, isNot(contains('secret')));
    });
  });

  group('观看记录：落盘失败要回滚内存态并把异常抛给调用方（UX #5）', () {
    test('成功路：删掉一条 → 内存与磁盘都没有它', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore(<String, Object?>{
        SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
        WatchHistoryStore.defaultKey: <Object?>[_record().toJson()],
      });
      final ProviderContainer c = _container(store);
      addTearDown(c.dispose);
      expect(c.read(watchHistoryProvider), hasLength(1));

      await c.read(watchHistoryProvider.notifier).remove('r1');
      expect(c.read(watchHistoryProvider), isEmpty, reason: '内存里没了');
      expect(WatchHistoryStore(store).load(), isEmpty, reason: '盘上也没了');
    });

    test('失败路：删除抛异常，**内存态回到删除前**（界面不能显示一条没落盘的删除）', () async {
      final _FailingStore store = _FailingStore(
        InMemoryKeyValueStore(<String, Object?>{
          SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
          WatchHistoryStore.defaultKey: <Object?>[_record().toJson()],
        }),
      );
      final ProviderContainer c = _container(store);
      addTearDown(c.dispose);
      expect(c.read(watchHistoryProvider), hasLength(1));

      await expectLater(
        c.read(watchHistoryProvider.notifier).remove('r1'),
        throwsA(isA<FileSystemException>()),
        reason: '调用方（界面）必须拿到失败信号，才能报错',
      );
      expect(store.attempts, 1);
      expect(
        c.read(watchHistoryProvider),
        hasLength(1),
        reason: '回滚：屏幕上那条记录不能凭空消失（重启后会"复活"就自相矛盾了）',
      );
    });

    test('撤销：restore 把它放回**原来的位置**（按 watchedAt 排序，不是追加到末尾）', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore(<String, Object?>{
        SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
        WatchHistoryStore.defaultKey: <Object?>[
          _record(id: 'new', title: '新的').toJson(),
          _record(id: 'old', title: '旧的').toJson(),
        ],
      });
      final ProviderContainer c = _container(store);
      addTearDown(c.dispose);
      final WatchHistoryController history = c.read(watchHistoryProvider.notifier);
      final WatchRecord newOne = c.read(watchHistoryProvider).first;
      final WatchRecord oldOne = c.read(watchHistoryProvider).last;

      await history.remove(newOne.id);
      expect(c.read(watchHistoryProvider).single.id, oldOne.id);
      await history.restore(newOne);
      expect(
        c.read(watchHistoryProvider).map((WatchRecord r) => r.id).toList(),
        <String>[newOne.id, oldOne.id],
        reason: '撤销之后顺序与删之前一致',
      );
    });
  });

  group('「已看过」标记：落盘失败也回滚（UX #5）', () {
    test('失败路：打勾抛异常，勾不许留在内存里', () async {
      final _FailingStore store = _FailingStore(InMemoryKeyValueStore(<String, Object?>{
        SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
      }));
      final ProviderContainer c = _container(store);
      addTearDown(c.dispose);
      final WatchedMarksController marks = c.read(watchedMarksProvider.notifier);

      await expectLater(
        marks.mark(<String>['k1'], byUser: true),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        c.read(watchedMarksProvider),
        isEmpty,
        reason: '勾没落盘就不该显示成已看过（重启后消失等于撒谎）',
      );
      expect(marks.isWatched('k1'), isFalse);
    });

    test('成功路：打勾 → 内存与磁盘都记上了', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore(<String, Object?>{
        SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
      });
      final ProviderContainer c = _container(store);
      addTearDown(c.dispose);
      await c.read(watchedMarksProvider.notifier).mark(<String>['k1'], byUser: true);
      expect(c.read(watchedMarksProvider).containsKey('k1'), isTrue);
      expect(WatchedMarkStore(store).load().containsKey('k1'), isTrue);
    });
  });

  group('DsAsync：错误不许被旧数据吃掉（UX #3）', () {
    testWidgets('有旧数据 + 出错 ⇒ 顶部错误横幅 + 旧数据继续可读 + 能重试', (WidgetTester tester) async {
      bool fail = false;
      final FutureProvider<String> value = FutureProvider<String>((Ref ref) async {
        if (fail) throw StateError('引擎挂了');
        return '第一份数据';
      });
      int retries = 0;

      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          theme: buildDsanimaTheme(),
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) => Scaffold(
              body: DsAsync<String>(
                value: ref.watch(value),
                onRetry: () {
                  retries++;
                  ref.invalidate(value);
                },
                builder: (BuildContext context, String data) => Text('数据：$data'),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('数据：第一份数据'), findsOneWidget);

      // 让 provider 变成"有旧值 + 有错误"——这正是 riverpod 保留旧数据的情形。
      final ProviderContainer c = ProviderScope.containerOf(
        tester.element(find.text('数据：第一份数据')),
      );
      fail = true;
      c.invalidate(value);
      await tester.pumpAndSettle();

      expect(find.text('数据：第一份数据'), findsOneWidget, reason: '旧数据不闪白、不消失');
      expect(find.textContaining('引擎挂了'), findsOneWidget, reason: '错误必须说出来');
      expect(find.textContaining('上一次成功读到的内容'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget, reason: '横幅要能一键重试');
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(retries, 1);
    });

    testWidgets('没有数据 + 出错 ⇒ 整屏错误面板（带重试），不是空列表', (WidgetTester tester) async {
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          theme: buildDsanimaTheme(),
          home: Scaffold(
            body: DsAsync<String>(
              value: AsyncError<String>(StateError('引擎没连上'), StackTrace.empty),
              onRetry: () {},
              builder: (BuildContext context, String data) => Text('不该渲染：$data'),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('引擎没连上'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.textContaining('不该渲染'), findsNothing);
    });
  });

  group('观看记录页：单条删除可撤销 + 空态带动作（UX #17/#20）', () {
    testWidgets('删掉一条 → 提示带「撤销」→ 点撤销就回来了', (WidgetTester tester) async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore(<String, Object?>{
        SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
        WatchHistoryStore.defaultKey: <Object?>[_record().toJson()],
      });
      await tester.pumpWidget(_historyHarness(store));
      await tester.pumpAndSettle();
      expect(find.text('葬送的芙莉莲'), findsOneWidget);

      await tester.tap(find.byTooltip('从观看记录里删掉这一条'));
      await tester.pumpAndSettle();
      expect(WatchHistoryStore(store).load(), isEmpty, reason: '真删掉了');
      expect(find.text('撤销'), findsOneWidget, reason: '不可逆的动作必须给后悔的机会');

      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(find.text('葬送的芙莉莲'), findsOneWidget, reason: '撤销之后记录回来');
      expect(
        WatchHistoryStore(store).load().single.title,
        '葬送的芙莉莲',
        reason: '撤销也要真的落盘',
      );
    });

    testWidgets('空态给一个下一步动作（不是干说"还没有观看记录"）', (WidgetTester tester) async {
      await tester.pumpWidget(_historyHarness(
        InMemoryKeyValueStore(<String, Object?>{
          SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
        }),
      ));
      await tester.pumpAndSettle();
      expect(find.text('还没有观看记录'), findsOneWidget);
      expect(find.text('去搜索'), findsOneWidget);
    });
  });

  group('续播起点规则（UX #2：界面写「看到 12:34」就必须从那儿开始）', () {
    test('看到一半 → 就从那儿接着播', () {
      expect(_record().resumePositionMs, 600000);
    });

    test('已看完 → 从头（那一行的按钮写的是「重看」，不是「继续播放」）', () {
      final WatchRecord done = _record().copyWith(positionMs: 1400000);
      expect(done.finished, isTrue);
      expect(done.resumePositionMs, isNull);
    });

    test('没有进度记录 → 从头', () {
      expect(_record().copyWith(positionMs: 0).resumePositionMs, isNull);
    });

    test('时长未知但有位置 → 照样从那儿接着播（不因为"不知道总长"就当没进度）', () {
      final WatchRecord partial = _record().copyWith(durationMs: 0);
      expect(partial.finished, isFalse);
      expect(partial.resumePositionMs, 600000);
    });
  });

  group('搜索并发守卫（UX #6：加载中改词/换源不许被吞、旧回应不许落到新源名下）', () {
    test('加载中提交新关键字：新查询**真的发出去**了（旧实现直接 return 吞掉）', () async {
      final _GatedSource source = _GatedSource()..gated = true;
      final ProviderContainer c = _searchContainer(source);
      addTearDown(c.dispose);
      final SearchQueryController search = c.read(searchProvider.notifier);

      search.setKeyword('第一版');
      final Future<void> first = search.refresh(); // 卡在网关上（在飞）
      expect(source.calls, <String>['mikan|第一版|1']);

      // 用户等不及，改了词再按一次搜索。
      search.setKeyword('第二版');
      final Future<void> second = search.refresh();
      expect(
        source.calls,
        <String>['mikan|第一版|1', 'mikan|第二版|1'],
        reason: '这是一个**新意图**，必须放行 —— 旧实现 `if (state.loading) return;` 会把它吞掉',
      );

      // 先放行新一轮，再放行旧一轮：旧的一轮回来时必须被丢掉。
      source.release(1, _pageWith('第二版', 2));
      await second;
      source.release(0, _pageWith('第一版', 1));
      await first;

      final SearchState state = c.read(searchProvider);
      expect(state.loading, isFalse, reason: '收尾要归位，不能永远转圈');
      expect(state.loaded, isTrue);
      expect(
        state.fetched.map((SourceItemView i) => i.title).toList(),
        <String>['第二版-1', '第二版-2'],
        reason: '池子里只能是新一轮的结果；旧一轮那两条不许挂进来',
      );
    });

    test('换源途中回来的旧源结果：不许挂到新源名下', () async {
      final _GatedSource source = _GatedSource()..gated = true;
      final ProviderContainer c = _searchContainer(source);
      addTearDown(c.dispose);
      final SearchQueryController search = c.read(searchProvider.notifier);

      final Future<void> first = search.refresh(); // mikan
      expect(source.calls, <String>['mikan||1']);

      // 换源：`setSource` 在"还没出结果"时不会自己重查（默认不加载那条规矩），
      // 所以界面那个 onChanged 会再显式 refresh 一次 —— 这里照它的样子做。
      search.setSource('nyaa');
      final Future<void> second = search.refresh();
      expect(source.calls, <String>['mikan||1', 'nyaa||1']);

      // 新的先回来，旧的后回来（真实网络就是这样乱序的）。
      source.release(1, _pageWith('nyaa', 2));
      await second;
      source.release(0, _pageWith('mikan', 3));
      await first;

      final SearchState state = c.read(searchProvider);
      expect(state.sourceId, 'nyaa');
      expect(
        state.fetched.map((SourceItemView i) => i.title).toList(),
        <String>['nyaa-1', 'nyaa-2'],
        reason: '旧源（mikan）那批回来得再晚也不许写进新源的池子',
      );
      expect(state.loading, isFalse);
    });

    test('同一个意图重复提交：只打一次网络（旧守卫真正想挡的就是这个）', () async {
      final _GatedSource source = _GatedSource()..gated = true;
      final ProviderContainer c = _searchContainer(source);
      addTearDown(c.dispose);
      final SearchQueryController search = c.read(searchProvider.notifier);

      search.setKeyword('同一个词');
      final Future<void> first = search.refresh();
      final Future<void> second = search.refresh(); // 连点两下搜索
      expect(
        source.calls,
        <String>['mikan|同一个词|1'],
        reason: '源下拉那次"setSource 自带刷新 + 显式再刷新"不能变成两次网络请求',
      );
      source.release(0, _pageWith('同一个词', 1));
      await Future.wait(<Future<void>>[first, second]);
      expect(c.read(searchProvider).loading, isFalse);
    });
  });

  group('翻页失败给重试入口（UX #21）', () {
    test('翻页失败 → retryFailedPage 真的再发一次，并且落到那一页', () async {
      final _PagedSource source = _PagedSource(<int, List<SourceItemView>>{
        1: _pagedItems(1, 20),
        2: _pagedItems(21, 40),
      })..failPage = 2;
      final ProviderContainer c = _searchContainer(source);
      addTearDown(c.dispose);
      final SearchQueryController search = c.read(searchProvider.notifier);

      await search.refresh();
      expect(c.read(searchProvider).page, 1);
      expect(source.requested, <int>[1]);

      await search.goToPage(2);
      expect(c.read(searchProvider).failure, isNotNull, reason: '取数失败要有说明');
      expect(c.read(searchProvider).page, 1, reason: '失败就留在原页，已拿到的结果不清');
      expect(source.requested, <int>[1, 2]);

      // 横幅上那颗「重试」：源恢复了，再走一遍同一页。
      source.failPage = null;
      await search.retryFailedPage();
      expect(source.requested, <int>[1, 2, 2], reason: '重试必须真的再发一次请求');
      expect(c.read(searchProvider).failure, isNull, reason: '成功了就把错误收掉');
      expect(c.read(searchProvider).page, 2);
      expect(c.read(searchProvider).items.first.id, 'id21');
    });

    test('没有翻页目标时「重试」= 重来一次整轮搜索（不是什么都不做）', () async {
      final _PagedSource source =
          _PagedSource(<int, List<SourceItemView>>{1: _pagedItems(1, 5)});
      final ProviderContainer c = _searchContainer(source);
      addTearDown(c.dispose);
      final SearchQueryController search = c.read(searchProvider.notifier);

      await search.retryFailedPage();
      expect(source.requested, <int>[1]);
      expect(c.read(searchProvider).loaded, isTrue);
    });
  });

  group('结果行的来源要写人看的名字（UX #16）', () {
    const List<SourceOption> sources = <SourceOption>[
      SourceOption(id: 'mikan', displayName: 'mikanani.me'),
      SourceOption(id: 'dmhy-batch', displayName: '动漫花园（整季打包）'),
    ];

    test('源表里的 id → displayName（与「源」面板同一个名字）', () {
      expect(sourceLabelFor('mikan', sources), 'mikanani.me');
      expect(sourceLabelFor('dmhy-batch', sources), '动漫花园（整季打包）');
    });

    test('订阅源 `rss:<id>` → 「订阅源」：订阅名在这一层拿不到，不编', () {
      expect(sourceLabelFor('rss:8f3a1c9e', sources), '订阅源');
    });

    test('查不到的 id → 原样显示（宁可难看，也不要显示一个错的源名）', () {
      expect(sourceLabelFor('gone-source', sources), 'gone-source');
    });
  });

  group('取消追番：有字幕组订阅时要问一句（UX #27）', () {
    /// 一部番 + 它的一个字幕组订阅。
    FollowingEntry entryOf() => FollowingEntry(
      id: 'bgm:3887',
      title: '葬送的芙莉莲',
      mikanBangumiId: '3887',
      addedAt: DateTime(2026, 10, 1),
    );

    SubscriptionView subOf() => const SubscriptionView(
      id: 'sub-1',
      name: '葬送的芙莉莲 · ANi',
      feedUrl: 'https://mikanani.me/RSS/Bangumi?bangumiId=3887&subgroupid=1',
      sourceKind: 'rss',
      sourceParams: <String, String>{
        kSubParamBangumiId: '3887',
        kSubParamGroupName: 'ANi',
      },
    );

    /// ⚠️ 测试里必须有一处**常驻 watch** `subscriptionsProvider`：真实应用里那是
    /// 主页（`home_page.dart:203` 一直在看它），订阅列表因此是现成的；只挂一颗
    /// `FollowButton` 的话那条流根本没人订阅，`.value` 永远是 null。
    Widget harness(_FakeSubsPort subs) => ProviderScope(
      overrides: [
        keyValueStoreProvider.overrideWithValue(
          InMemoryKeyValueStore(<String, Object?>{
            SettingsController.storageKey:
                const AppSettings(firstRunCompleted: true).toJson(),
            FollowingStore.defaultKey: <Object?>[entryOf().toJson()],
          }),
        ),
        subsPortProvider.overrideWithValue(subs),
      ],
      child: MaterialApp(
        theme: buildDsanimaTheme(),
        home: Scaffold(
          body: Center(
            child: Consumer(
              builder: (BuildContext context, WidgetRef ref, Widget? _) {
                ref.watch(subscriptionsProvider); // 替身：主页那处常驻 watch
                return FollowButton(entry: entryOf());
              },
            ),
          ),
        ),
      ),
    );

    testWidgets('弹三选；「只取消追番」保留订阅，并明说它们还在跑', (WidgetTester tester) async {
      final _FakeSubsPort subs = _FakeSubsPort(<SubscriptionView>[subOf()]);
      await tester.pumpWidget(harness(subs));
      await tester.pumpAndSettle();
      expect(find.text('已追'), findsOneWidget);

      await tester.tap(find.text('已追'));
      await tester.pumpAndSettle();
      expect(find.text('取消追番「葬送的芙莉莲」？'), findsOneWidget,
          reason: '有订阅就必须问一句（旧实现静默留下孤儿订阅）');
      expect(find.textContaining('每 30 分钟在后台刷新'), findsOneWidget);

      await tester.tap(find.text('只取消追番'));
      await tester.pumpAndSettle();
      expect(subs.removed, isEmpty, reason: '选了"只取消追番"就不该动订阅');
      expect(find.textContaining('1 个订阅还在后台刷新'), findsOneWidget,
          reason: '要如实告诉用户它们还在跑');
      expect(find.text('追番'), findsOneWidget, reason: '追番标记已经取消');
    });

    testWidgets('「连订阅一起取消」会真的把订阅删掉', (WidgetTester tester) async {
      final _FakeSubsPort subs = _FakeSubsPort(<SubscriptionView>[subOf()]);
      await tester.pumpWidget(harness(subs));
      await tester.pumpAndSettle();

      await tester.tap(find.text('已追'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('连订阅一起取消'));
      await tester.pumpAndSettle();
      expect(subs.removed, <String>['sub-1']);
      expect(find.textContaining('并停掉 1 个字幕组订阅'), findsOneWidget);
      expect(find.text('追番'), findsOneWidget);
    });

    testWidgets('没有订阅的那一部：照旧**直接**取消，不弹框（不给日常动作添摩擦）', (
      WidgetTester tester,
    ) async {
      final _FakeSubsPort subs = _FakeSubsPort(const <SubscriptionView>[]);
      await tester.pumpWidget(harness(subs));
      await tester.pumpAndSettle();

      await tester.tap(find.text('已追'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('已从「正在追」移除'), findsOneWidget);
      expect(find.text('追番'), findsOneWidget);
    });
  });

  group('播放窗口「检查—创建」不许并发（UX #51：两路起播只许开一扇窗）', () {
    test('两路同时进来是**串行**的：后者等前者做完才开始', () async {
      final SerialGate gate = SerialGate();
      final List<String> order = <String>[];

      final Future<void> first = gate.run(() async {
        order.add('first:start');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        order.add('first:end');
      });
      final Future<void> second = gate.run(() async {
        order.add('second:start');
      });

      await Future.wait(<Future<void>>[first, second]);
      expect(
        order,
        <String>['first:start', 'first:end', 'second:start'],
        reason: '第二条必须等第一条（含它内部的 await）做完 —— 不然两路都会看到'
            '"还没有窗口"而各建一扇',
      );
    });

    test('前一次失败**不阻塞**后面的，而且错误只回给它自己的调用方', () async {
      final SerialGate gate = SerialGate();
      final List<String> order = <String>[];

      final Future<void> failing = gate.run(() async {
        order.add('bad');
        throw StateError('建窗失败');
      });
      final Future<void> after = gate.run(() async => order.add('after'));

      await expectLater(failing, throwsA(isA<StateError>()));
      await after; // 链没有断
      expect(order, <String>['bad', 'after']);
    });
  });

  group('外观选择器的键盘可达性（UX #40）', () {
    testWidgets('Tab 能落到格子上、回车能选中，读屏看到的是"按钮 + 已选中"', (
      WidgetTester tester,
    ) async {
      // 旧实现是裸 `GestureDetector`：Tab 整块跳过、没有焦点框、回车/空格没反应 ——
      // 鼠标能做的事键盘一样都做不了。
      // ⚠️ 必须在**测试体内**dispose：`addTearDown` 跑在框架的收尾检查之后，
      // 那时会被判定成"SemanticsHandle 没释放"。
      final SemanticsHandle handle = tester.ensureSemantics();
      final List<String> picked = <String>[];
      const String prefix = 'kbd';
      final DsAppearance first = DsAppearance.values.first;

      await tester.pumpWidget(MaterialApp(
        theme: buildDsanimaTheme(),
        home: Scaffold(
          body: NeoAppearancePicker(
            keyPrefix: prefix,
            value: first,
            onChanged: (DsAppearance a, Offset _) => picked.add(a.code),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final Finder cell = find.byKey(Key('$prefix-${first.code}'));
      expect(cell, findsOneWidget);
      expect(
        tester.getSemantics(cell).flagsCollection.isButton,
        isTrue,
        reason: '读屏要念成"按钮"，不是一段纯文字',
      );
      expect(
        tester.getSemantics(cell).flagsCollection.isSelected,
        Tristate.isTrue,
        reason: '当前选中的那一套要让读屏知道',
      );

      // 键盘走一遍：Tab 聚焦 → 回车激活。
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus,
        isNotNull,
        reason: 'Tab 必须能落在外观格上（旧实现整块被跳过）',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(picked, isNotEmpty, reason: '回车要能选中（旧实现完全没反应）');
      handle.dispose();
    });
  });

  group('全局未捕获异常：用户看得见（UX §2.1）', () {
    test('上报 → 广播一条 DsFailure；同一条 5 秒内不重复刷屏', () async {
      clearGlobalFailure();
      final List<DsFailure?> seen = <DsFailure?>[];
      void listener() => seen.add(globalFailure.value);
      globalFailure.addListener(listener);
      addTearDown(() {
        globalFailure.removeListener(listener);
        clearGlobalFailure();
      });

      reportGlobalFailure(StateError('漏包的 await'), StackTrace.empty);
      // 广播是**微任务**（避开"构建中触发通知"），所以要跨过一拍才看得到。
      await Future<void>.delayed(Duration.zero);
      expect(seen.where((DsFailure? f) => f != null), hasLength(1));
      expect(globalFailure.value!.message, contains('漏包的 await'));

      reportGlobalFailure(StateError('漏包的 await'), StackTrace.empty);
      await Future<void>.delayed(Duration.zero);
      expect(
        seen.where((DsFailure? f) => f != null),
        hasLength(1),
        reason: '同一条错误短期内重复上报只留一条（流/帧回调会每帧重抛）',
      );
    });
  });
}
