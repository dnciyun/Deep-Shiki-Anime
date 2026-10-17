/// 「正在追」页的两处性能修复（1.1.0 M1/T3）：
///
/// 1. **引擎种子流（2Hz）/ 队列流不再直接驱动整页重建** —— `followingTorrentsProvider` /
///    `followingJobsProvider` 只把「卡片真正会读的字段」做成签名，签名没变就不通知。
/// 2. **订阅条目缓存不会因为订阅流推了一次就整片失效** —— `subscriptionItemsProvider`
///    的依赖从「整个订阅列表」收窄到「这个订阅的抓取身份（源种类+地址+参数）」。
///    旧写法下订阅自动刷新一次（`lastError`/`lastRefreshAt` 变了 → 新 List）就会让
///    一页 N 个字幕组重抓 N 个 RSS。
///
/// 另外钉住 [InFlightCoalescer]：「同时发生的同一个 `latest()` 只抓一次」（`host_data.dart`
/// 的 `_latestOf` 就是它的调用方）。
library;

import 'dart:async';

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/state/following_snapshot.dart';
import 'package:dsanima/state/in_flight.dart';
import 'package:dsanima/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

EngineTorrentView _torrent({
  String name = '[ANi] 葬送的芙莉莲 - 01 [1080p]',
  bool finished = false,
  double progress = 0.42,
  int totalBytes = 1400000000,
  double uploadBps = 0,
  int peers = 0,
}) => EngineTorrentView(
  id: 1,
  name: name,
  state: TorrentState.live,
  progress: progress,
  finished: finished,
  totalBytes: totalBytes,
  uploadBps: uploadBps,
  peers: peers,
);

class _FakeSubsPort implements SubsPort {
  final StreamController<List<SubscriptionView>> controller =
      StreamController<List<SubscriptionView>>.broadcast();

  /// `items()` 被真调了几次（= 真的抓了几次 RSS）。
  final List<String> itemCalls = <String>[];

  @override
  Stream<List<SubscriptionView>> watch() => controller.stream;

  @override
  Future<List<SourceItemView>> items(SubscriptionView subscription) async {
    itemCalls.add(subscription.id);
    return const <SourceItemView>[];
  }

  @override
  Future<void> upsert(SubscriptionView subscription) async {}

  @override
  Future<void> remove(String id) async {}

  @override
  Future<SubsRefreshResult> refresh(String id) async => const SubsRefreshResult(fetched: 0);
}

SubscriptionView _sub({
  String id = 's1',
  String name = '喵萌奶茶屋',
  String feedUrl = 'https://mikanani.me/RSS/Bangumi?bangumiId=10',
  String? lastError,
  DateTime? lastRefreshAt,
}) => SubscriptionView(
  id: id,
  name: name,
  feedUrl: feedUrl,
  lastError: lastError,
  lastRefreshAt: lastRefreshAt,
);

void main() {
  group('正在追：引擎 2Hz 帧不再驱动页面重建（1.1.0 M1/T3）', () {
    late StreamController<List<EngineTorrentView>> engine;
    late ProviderContainer container;
    late int notifications;

    setUp(() {
      engine = StreamController<List<EngineTorrentView>>.broadcast();
      container = ProviderContainer(
        overrides: [engineTorrentsProvider.overrideWith((Ref _) => engine.stream)],
      );
      notifications = 0;
      container.listen<List<EngineTorrentView>>(
        followingTorrentsProvider,
        (_, _) => notifications++,
      );
      expect(container.read(followingTorrentsProvider), isEmpty);
    });

    tearDown(() async {
      container.dispose();
      await engine.close();
    });

    test('速度/对等每帧都变、进度百分比没变 → 一次都不通知', () async {
      engine.add(<EngineTorrentView>[_torrent()]);
      await pumpEventQueue();
      expect(notifications, 1, reason: '第一次有数据，页面该建一次');

      for (int frame = 0; frame < 10; frame++) {
        // 上传速度与对等数每帧都换（引擎真实快照就是这样），但卡片根本不显示这些。
        engine.add(<EngineTorrentView>[_torrent(uploadBps: 1024.0 * frame, peers: frame)]);
        await pumpEventQueue();
      }
      expect(
        notifications,
        1,
        reason: '卡片会读的字段（名字/状态/完成/进度%/字节/文件）一个都没变 → 不许通知',
      );
    });

    test('进度百分比变了 → 必须通知（卡片上写着「下载中 N%」）', () async {
      engine.add(<EngineTorrentView>[_torrent(progress: 0.42)]);
      await pumpEventQueue();
      expect(notifications, 1);

      engine.add(<EngineTorrentView>[_torrent(progress: 0.43)]);
      await pumpEventQueue();
      expect(notifications, 2, reason: '42% → 43% 用户看得见，必须更新');

      // 小数点后那点变化不进签名（卡片显示整数百分比）。
      engine.add(<EngineTorrentView>[_torrent(progress: 0.431)]);
      await pumpEventQueue();
      expect(notifications, 2, reason: '43.1% 与 43% 在界面上是同一个数字');
    });

    test('下载完成 / 换了种子名 → 通知', () async {
      engine.add(<EngineTorrentView>[_torrent(progress: 0.99)]);
      await pumpEventQueue();
      expect(notifications, 1);

      engine.add(<EngineTorrentView>[_torrent(progress: 1, finished: true)]);
      await pumpEventQueue();
      expect(notifications, 2);

      engine.add(<EngineTorrentView>[
        _torrent(progress: 1, finished: true),
        _torrent(name: '[Lilith] 葬送的芙莉莲 - 02 [1080p]', progress: 0.1),
      ]);
      await pumpEventQueue();
      expect(notifications, 3);
    });

    test('签名函数本身：顺序无关，且不含卡片不读的字段', () {
      final EngineTorrentView a = _torrent(name: 'A');
      final EngineTorrentView b =
          _torrent(name: 'B', progress: 0.1);
      expect(
        followingTorrentsSignature(<EngineTorrentView>[a, b]),
        followingTorrentsSignature(<EngineTorrentView>[b, a]),
        reason: '引擎返回顺序变了不该算"数据变了"',
      );
      expect(
        followingTorrentsSignature(<EngineTorrentView>[_torrent(uploadBps: 1, peers: 2)]),
        followingTorrentsSignature(<EngineTorrentView>[_torrent(uploadBps: 99, peers: 7)]),
        reason: '上传/对等不是卡片字段',
      );
    });
  });

  group('订阅条目：订阅流推一次不许让全部订阅重抓（1.1.0 M1/T3）', () {
    late _FakeSubsPort port;
    late ProviderContainer container;

    setUp(() {
      port = _FakeSubsPort();
      container = ProviderContainer(overrides: [subsPortProvider.overrideWithValue(port)]);
    });

    tearDown(() async {
      container.dispose();
      await port.controller.close();
    });

    test('只改 lastError / lastRefreshAt / 名字 → 0 次重抓；换地址才重抓', () async {
      // ⚠️ 顺序有讲究：先有人订阅 `subscriptionsProvider`（它 watch 的是 broadcast 流），
      // 之后再推事件 —— 反过来推的话事件会丢，列表永远停在 loading。
      container.listen<AsyncValue<List<SubscriptionView>>>(subscriptionsProvider, (_, _) {});
      port.controller.add(<SubscriptionView>[_sub()]);
      await pumpEventQueue();
      // 挂上监听（= 页面在看这一条）。第一次会抓一次。
      container.listen(subscriptionItemsProvider('s1'), (_, _) {});
      await pumpEventQueue();
      expect(port.itemCalls, <String>['s1']);

      // 订阅自动刷新：lastError / lastRefreshAt 变了 —— 抓取身份没变。
      port.controller.add(<SubscriptionView>[
        _sub(lastError: '上次 500', lastRefreshAt: DateTime(2026, 10, 17, 20, 0)),
      ]);
      await pumpEventQueue();
      expect(port.itemCalls, <String>['s1'], reason: '只是状态字段变了，不该重抓 RSS');

      // 改名同理。
      port.controller.add(<SubscriptionView>[_sub(name: '喵萌奶茶屋（改）')]);
      await pumpEventQueue();
      expect(port.itemCalls, <String>['s1'], reason: '改名不改变抓到什么');

      // 地址真的变了 → 必须重抓。
      port.controller.add(<SubscriptionView>[_sub(feedUrl: 'https://mikanani.me/RSS/Bangumi?bangumiId=99')]);
      await pumpEventQueue();
      expect(port.itemCalls, <String>['s1', 's1'], reason: '换了 feed 就必须重新抓');
    });
  });

  group('InFlightCoalescer：同时发生的同一个抓取只做一次', () {
    test('并发的同 key 调用共享一个 Future，只跑一次 start', () async {
      final InFlightCoalescer<String, int> coalescer = InFlightCoalescer<String, int>();
      int started = 0;
      Future<int> work() {
        started++;
        return Future<int>.delayed(const Duration(milliseconds: 10), () => 42);
      }

      final Future<int> a = coalescer.run('k', work);
      final Future<int> b = coalescer.run('k', work);
      expect(identical(a, b), isTrue, reason: '后来者拿到的是同一个 Future');
      expect(await Future.wait<int>(<Future<int>>[a, b]), <int>[42, 42]);
      expect(started, 1, reason: '两次并发只真发一次');
      expect(coalescer.inFlightCount, 0, reason: '结束后必须摘掉（不做 TTL 缓存）');
    });

    test('先后发生（不并发）就是两次真抓 —— 不许变成缓存', () async {
      final InFlightCoalescer<String, int> coalescer = InFlightCoalescer<String, int>();
      int started = 0;
      Future<int> work() async {
        started++;
        return started;
      }

      expect(await coalescer.run('k', work), 1);
      expect(await coalescer.run('k', work), 2);
      expect(started, 2, reason: '这不是缓存：用户点「刷新」必须真的去抓');
    });

    test('失败也要摘掉：下一次能重试（不会被永久钉在失败 Future 上）', () async {
      final InFlightCoalescer<String, int> coalescer = InFlightCoalescer<String, int>();
      int started = 0;
      Future<int> failing() async {
        started++;
        throw StateError('网络断了');
      }

      final Future<int> a = coalescer.run('k', failing);
      final Future<int> b = coalescer.run('k', failing);
      await expectLater(a, throwsStateError);
      await expectLater(b, throwsStateError);
      expect(started, 1, reason: '并发失败也只发一次');
      expect(coalescer.inFlightCount, 0, reason: '失败后必须能重试');

      final int ok = await coalescer.run('k', () async => 7);
      expect(ok, 7);
    });

    test('start 同步抛异常也要变成失败的 Future（不卡住 completer）', () async {
      final InFlightCoalescer<String, int> coalescer = InFlightCoalescer<String, int>();
      await expectLater(
        coalescer.run('k', () => throw StateError('参数不对')),
        throwsStateError,
      );
      expect(coalescer.inFlightCount, 0);
      expect(await coalescer.run('k', () async => 1), 1);
    });

    test('不同 key 不会互相合并', () async {
      final InFlightCoalescer<String, int> coalescer = InFlightCoalescer<String, int>();
      final List<String> started = <String>[];
      Future<int> work(String key) async {
        started.add(key);
        return key.length;
      }

      expect(
        await Future.wait<int>(<Future<int>>[
          coalescer.run('a', () => work('a')),
          coalescer.run('bb', () => work('bb')),
        ]),
        <int>[1, 2],
      );
      expect(started, <String>['a', 'bb']);
    });
  });
}
