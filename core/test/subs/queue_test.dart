/// 队列调度单测（spec §4.3）。
///
/// 用**内存假引擎**（实现本包自己定义的 [TorrentEnginePort]）+ 内存 KeyValueStore，
/// 不 import `core/lib/engine/`、不联网、不起进程。
library;

import 'dart:async';

import 'package:dsanima_core/sources/sources.dart';
import 'package:dsanima_core/subs/subs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// 与真实边车 504 时抛出的 `EngineException` **同形状**的替身。
///
/// 为什么用替身而不是 import `core/lib/engine/`：这个文件刻意只依赖本包的
/// `subs` + `sources`（见文件头），而 `_startFailureText` 判的正是这段文本形状，
/// 所以同形状的替身钉得更准（也顺便保证"以后改文案不会依赖引擎包内部"）。
class _FakeEngineError implements Exception {
  @override
  String toString() => 'EngineException[504]: metadata_timeout '
      '(POST http://127.0.0.1:45871/torrents)\n  响应体: {"detail":"metadata_timeout"}';
}

/// 假引擎端口。
class FakeEngine implements TorrentEnginePort {  int nextId = 1;

  final List<String> addCalls = <String>[];
  final List<({int id, bool deleteFiles})> removeCalls =
      <({int id, bool deleteFiles})>[];
  final List<int> pauseCalls = <int>[];
  final List<int> resumeCalls = <int>[];
  final List<EngineTorrentRef> torrents = <EngineTorrentRef>[];
  final StreamController<EngineProgressTick> ticks =
      StreamController<EngineProgressTick>.broadcast();

  List<EngineFileInfo> files = <EngineFileInfo>[
    const EngineFileInfo(index: 0, path: 'ep.mkv', length: 1000, isVideo: true),
    const EngineFileInfo(index: 1, path: 'ep.ass', length: 10),
  ];

  Object? addError;

  /// 前 [blockFirstAdds] 次 `addMagnet` 挂住，直到 [addsReleased] 被 complete。
  ///
  /// 真机语义：边车对磁力链是**在 HTTP 请求里同步等元数据**（最长
  /// `kDefaultMetadataRequestTimeout` = 130s），等不到就 504。用户第二十三轮报的
  /// 「连点下载，前面那几条显示引擎里没有它」就是这个窗口 —— 它证明的是
  /// 「一条 add 挂住不该挡住下一条启动」，见 `并发启动：一条等元数据不挡住下一条`。
  int blockFirstAdds = 0;
  final Completer<void> addsReleased = Completer<void>();

  /// 让 `remove` 抛错（模拟引擎 404 `no_such_torrent` / 边车没起）。
  Object? removeError;

  /// 让 `listTorrents` 抛错（模拟对账时边车不可用 / 请求超时）。
  Object? listError;
  List<int>? lastOnlyFiles;
  String? lastSubFolder;
  String? lastName;

  static String? infoHashOf(String magnet) =>
      RegExp(r'btih:([0-9a-fA-F]{40})').firstMatch(magnet)?.group(1)?.toLowerCase();

  @override
  Future<EngineAddedTorrent> addMagnet(
    String magnet, {
    String? name,
    List<int>? onlyFiles,
    bool startPaused = false,
    String? subFolder,
  }) async {
    addCalls.add(magnet);
    lastName = name;
    lastOnlyFiles = onlyFiles;
    lastSubFolder = subFolder;
    if (addCalls.length <= blockFirstAdds) await addsReleased.future;
    final error = addError;
    if (error != null) throw error;
    final torrent = EngineAddedTorrent(
      id: nextId++,
      infoHash: infoHashOf(magnet),
      name: name,
      files: files,
    );
    torrents.add(EngineTorrentRef(
      id: torrent.id,
      infoHash: torrent.infoHash,
      name: name,
    ));
    return torrent;
  }

  @override
  Future<List<EngineTorrentRef>> listTorrents() async {
    final Object? error = listError;
    if (error != null) throw error;
    return List<EngineTorrentRef>.of(torrents);
  }

  @override
  Future<void> pause(int id) async => pauseCalls.add(id);

  @override
  Future<void> resume(int id) async => resumeCalls.add(id);

  @override
  Future<void> remove(int id, {bool deleteFiles = false}) async {
    removeCalls.add((id: id, deleteFiles: deleteFiles));
    final Object? error = removeError;
    if (error != null) throw error;
    torrents.removeWhere((EngineTorrentRef t) => t.id == id);
  }

  @override
  Stream<EngineProgressTick> progress() => ticks.stream;

  @override
  Uri streamUrl(int id, int fileIndex) => Uri.parse(
      'http://127.0.0.1:45871/torrents/$id/files/$fileIndex/stream?token=abc');

  Future<void> dispose() => ticks.close();
}

/// 构造一个带确定性 id 的条目。
SourceItem ep(
  String n, {
  bool batch = false,
  String sourceId = 'nyaa',
}) {
  final hash = n.padLeft(40, '0');
  return SourceItem(
    id: 'item-$n',
    sourceId: sourceId,
    title: '[组] 某番 - $n [1080p]',
    magnet: 'magnet:?xt=urn:btih:$hash',
    infoHash: hash,
    sizeBytes: 300 * 1024 * 1024,
    seeders: 10,
    episodeHints: batch ? <String>[n, '99'] : <String>[n],
    extra: <String, dynamic>{'isBatch': batch, 'resolution': 1080},
  );
}

class Harness {
  Harness({
    BandwidthPolicy? policy,
    bool autoPump = false,
    FakeClock? clock,
  })  : clock = clock ?? FakeClock(DateTime.utc(2026, 10, 8, 12)) {
    var seq = 0;
    manager = QueueManager(
      engine: engine,
      store: store,
      policy: policy,
      clock: this.clock.call,
      idGenerator: () => 'job-${++seq}',
      autoPump: autoPump,
    );
  }

  final FakeEngine engine = FakeEngine();
  final InMemoryKeyValueStore store = InMemoryKeyValueStore();
  final FakeClock clock;
  late final QueueManager manager;

  List<QueueJob> get jobs => manager.jobs;

  QueueJob jobOf(String itemId) =>
      jobs.firstWhere((QueueJob j) => j.item.id == itemId);

  Future<void> tearDown() async {
    await manager.dispose();
    await engine.dispose();
  }
}

void main() {
  test('调度顺序：priority 小者先（用户 10 先于预取 100）', () async {
    final h = Harness();
    await h.manager.enqueue(ep('01'), subscriptionId: 's', priority: 100);
    await h.manager.enqueue(ep('02'), subscriptionId: 's', priority: 10);
    await h.manager.enqueue(ep('03'), subscriptionId: 's', priority: 100);

    await h.manager.pump();

    expect(h.engine.addCalls, hasLength(1)); // 并发 1
    expect(h.engine.lastName, '[组] 某番 - 02 [1080p]');
    expect(h.jobOf('item-02').state, JobState.downloading);
    expect(h.jobOf('item-02').priority, QueueManager.playbackPriority);
    expect(h.jobOf('item-01').state, JobState.queued);
    await h.tearDown();
  });

  test('同 priority 时按 createdAt 最旧优先', () async {
    final h = Harness();
    await h.manager.enqueue(ep('05'), subscriptionId: 's', priority: 10);
    h.clock.advance(const Duration(minutes: 1));
    await h.manager.enqueue(ep('06'), subscriptionId: 's', priority: 10);

    await h.manager.pump();

    expect(h.engine.lastName, contains('05'));
    await h.tearDown();
  });

  test('并发数：maxConcurrent=2 启动两个；>3 被夹到 3', () async {
    final h = Harness(policy: const BandwidthPolicy(maxConcurrent: 2));
    for (final n in <String>['01', '02', '03']) {
      await h.manager.enqueue(ep(n), subscriptionId: 's');
    }
    await h.manager.pump();
    expect(h.jobs.where((QueueJob j) => j.state == JobState.downloading),
        hasLength(2));
    expect(h.engine.addCalls, hasLength(2));

    final h3 = Harness(policy: const BandwidthPolicy(maxConcurrent: 5));
    expect(h3.manager.policy.effectiveMaxConcurrent, 3);
    for (final n in <String>['01', '02', '03', '04', '05']) {
      await h3.manager.enqueue(ep(n), subscriptionId: 's');
    }
    await h3.manager.pump();
    expect(h3.engine.addCalls, hasLength(3));
    await h.tearDown();
    await h3.tearDown();
  });

  test('并发启动：一条卡在等元数据，不挡住下一条交给引擎（第二十三轮）', () async {
    // 真机形态：连点下载 → 第 1 条磁力没有 peer，边车在 POST /torrents 里同步等元数据
    // （最长 130s）才回；旧实现 `pump()` 是 `await _start()` 串行，于是后面几条
    // 连"交给引擎"都没发生 —— 队列页只能把它们写成"引擎里已经没有这个任务"
    //（卡片只看 engineId 是否为空）。并发下载数本该决定**同时启动几条**。
    final h = Harness(policy: const BandwidthPolicy(maxConcurrent: 2));
    h.engine.blockFirstAdds = 2;
    await h.manager.enqueue(ep('01'), subscriptionId: 's');
    await h.manager.enqueue(ep('02'), subscriptionId: 's');

    final Future<void> pumping = h.manager.pump();
    await pumpEventQueue();

    // 两条都挂在那儿等元数据，但**两条都已经交给引擎**（addCalls 两条）。
    expect(h.engine.addCalls, hasLength(2), reason: '第 2 条不该等第 1 条的元数据');
    expect(h.jobs.where((QueueJob j) => j.state == JobState.downloading), hasLength(2));
    // 引擎还没回话 ⇒ 两条都没有 engineId。这正是要分清"等元数据"与"引擎里没有它"的窗口。
    expect(h.jobOf('item-01').engineId, isNull);
    expect(h.jobOf('item-02').engineId, isNull);

    h.engine.addsReleased.complete();
    await pumping;
    expect(h.jobOf('item-01').engineId, isNotNull);
    expect(h.jobOf('item-02').engineId, isNotNull);
    await h.tearDown();
  });

  test('pump 可重入：已在 pump 中再次调用不会重复启动', () async {
    final h = Harness();
    for (final n in <String>['01', '02']) {
      await h.manager.enqueue(ep(n), subscriptionId: 's');
    }
    await Future.wait(<Future<void>>[h.manager.pump(), h.manager.pump()]);
    expect(h.engine.addCalls, hasLength(1));
    await h.tearDown();
  });

  group('点播路径 playNow', () {
    test('立即 addMagnet + 立刻给出 streamUrl（不等下完）', () async {
      final h = Harness();
      final ticket = await h.manager.playNow(
        ep('01'),
        subscriptionId: 's',
        onlyFiles: <int>[0, 1],
        subFolder: 'Anime/某番',
      );

      expect(h.engine.addCalls, hasLength(1));
      expect(h.engine.lastName, '[组] 某番 - 01 [1080p]');
      expect(h.engine.lastOnlyFiles, <int>[0, 1]);
      expect(h.engine.lastSubFolder, 'Anime/某番');
      expect(ticket.job.state, JobState.downloading);
      expect(ticket.job.engineId, 1);
      expect(ticket.job.fileIndex, 0); // 体积最大的视频
      expect(ticket.job.priority, QueueManager.playbackPriority);
      expect(ticket.job.saveSubFolder, 'Anime/某番');
      expect(ticket.streamUrl.toString(),
          'http://127.0.0.1:45871/torrents/1/files/0/stream?token=abc');
      expect(h.manager.playingItemId, 'item-01');
      await h.tearDown();
    });

    test('autoPump 打开（真机配置）时点播也只会 addMagnet 一次', () async {
      // `enqueue()` 内部会 `unawaited(pump())` 自动调度一次，而 `playNow()` 拿到同一条
      // 任务后还会再 `_start` 一次 —— 两条路都到 `_start`。修复前同一个种子会被
      // `addMagnet` **两遍**（多一次 HTTP；有些引擎还会因此重置任务状态）。
      // 注意测试 Harness 默认 autoPump=false，所以这个双开 bug 在别的用例里看不见。
      final h = Harness(autoPump: true);
      final ticket = await h.manager.playNow(ep('01'), subscriptionId: 's');
      await Future<void>.delayed(Duration.zero); // 给自动 pump 一拍
      expect(h.engine.addCalls, hasLength(1), reason: '一次点播只能加一次种子');
      expect(ticket.job.state, JobState.downloading);
      expect(ticket.job.fileIndex, 0);
      await h.tearDown();
    });

    test('多视频时取体积最大的那个作为 playable file', () async {      final h = Harness();
      h.engine.files = <EngineFileInfo>[
        const EngineFileInfo(index: 0, path: 'a/sp1.mkv', length: 100, isVideo: true),
        const EngineFileInfo(index: 1, path: 'a/sp2.mkv', length: 900, isVideo: true),
        const EngineFileInfo(index: 2, path: 'a/ep.ass', length: 5),
      ];
      final ticket = await h.manager.playNow(ep('01'), subscriptionId: 's');
      expect(ticket.job.fileIndex, 1);
      await h.tearDown();
    });

    test('既没有磁力也没有 infoHash → QueueException（不静默跳过）', () async {
      final h = Harness();
      const broken = SourceItem(id: 'x', sourceId: 'nyaa', title: '没有下载源');
      await expectLater(
        h.manager.playNow(broken, subscriptionId: 's'),
        throwsA(isA<QueueException>()),
      );
      expect(h.engine.addCalls, isEmpty);
      await h.tearDown();
    });

    test('种子内没有视频文件 → QueueException 且任务标记 failed', () async {
      final h = Harness();
      h.engine.files = <EngineFileInfo>[
        const EngineFileInfo(index: 0, path: 'readme.txt', length: 10),
      ];
      await expectLater(
        h.manager.playNow(ep('01'), subscriptionId: 's'),
        throwsA(isA<QueueException>()),
      );
      final job = h.jobOf('item-01');
      expect(job.state, JobState.failed);
      expect(job.error, contains('没有可识别的视频文件'));
      await h.tearDown();
    });

    test('引擎 addMagnet 失败 → task 标 failed 且带原因', () async {
      final h = Harness();
      h.engine.addError = StateError('metadata_timeout');
      await expectLater(
        h.manager.playNow(ep('01'), subscriptionId: 's'),
        throwsA(isA<QueueException>()),
      );
      final job = h.jobOf('item-01');
      expect(job.state, JobState.failed);
      expect(job.error, contains('metadata_timeout'));
      await h.tearDown();
    });

    // ── 第四十二轮 UX #7：失败的那一行是"死路"上唯一的信息，必须是给人看的 ──
    test('加种失败的文案：去掉技术类型名与本机地址，说清"为什么 + 怎么办"', () async {
      final h = Harness();
      // 真实边车 504 时抛的 `EngineException` 的 toString 就是这个形状
      // （`EngineException[504]: metadata_timeout (POST http://…/torrents)`，
      // 后面还跟着「响应体/原因」多行）。这里用一个同形状的替身来钉这条规则。
      h.engine.addError = _FakeEngineError();
      await expectLater(
        h.manager.playNow(ep('01'), subscriptionId: 's'),
        throwsA(isA<QueueException>()),
      );
      final job = h.jobOf('item-01');
      expect(job.state, JobState.failed);
      expect(job.error, isNot(contains('EngineException')), reason: '类型名不该上屏');
      expect(job.error, isNot(contains('127.0.0.1')), reason: '本机地址不该上屏');
      expect(job.error, isNot(contains('\n')), reason: '多行技术倾倒不该上屏');
      expect(job.error, contains('做种'), reason: '要说清原因（没人做种）');
      expect(job.error, contains('换一条种子'), reason: '要给出下一步');
      await h.tearDown();
    });

    test('认不出的异常也只留一行、有长度上限（不倒库内部结构）', () async {
      final h = Harness();
      h.engine.addError = StateError('boom ${'x' * 400}\n第二行细节');
      await expectLater(
        h.manager.playNow(ep('01'), subscriptionId: 's'),
        throwsA(isA<QueueException>()),
      );
      final job = h.jobOf('item-01');
      expect(job.error, startsWith('加种失败：'));
      expect(job.error, contains('boom'));
      expect(job.error, isNot(contains('第二行细节')));
      expect(job.error!.length, lessThan(200), reason: '一行、有上限，才不至于把行撑爆');
      await h.tearDown();
    });
  });

  group('完成判定：completedFiles / finished / 字节数下满，三条任一成立', () {
    test('finished=true（引擎自己说下完了）→ 算下完', () async {
      // 用户 2026-10-12 第 9 轮「下载100%了还是不完成」：进度是**事件流**，
      // completedFiles 那条事件丢了就再也不来；引擎的 finished 是同一件事的另一个
      // 独立证据，不靠事件送达。旧实现只认 completedFiles，于是任务永远停在下载中。
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      await h.manager.onProgress(const EngineProgressTick(
        id: 1,
        finished: true,
        completedFiles: <int>{},
      ));
      expect(h.jobOf('item-01').state, JobState.completed);
      await h.tearDown();
    });

    test('字节数下满（progressBytes >= totalBytes）→ 算下完', () async {
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      await h.manager.onProgress(const EngineProgressTick(
        id: 1,
        progressBytes: 1000,
        totalBytes: 1000,
        completedFiles: <int>{},
      ));
      expect(h.jobOf('item-01').state, JobState.completed);
      await h.tearDown();
    });

    test('没下满（字节差一截）→ 仍然是下载中', () async {
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      await h.manager.onProgress(const EngineProgressTick(
        id: 1,
        progressBytes: 999,
        totalBytes: 1000,
        completedFiles: <int>{},
      ));
      expect(h.jobOf('item-01').state, JobState.downloading);
      await h.tearDown();
    });

    test('totalBytes=0 / 缺字节数 → 不靠字节判下完', () async {
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      await h.manager.onProgress(const EngineProgressTick(
        id: 1,
        progressBytes: 0,
        totalBytes: 0,
        completedFiles: <int>{},
      ));
      await h.manager.onProgress(const EngineProgressTick(
        id: 1,
        progressBytes: 1000,
        completedFiles: <int>{},
      ));
      expect(h.jobOf('item-01').state, JobState.downloading);
      await h.tearDown();
    });

    test('completedFiles 含本任务 fileIndex → completed', () async {
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      await h.manager.onProgress(const EngineProgressTick(
        id: 1,
        completedFiles: <int>{0},
      ));
      expect(h.jobOf('item-01').state, JobState.completed);
      await h.tearDown();
    });

    test('别的事件（其他 id / 其他 fileIndex）不影响本任务', () async {
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      await h.manager.onProgress(const EngineProgressTick(
        id: 999,
        completedFiles: <int>{0},
      ));
      await h.manager.onProgress(const EngineProgressTick(
        id: 1,
        completedFiles: <int>{1},
      ));
      expect(h.jobOf('item-01').state, JobState.downloading);
      await h.tearDown();
    });

    test('start() 订阅引擎进度流后自动完成', () async {
      final h = Harness();
      h.manager.start();
      await h.manager.playNow(ep('01'), subscriptionId: 's');

      final completed = h.manager.changes.firstWhere((List<QueueJob> jobs) =>
          jobs.any((QueueJob j) => j.state == JobState.completed));
      h.engine.ticks.add(const EngineProgressTick(id: 1, completedFiles: <int>{0}));
      final snapshot = await completed;
      expect(snapshot.first.state, JobState.completed);
      await h.tearDown();
    });

    test('对账：引擎说下完了 → 把漏掉事件的那条补成已完成', () async {
      // 这条覆盖的就是真机那个场景：队列从一开始就没收到任何进度事件
      // （订阅建在边车启动之前，见 app 侧 resilientEngineStream 的注释），
      // 引擎侧其实早就 finished 了。对账是"按状态说话"，能兜住。
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      expect(h.manager.jobs.single.state, JobState.downloading);

      final int engineId = h.manager.jobs.single.engineId!;
      h.engine.torrents
        ..clear()
        ..add(EngineTorrentRef(id: engineId, finished: true, progress: 1));
      await h.manager.reconcileWithEngine();

      expect(h.jobOf('item-01').state, JobState.completed);
      await h.tearDown();
    });

    test('对账：引擎只报了 100% 进度（finished 还没置位）也算下完', () async {
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      final int engineId = h.manager.jobs.single.engineId!;
      h.engine.torrents
        ..clear()
        ..add(EngineTorrentRef(id: engineId, finished: false, progress: 1.0));
      await h.manager.reconcileWithEngine();
      expect(h.jobOf('item-01').state, JobState.completed);
      await h.tearDown();
    });

    test('对账：引擎才下到一半 → 不动', () async {
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      final int engineId = h.manager.jobs.single.engineId!;
      h.engine.torrents
        ..clear()
        ..add(EngineTorrentRef(id: engineId, finished: false, progress: 0.42));
      await h.manager.reconcileWithEngine();
      expect(h.jobOf('item-01').state, JobState.downloading);
      await h.tearDown();
    });

    test('⚠️ 对账时引擎不可用 → 不许把异常抛给宿主，但必须记下原因', () async {
      // 宿主在 `EngineBootstrapController.start()` 的成功分支里 await 这次对账，
      // 而它只吞 `PortUnavailableException` —— 别的异常会从 `main.dart` 那条
      // `unawaited(start())` 冒成**启动期的未处理异常**：队列既不显示为什么没对上账，
      // 用户也看不到任何提示（静默失败）。
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      h.engine.listError = Exception('引擎请求超时');

      await expectLater(h.manager.reconcileWithEngine(), completes);
      expect(h.manager.jobs.single.state, JobState.downloading, reason: '对不上账时状态不动');
      expect(
        h.manager.loadWarnings.any((String w) => w.contains('对账')),
        isTrue,
        reason: '不能静默：失败原因要能被队列页展示出来',
      );
      await h.tearDown();
    });
  });

  group('预热后几集（第三十八轮：默认关、档位 1..3）', () {
    test('本集下完后自动以 priority 100 入队「下一集」', () async {
      final h = Harness(policy: const BandwidthPolicy(preheatAhead: 1));
      h.manager.addCandidates('s', <SourceItem>[ep('01'), ep('02'), ep('03')]);
      await h.manager.playNow(ep('01'), subscriptionId: 's');

      await h.manager.onProgress(const EngineProgressTick(
        id: 1,
        completedFiles: <int>{0},
      ));

      final next = h.jobOf('item-02');
      expect(next.priority, QueueManager.prefetchPriority);
      expect(next.isPrefetch, isTrue);
      expect(next.state, JobState.queued); // autoPump=false，等调度器空闲时启动
      expect(h.jobs.any((QueueJob j) => j.item.id == 'item-03'), isFalse);

      await h.manager.pump();
      expect(next.state, JobState.downloading);
      await h.tearDown();
    });

    test('档位 2：本集下完一次补两条，而不是一条', () async {
      final h = Harness(policy: const BandwidthPolicy(preheatAhead: 2));
      h.manager.addCandidates(
          's', <SourceItem>[ep('01'), ep('02'), ep('03'), ep('04')]);
      await h.manager.playNow(ep('01'), subscriptionId: 's');

      await h.manager.onProgress(const EngineProgressTick(
        id: 1,
        completedFiles: <int>{0},
      ));

      expect(h.jobOf('item-02').isPrefetch, isTrue);
      expect(h.jobOf('item-03').isPrefetch, isTrue);
      expect(h.jobs.any((QueueJob j) => j.item.id == 'item-04'), isFalse,
          reason: '档位是 2：第三条不预热');
      await h.tearDown();
    });

    test('起播时就把后几集预热（playNow 的 preheat 清单）', () async {
      final h = Harness(policy: const BandwidthPolicy(preheatAhead: 2));
      // 搜索页那种场景：没有订阅 id、没有 `addCandidates`，只有手上的这一批。
      await h.manager.playNow(
        ep('01'),
        preheat: <SourceItem>[ep('01'), ep('02'), ep('03'), ep('04')],
      );

      expect(h.jobOf('item-02').isPrefetch, isTrue);
      expect(h.jobOf('item-03').isPrefetch, isTrue);
      expect(h.jobs.any((QueueJob j) => j.item.id == 'item-04'), isFalse);
      await h.tearDown();
    });

    test('默认档位 0：起播不预热任何后集（本轮要求的默认关闭）', () async {
      final h = Harness(); // 默认 preheatAhead = 0
      await h.manager.playNow(
        ep('01'),
        preheat: <SourceItem>[ep('01'), ep('02'), ep('03')],
      );

      expect(h.manager.jobs, hasLength(1), reason: '只有正在播的那一集');
      expect(h.manager.jobs.single.item.id, 'item-01');
      await h.tearDown();
    });

    test('并发上限管用户任务，预热任务照旧启动（否则"预热"永远轮不上）', () async {
      final h = Harness(
        policy: const BandwidthPolicy(preheatAhead: 2, maxConcurrent: 1),
      );
      await h.manager.playNow(
        ep('01'),
        preheat: <SourceItem>[ep('01'), ep('02'), ep('03')],
      );
      await h.manager.pump();

      expect(h.jobOf('item-01').state, JobState.downloading);
      expect(h.jobOf('item-02').state, JobState.downloading,
          reason: '预热不受"并发下载数"约束 —— 那一集正在下，等它等于永远不预热');
      expect(h.jobOf('item-03').state, JobState.downloading);
      await h.tearDown();
    });

    test('挑最近的一集，跳过合集与已在队列里的集', () async {
      final h = Harness(policy: const BandwidthPolicy(preheatAhead: 1));
      h.manager.addCandidates(
          's', <SourceItem>[ep('01'), ep('02', batch: true), ep('03'), ep('04')]);
      await h.manager.enqueue(ep('03'), subscriptionId: 's');
      await h.manager.playNow(ep('01'), subscriptionId: 's');

      await h.manager.onProgress(const EngineProgressTick(
        id: 1,
        completedFiles: <int>{0},
      ));

      expect(h.jobOf('item-04').isPrefetch, isTrue);
      expect(h.jobs.any((QueueJob j) => j.item.id == 'item-02'), isFalse);
      await h.tearDown();
    });

    test('addCandidates 带规则时只保留命中规则的条目', () async {
      final h = Harness(policy: const BandwidthPolicy(preheatAhead: 1));
      final rule = SubsRule(id: 'r', name: 'r', includeRegex: '某番');
      h.manager.addCandidates(
        's',
        <SourceItem>[
          ep('01'),
          SourceItem(
            id: 'item-other',
            sourceId: 'nyaa',
            title: '[组] 别的番 - 02 [1080p]',
            magnet: 'magnet:?xt=urn:btih:${'2'.padLeft(40, '0')}',
            episodeHints: const <String>['02'],
          ),
        ],
        rule: rule,
      );
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      await h.manager.onProgress(
          const EngineProgressTick(id: 1, completedFiles: <int>{0}));

      expect(h.jobs.any((QueueJob j) => j.item.id == 'item-other'), isFalse);
      await h.tearDown();
    });

    test('默认档位 0：不下完就预取，且队列里其他集保持 queued', () async {
      final h = Harness();
      h.manager.addCandidates('s', <SourceItem>[ep('01'), ep('02')]);
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      await h.manager.onProgress(
          const EngineProgressTick(id: 1, completedFiles: <int>{0}));

      // 没有自动入队
      expect(h.jobs.any((QueueJob j) => j.item.id == 'item-02'), isFalse);

      // 即使队列里已经有预热任务，也不会被启动
      final manual = (await h.manager.enqueue(ep('02'),
          subscriptionId: 's', priority: QueueManager.prefetchPriority))!;
      await h.manager.pump();
      expect(manual.state, JobState.queued);

      // 用户手点的任务（priority 10）仍然可以启动
      await h.manager.removeJob(h.jobOf('item-01').id);
      h.engine.files = <EngineFileInfo>[
        const EngineFileInfo(index: 0, path: 'ep2.mkv', length: 1000, isVideo: true),
      ];
      final user =
          (await h.manager.enqueue(ep('03'), subscriptionId: 's'))!;
      await h.manager.pump();
      expect(user.state, JobState.downloading);
      await h.tearDown();
    });

    test('preheat() 直接调用时也受档位约束', () async {
      final off = Harness();
      off.manager.addCandidates('s', <SourceItem>[ep('01'), ep('02')]);
      expect(
        await off.manager.preheat('s', afterItemId: 'item-01'),
        isEmpty,
        reason: '档位 0（默认）必须拦住预热',
      );
      await off.tearDown();

      final on = Harness(policy: const BandwidthPolicy(preheatAhead: 1));
      on.manager.addCandidates('s', <SourceItem>[ep('01'), ep('02')]);
      final List<QueueJob> warmed =
          await on.manager.preheat('s', afterItemId: 'item-01');
      expect(warmed.map((QueueJob j) => j.item.id), <String>['item-02']);
      await on.tearDown();
    });

    test('excludePatterns 命中的番剧一律不预取', () async {
      final h = Harness(
        policy: const BandwidthPolicy(excludePatterns: <String>['某番']),
      );
      h.manager.addCandidates('s', <SourceItem>[ep('01'), ep('02')]);
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      await h.manager.onProgress(
          const EngineProgressTick(id: 1, completedFiles: <int>{0}));

      expect(h.jobs.any((QueueJob j) => j.item.id == 'item-02'), isFalse);
      // 已经排队的预取任务也不会被启动（策略第二道防线）
      final queued = (await h.manager.enqueue(ep('02'),
          subscriptionId: 's', priority: QueueManager.prefetchPriority))!;
      await h.manager.pump();
      expect(queued.state, JobState.queued);
      await h.tearDown();
    });

    test('没有候选 / 没有当前集 / 集数不可比时不预热', () async {
      final h = Harness(policy: const BandwidthPolicy(preheatAhead: 1));
      expect(await h.manager.preheat('unknown', afterItemId: 'item-01'),
          isEmpty);

      h.manager.addCandidates('s', <SourceItem>[ep('01')]);
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      expect(await h.manager.preheat('s', afterItemId: 'item-01'), isEmpty);

      final batchOnly = SourceItem(
        id: 'item-batch',
        sourceId: 'nyaa',
        title: '[组] 某番 合集',
        magnet: 'magnet:?xt=urn:btih:${'9'.padLeft(40, '0')}',
        episodeHints: const <String>[],
      );
      h.manager.addCandidates('s2', <SourceItem>[batchOnly]);
      expect(await h.manager.preheat('s2', afterItemId: 'item-batch'),
          isEmpty);
      await h.tearDown();
    });
  });

  group('省流量策略', () {
    test('stopSeedingAfterPlayback：播放结束对该 torrent pause', () async {
      final h = Harness(
          policy: const BandwidthPolicy(stopSeedingAfterPlayback: true));
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      await h.manager.onPlaybackFinished(1);
      expect(h.engine.pauseCalls, <int>[1]);
      expect(h.engine.removeCalls, isEmpty);
      await h.tearDown();
    });

    test('deleteAfterPlayed：播放结束删除任务与文件', () async {
      final h = Harness(policy: const BandwidthPolicy(deleteAfterPlayed: true));
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      await h.manager.onPlaybackFinished(1);
      expect(h.engine.removeCalls.single.deleteFiles, isTrue);
      expect(h.jobOf('item-01').state, JobState.completed);
      await h.tearDown();
    });

    test('默认策略：不停做种也不删文件', () async {
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      await h.manager.onPlaybackFinished(1);
      expect(h.engine.pauseCalls, isEmpty);
      expect(h.engine.removeCalls, isEmpty);
      await h.tearDown();
    });

    test('onPlaybackFinished 会切到下一集（playingItemId 更新）', () async {
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      await h.manager.onPlaybackFinished(1, next: ep('02'));
      expect(h.manager.playingItemId, 'item-02');
      await h.tearDown();
    });

    // ---------------------------------------------------------------- 播放结束收尾
    //
    // 用户 2026-10-11 选定「留记录但收尾」：宿主以前没有**任何**地方在播放窗口收起时
    // 通知队列，点播建的那条任务就永远停在 downloading（「为什么队列里总是有东西」）。
    test('settleAfterPlayback：没下完 → paused 且引擎侧停下（留记录，能删）', () async {
      final h = Harness(policy: const BandwidthPolicy(stopSeedingAfterPlayback: true));
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      final job = h.jobOf('item-01');
      await h.manager.settleAfterPlayback(1);

      expect(job.state, JobState.paused); // 记录还在（用户要能看见、能删）
      expect(job.error, contains('播放已结束'));
      expect(h.engine.pauseCalls, <int>[1]); // 引擎侧不再后台跑
      expect(h.manager.jobs, hasLength(1));
      await h.tearDown();
    });

    test('settleAfterPlayback：已下完 → completed（不删记录、不删文件）', () async {
      final h = Harness(policy: const BandwidthPolicy(stopSeedingAfterPlayback: true));
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      // 走真实判据：先订阅进度流，再报「本集的 fileIndex 下完了」。
      h.manager.start();
      h.engine.ticks.add(const EngineProgressTick(
          id: 1, completedFiles: <int>{0}, finished: true));
      await Future<void>.delayed(Duration.zero);
      final job = h.jobOf('item-01');
      expect(job.state, JobState.completed);

      await h.manager.settleAfterPlayback(1);
      expect(job.state, JobState.completed);
      expect(job.error, isNull);
      expect(h.engine.removeCalls, isEmpty);
      await h.tearDown();
    });

    test('settleAfterPlayback：默认策略且已下完 → 继续做种（不 pause）', () async {
      final h = Harness(); // 默认 stopSeedingAfterPlayback=false
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      final job = h.jobOf('item-01');
      job.state = JobState.completed;
      await h.manager.settleAfterPlayback(1);
      expect(job.state, JobState.completed);
      expect(h.engine.pauseCalls, isEmpty);
      await h.tearDown();
    });

    test('settleAfterPlayback：deleteAfterPlayed → 删文件并标 completed', () async {
      final h = Harness(policy: const BandwidthPolicy(deleteAfterPlayed: true));
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      await h.manager.settleAfterPlayback(1);
      expect(h.engine.removeCalls.single.deleteFiles, isTrue);
      expect(h.jobOf('item-01').state, JobState.completed);
      await h.tearDown();
    });

    test('settleAfterPlayback：队列里没有这条任务时也只收拾引擎', () async {
      final h = Harness(policy: const BandwidthPolicy(stopSeedingAfterPlayback: true));
      await h.manager.settleAfterPlayback(9);
      expect(h.manager.jobs, isEmpty);
      expect(h.engine.pauseCalls, <int>[9]);
      await h.tearDown();
    });

    test('maxConcurrent 的边界：0/负数夹到 1', () {
      expect(const BandwidthPolicy(maxConcurrent: 0).effectiveMaxConcurrent, 1);
      expect(const BandwidthPolicy(maxConcurrent: -3).effectiveMaxConcurrent, 1);
      expect(const BandwidthPolicy(maxConcurrent: 3).effectiveMaxConcurrent, 3);
    });

    test('preheatAhead 的边界：0/负数 = 关，上限 3', () {
      expect(const BandwidthPolicy().preheatAhead, 0, reason: '默认关闭');
      expect(const BandwidthPolicy(preheatAhead: -1).effectivePreheatAhead, 0);
      expect(const BandwidthPolicy(preheatAhead: 2).effectivePreheatAhead, 2);
      expect(const BandwidthPolicy(preheatAhead: 9).effectivePreheatAhead, 3);
    });

    test('BandwidthPolicy JSON 往返与 excludePatterns 匹配', () {
      const policy = BandwidthPolicy(
        preheatAhead: 2,
        stopSeedingAfterPlayback: true,
        stopSeedingAfterDownload: true,
        deleteAfterPlayed: true,
        maxConcurrent: 2,
        excludePatterns: <String>['省流量番', 'Another'],
      );
      final restored = BandwidthPolicy.fromJson(policy.toJson());
      expect(restored.preheatAhead, 2);
      expect(restored.stopSeedingAfterPlayback, isTrue);
      expect(restored.stopSeedingAfterDownload, isTrue);
      expect(restored.deleteAfterPlayed, isTrue);
      expect(restored.maxConcurrent, 2);
      expect(restored.excludePatterns, <String>['省流量番', 'Another']);
      expect(restored.isExcluded('[组] 省流量番 - 01'), isTrue);
      expect(restored.isExcluded('[组] another show - 01'), isTrue);
      expect(restored.isExcluded('[组] 正常番 - 01'), isFalse);
      expect(restored.isExcluded(null), isFalse);
    });

    // ── 第四十二轮 UX #25：界面写「排除正则」，就必须真的按正则匹配 ──
    test('排除规则是**正则**：`合集|总集篇` 这种"或"要真的生效', () {
      const BandwidthPolicy policy = BandwidthPolicy(
        excludePatterns: <String>['合集|总集篇', 'HEVC.*10bit'],
      );
      // 旧实现是子串匹配：`合集|总集篇` 这一整串永远不是任何标题的子串 ⇒ 设了没反应。
      expect(policy.isExcluded('[组] 某番 合集 01'), isTrue,
          reason: '`|` 是"或"，左边命中就该排除');
      expect(policy.isExcluded('[组] 某番 总集篇'), isTrue, reason: '右边也要命中');
      expect(policy.isExcluded('[组] 某番 - 01 [HEVC 8bit]'), isFalse);
      expect(policy.isExcluded('[组] 某番 - 01 [HEVC 10bit]'), isTrue,
          reason: '`.*` 要当"任意字符"，不是字面量');
      expect(policy.isExcluded('[组] 某番 - 01'), isFalse);
    });

    test('大小写不敏感照旧；编不出来的老模式退回子串匹配（不装作生效）', () {
      const BandwidthPolicy policy = BandwidthPolicy(
        excludePatterns: <String>['Another', 'C++'],
      );
      expect(policy.isExcluded('[组] another show - 01'), isTrue,
          reason: '正则大小写不敏感');
      // `C++` 不是合法正则（`+` 后面不能再跟 `+`）→ 退回子串匹配，仍然能用。
      expect(policy.isExcluded('[组] 学 C++ 的人 - 01'), isTrue);
      expect(policy.isExcluded('[组] 学 C 的人 - 01'), isFalse);
    });

    test('旧键 prefetchNext 不再被读取（否则"默认关闭"会被老配置打开）', () {
      // 第三十八轮：旧默认是 true（下完本集自动下下一集），用户要求默认关掉。
      final legacy = BandwidthPolicy.fromJson(<String, dynamic>{
        'prefetchNext': true,
        'maxConcurrent': 2,
      });
      expect(legacy.preheatAhead, 0);
      expect(legacy.maxConcurrent, 2);
    });
  });

  // ── 不做种（用户 2026-10-12 第十二轮）────────────────────────────────────────
  //
  // 用户原话：「修复下载完后，自动上传做种问题，设置关着的做种」。
  // 根因不在队列、也不在设置页：设置里那个「开启做种」开关关掉时只把边车的
  // `--seed-ratio` 传成 **0**，而边车的语义是「`>0` 才在达到比例后暂停，
  // **0 = 不做任何做种干预**」（`engine/src/state.rs` 的 `maybe_stop_seeding`）
  // ⇒ 关掉开关反而等于"永远做种，宿主也不管"。
  // 现在开关接到这条策略上：下完的那一刻 `pause()`（暂停的 torrent 不再上传，
  // 已下载区间照旧可读）。
  group('不做种（下完就停上传）', () {
    test('策略开：整个种子下完的那一刻 pause 该 torrent', () async {
      final h = Harness(policy: const BandwidthPolicy(stopSeedingAfterDownload: true));
      await h.manager.playNow(ep('01'), subscriptionId: 's');

      await h.manager.onProgress(
          const EngineProgressTick(id: 1, finished: true));

      expect(h.engine.pauseCalls, <int>[1]);
      expect(h.jobOf('item-01').state, JobState.completed);
      await h.tearDown();
    });

    test('字节数下满（引擎没发 finished）同样算下完 → 也停', () async {
      final h = Harness(policy: const BandwidthPolicy(stopSeedingAfterDownload: true));
      await h.manager.playNow(ep('01'), subscriptionId: 's');

      await h.manager.onProgress(const EngineProgressTick(
          id: 1, progressBytes: 100, totalBytes: 100));

      expect(h.engine.pauseCalls, <int>[1]);
      await h.tearDown();
    });

    test('策略关（用户开了做种）：下完不 pause，交给引擎的做种比规则', () async {
      final h = Harness(); // 默认 stopSeedingAfterDownload=false
      await h.manager.playNow(ep('01'), subscriptionId: 's');

      await h.manager.onProgress(
          const EngineProgressTick(id: 1, finished: true));

      expect(h.engine.pauseCalls, isEmpty);
      expect(h.jobOf('item-01').state, JobState.completed);
      await h.tearDown();
    });

    test('已经暂停过的 tick 不再打扰引擎（幂等靠状态，不靠记账）', () async {
      final h = Harness(policy: const BandwidthPolicy(stopSeedingAfterDownload: true));

      await h.manager.onProgress(const EngineProgressTick(
          id: 1, finished: true, paused: true));

      expect(h.engine.pauseCalls, isEmpty, reason: '引擎说它已经停了，就不该再发一次 pause');
      await h.tearDown();
    });

    test('只下完一集（整个种子还没完）不停：停了还在下的那几集也会跟着停', () async {
      final h = Harness(policy: const BandwidthPolicy(stopSeedingAfterDownload: true));
      await h.manager.playNow(ep('01'), subscriptionId: 's');

      await h.manager.onProgress(
          const EngineProgressTick(id: 1, completedFiles: <int>{0}));

      expect(h.jobOf('item-01').state, JobState.completed, reason: '按集的判据照旧生效');
      expect(h.engine.pauseCalls, isEmpty, reason: '整个种子没下完就不该停上传');
      await h.tearDown();
    });

    test('引擎里没有队列记录的种子也停（设置是对整台机器生效的）', () async {
      final h = Harness(policy: const BandwidthPolicy(stopSeedingAfterDownload: true));

      await h.manager.onProgress(
          const EngineProgressTick(id: 77, finished: true));

      expect(h.engine.pauseCalls, <int>[77]);
      await h.tearDown();
    });

    test('对账：引擎里已下完且还在跑的 torrent 一律 pause（含上次会话留下的）', () async {
      final h = Harness(policy: const BandwidthPolicy(stopSeedingAfterDownload: true));
      h.engine.torrents.addAll(<EngineTorrentRef>[
        const EngineTorrentRef(id: 7, finished: true),
        const EngineTorrentRef(id: 8, progress: 1.0),
        const EngineTorrentRef(id: 9, finished: true, paused: true), // 已经停过
        const EngineTorrentRef(id: 10, progress: 0.4), // 还在下
      ]);

      await h.manager.reconcileWithEngine();

      expect(h.engine.pauseCalls, <int>[7, 8]);
      await h.tearDown();
    });

    test('开关从「做种」切到「不做种」：立刻停掉已下完的（不等下一次进度事件）', () async {
      final h = Harness(); // 先开着做种
      h.engine.torrents.add(const EngineTorrentRef(id: 5, finished: true));

      h.manager.setPolicy(const BandwidthPolicy(stopSeedingAfterDownload: true));
      await Future<void>.delayed(Duration.zero);
      expect(h.engine.pauseCalls, <int>[5]);

      // 再保存一次设置（开关没变）不该反复打扰引擎。
      h.manager.setPolicy(const BandwidthPolicy(stopSeedingAfterDownload: true));
      await Future<void>.delayed(Duration.zero);
      expect(h.engine.pauseCalls, <int>[5]);
      await h.tearDown();
    });
  });

  group('暂停 / 继续 / 取消', () {
    test('pauseJob：downloading → paused 并调引擎 pause', () async {
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      final job = h.jobOf('item-01');
      await h.manager.pauseJob(job.id);
      expect(h.engine.pauseCalls, <int>[1]);
      expect(job.state, JobState.paused);
      await h.tearDown();
    });

    test('resumeJob：有 engineId 走引擎 resume', () async {
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      final job = h.jobOf('item-01');
      await h.manager.pauseJob(job.id);
      await h.manager.resumeJob(job.id);
      expect(h.engine.resumeCalls, <int>[1]);
      expect(job.state, JobState.downloading);
      await h.tearDown();
    });

    test('resumeJob：还没启动过的任务回到 queued 并重新调度', () async {
      final h = Harness();
      final job = (await h.manager.enqueue(ep('01'), subscriptionId: 's'))!;
      await h.manager.pauseJob(job.id);
      expect(job.state, JobState.paused);
      await h.manager.resumeJob(job.id);
      expect(job.state, JobState.queued); // autoPump=false → 等调度器
      await h.manager.pump();
      expect(job.state, JobState.downloading);
      expect(h.engine.resumeCalls, isEmpty);
      await h.tearDown();
    });

    test('非法状态转换会抛 QueueException', () async {
      final h = Harness();
      final job = (await h.manager.enqueue(ep('01'), subscriptionId: 's'))!;
      await expectLater(h.manager.resumeJob(job.id),
          throwsA(isA<QueueException>()));
      await expectLater(h.manager.pauseJob('不存在'),
          throwsA(isA<QueueException>()));
      await h.tearDown();
    });

    test('removeJob(deleteFiles) 透传引擎、真删记录并记墓碑', () async {
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      final job = h.jobOf('item-01');
      await h.manager.removeJob(job.id, deleteFiles: true);
      expect(h.engine.removeCalls.single.deleteFiles, isTrue);
      expect(h.jobs, isEmpty); // 记录真的从队列里删掉了（旧实现只标 cancelled）

      // 墓碑：订阅自动入队不会把这一集拉回来
      expect(await h.manager.enqueue(ep('01'), subscriptionId: 's'), isNull);
      expect(h.manager.isRemoved(ep('01')), isTrue);

      // 释放了并发位：新的任务能起来
      await h.manager.enqueue(ep('02'), subscriptionId: 's');
      await h.manager.pump();
      expect(h.jobOf('item-02').state, JobState.downloading);

      // 用户手点「下载」= 重新要，墓碑被清掉
      expect(
        await h.manager.enqueue(ep('01'), subscriptionId: 's', explicit: true),
        isNotNull,
      );
      expect(h.manager.isRemoved(ep('01')), isFalse);
      await h.tearDown();
    });

    // ------------------------------------------------------------------ 删不掉 = bug
    //
    // 用户 2026-10-11：「队列里总是有东西，还删不掉」。旧实现第一件事就是
    // `await engine.remove(...)` 且不兜异常：引擎一回 404（用户先在「已缓存」页删过这个
    // torrent、或边车重启后 id 变了）就把记录删除 + 墓碑一起打断。
    test('removeJob：引擎报 404 也必须删掉记录并记墓碑（只回报提示）', () async {
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      final job = h.jobOf('item-01');
      h.engine.removeError = StateError('404 no_such_torrent');

      final String? warning = await h.manager.removeJob(job.id);

      expect(h.jobs, isEmpty);
      expect(h.manager.isRemoved(ep('01')), isTrue);
      expect(warning, isNotNull);
      expect(warning, contains('队列记录已清理'));
      await h.tearDown();
    });

    // ---------------------------------------------- 第十九轮：下完的不能被队列带着删
    //
    // 用户 2026-10-12：「队列中移除了不应该把已完成里也移除」。用户心里「下完 = 本地文件」，
    // 而「已完成」页的数据源就是引擎里 `finished` 的那批种子 —— 队列侧「移除（不含文件）」
    // 一旦顺手删掉引擎那条记录，用户看到的就是「我在队列里清一下，已完成的片也没了」。
    group('队列移除不动已下完的引擎记录（第十九轮）', () {
      test('已 completed 的任务：只删队列记录，引擎与文件都不动', () async {
        final h = Harness();
        await h.manager.playNow(ep('01'), subscriptionId: 's');
        await h.manager.onProgress(const EngineProgressTick(
            id: 1, finished: true, completedFiles: <int>{0}));
        final job = h.jobOf('item-01');
        expect(job.state, JobState.completed);

        final String? warning = await h.manager.removeJob(job.id);

        expect(warning, isNull);
        expect(h.engine.removeCalls, isEmpty); // 引擎那份留着 → 「已完成」页照旧
        expect(h.engine.torrents, hasLength(1));
        expect(h.jobs, isEmpty);
        expect(h.manager.isRemoved(ep('01')), isTrue); // 墓碑照旧落地
        await h.tearDown();
      });

      test('队列还停在 downloading、引擎说下完了：也不动引擎（判据看引擎状态）', () async {
        final h = Harness();
        await h.manager.playNow(ep('01'), subscriptionId: 's');
        h.engine.torrents
          ..clear()
          ..add(const EngineTorrentRef(id: 1, finished: true));
        expect(h.jobOf('item-01').state, JobState.downloading);

        await h.manager.removeJob(h.jobOf('item-01').id);

        expect(h.engine.removeCalls, isEmpty);
        expect(h.jobs, isEmpty);
        await h.tearDown();
      });

      test('没下完的照旧删引擎那份（磁盘文件留着）', () async {
        final h = Harness();
        await h.manager.playNow(ep('01'), subscriptionId: 's');
        await h.manager.removeJob(h.jobOf('item-01').id);
        expect(h.engine.removeCalls.single.deleteFiles, isFalse);
        expect(h.engine.torrents, isEmpty);
        await h.tearDown();
      });

      test('「删除含文件」：下完的也照旧连引擎一起删', () async {
        final h = Harness();
        await h.manager.playNow(ep('01'), subscriptionId: 's');
        await h.manager.onProgress(const EngineProgressTick(
            id: 1, finished: true, completedFiles: <int>{0}));

        await h.manager.removeJob(h.jobOf('item-01').id, deleteFiles: true);

        expect(h.engine.removeCalls.single.deleteFiles, isTrue);
        expect(h.engine.torrents, isEmpty);
        await h.tearDown();
      });

      test('引擎读不到（边车没起）：不当作已下完，照旧尝试删除', () async {
        final h = Harness();
        await h.manager.playNow(ep('01'), subscriptionId: 's');
        h.engine.listError = StateError('engine down');

        final String? warning = await h.manager.removeJob(h.jobOf('item-01').id);

        expect(h.engine.removeCalls.single.id, 1);
        expect(warning, isNull); // 删除本身成功了：不算"引擎那一步没成功"
        expect(h.jobs, isEmpty);
        await h.tearDown();
      });

      test('clearAll：只从队列拿掉，引擎里已下完的那条留着', () async {
        final h = Harness();
        await h.manager.playNow(ep('01'), subscriptionId: 's');
        await h.manager.onProgress(const EngineProgressTick(
            id: 1, finished: true, completedFiles: <int>{0}));
        await h.manager.playNow(ep('02'), subscriptionId: 's'); // engineId 2，还在下
        expect(h.engine.torrents, hasLength(2));

        await h.manager.clearAll();

        expect(h.jobs, isEmpty);
        expect(h.engine.removeCalls.single.id, 2); // 只删没下完的那条
        expect(h.engine.torrents.single.id, 1);
        expect(h.manager.isRemoved(ep('01')), isTrue);
        await h.tearDown();
      });

      test('clearAll(deleteFiles: true)：明确要删文件时就都删，连下完的也不留', () async {
        final h = Harness();
        await h.manager.playNow(ep('01'), subscriptionId: 's');
        await h.manager.onProgress(const EngineProgressTick(
            id: 1, finished: true, completedFiles: <int>{0}));

        await h.manager.clearAll(deleteFiles: true);

        expect(h.engine.removeCalls.single.deleteFiles, isTrue);
        expect(h.engine.torrents, isEmpty);
        await h.tearDown();
      });
    });

    test('removeByEngine：删引擎那一份时把队列里绑着它的任务一起清掉', () async {
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      expect(h.jobs, hasLength(1));

      // 「已缓存」页删的就是这个 engineId：队列必须同步（否则留下幽灵"下载中"）。
      final String? warning = await h.manager.removeByEngine(1, deleteFiles: true);

      expect(warning, isNull);
      expect(h.engine.removeCalls.single.deleteFiles, isTrue);
      expect(h.jobs, isEmpty);
      expect(h.manager.isRemoved(ep('01')), isTrue);
      await h.tearDown();
    });

    test('removeByEngine：引擎里没有该 id 也照样把队列记录清掉', () async {
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      h.engine.removeError = StateError('404 no_such_torrent');
      final String? warning = await h.manager.removeByEngine(1);
      expect(h.jobs, isEmpty);
      expect(warning, contains('队列记录已清理'));
      await h.tearDown();
    });

    test('clearAll：引擎逐个失败也照样清空并记墓碑', () async {
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      await h.manager.playNow(ep('02'), subscriptionId: 's');
      h.engine.removeError = StateError('404');

      final String? warning = await h.manager.clearAll();

      expect(h.jobs, isEmpty);
      expect(h.manager.isRemoved(ep('01')), isTrue);
      expect(h.manager.isRemoved(ep('02')), isTrue);
      expect(warning, isNotNull);
      await h.tearDown();
    });

    test('同一集重复入队只会有一条任务（不会下几份）', () async {
      final h = Harness();
      final first = (await h.manager.enqueue(ep('01'), subscriptionId: 's'))!;
      final again = await h.manager.enqueue(ep('01'), subscriptionId: 's');
      expect(again!.id, first.id);
      expect(h.jobs, hasLength(1));

      await h.manager.pump();
      expect(h.engine.addCalls, hasLength(1));
      // 已经在下载时再点播：复用那条，不再 addMagnet
      final ticket = await h.manager.playNow(ep('01'), subscriptionId: 's');
      expect(ticket.job.id, first.id);
      expect(h.engine.addCalls, hasLength(1));
      await h.tearDown();
    });

    test('已下完的一集不会被订阅自动入队重置回队列（不重下一遍）', () async {
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      await h.manager.onProgress(
          const EngineProgressTick(id: 1, completedFiles: <int>{0}));
      expect(h.jobOf('item-01').state, JobState.completed);

      // 订阅又刷新到同一集（autoDownload 开着也一样）：不该重新入队/重下
      final again = await h.manager.enqueue(ep('01'), subscriptionId: 's');
      expect(again!.state, JobState.completed);
      expect(h.jobs, hasLength(1));
      await h.manager.pump();
      expect(h.engine.addCalls, hasLength(1));

      // 用户手点「下载」也不会把它重置成未下
      final manual = await h.manager.enqueue(ep('01'),
          subscriptionId: 's', explicit: true);
      expect(manual!.state, JobState.completed);
      expect(h.jobs, hasLength(1));
      await h.tearDown();
    });

    test('clearAll 清空队列并给每条记墓碑', () async {
      final h = Harness();
      await h.manager.enqueue(ep('01'), subscriptionId: 's');
      await h.manager.enqueue(ep('02'), subscriptionId: 's');
      expect(h.engine.removeCalls, isEmpty); // 都还没进引擎
      await h.manager.clearAll(deleteFiles: true);
      expect(h.jobs, isEmpty);
      expect(await h.manager.enqueue(ep('01'), subscriptionId: 's'), isNull);
      expect(await h.manager.enqueue(ep('02'), subscriptionId: 's'), isNull);
      await h.tearDown();
    });

    test('clearCompleted 只清理已完成记录', () async {
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      await h.manager.onProgress(
          const EngineProgressTick(id: 1, completedFiles: <int>{0}));
      await h.manager.enqueue(ep('02'), subscriptionId: 's');
      await h.manager.clearCompleted();
      expect(h.jobs, hasLength(1));
      expect(h.jobs.single.item.id, 'item-02');
      await h.tearDown();
    });
  });

  group('持久化与重启对齐', () {
    test('每次状态变化都写盘；load() 可恢复', () async {
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      final raw = h.store.get('jobs');
      expect(raw, isA<List<dynamic>>());
      expect((raw! as List<dynamic>).length, 1);

      final restored = QueueManager(
        engine: h.engine,
        store: h.store,
        autoPump: false,
        idGenerator: () => 'job-x',
      );
      await restored.load();
      expect(restored.jobs, hasLength(1));
      final job = restored.jobs.single;
      expect(job.item.id, 'item-01');
      // 重启后 downloading 也降级成 paused（见 load 文档：边车会自己恢复 torrent 接着传，
      // "重启不自动下载"必须在引擎侧也成立）。
      expect(job.state, JobState.paused);
      expect(job.error, contains('重启'));
      expect(job.engineId, 1);
      expect(job.fileIndex, 0);
      expect(job.priority, QueueManager.playbackPriority);
      await restored.dispose();
      await h.tearDown();
    });

    test('损坏记录被跳过并记录 warning', () async {
      final store = InMemoryKeyValueStore(<String, Object?>{
        'jobs': <dynamic>[
          'not-a-map',
          <String, dynamic>{'id': 'broken'}, // 缺 item/createdAt
        ],
      });
      final engine = FakeEngine();
      final manager = QueueManager(engine: engine, store: store, autoPump: false);
      await manager.load();
      expect(manager.jobs, isEmpty);
      expect(manager.loadWarnings, hasLength(2));
      await manager.dispose();
      await engine.dispose();
    });

    test('重启对齐：同 infoHash 视为同一任务，重新绑定引擎 id', () async {
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');
      expect(h.jobOf('item-01').engineId, 1);

      // 模拟「引擎重启后 id 变了」：新 manager + 引擎里已有同 infoHash 的任务
      final restarted = QueueManager(
        engine: h.engine,
        store: h.store,
        autoPump: false,
      );
      await restarted.load();
      h.engine.torrents.clear();
      h.engine.torrents.add(EngineTorrentRef(
        id: 42,
        infoHash: '01'.padLeft(40, '0'),
        name: '[组] 某番 - 01 [1080p]',
      ));
      await restarted.reconcileWithEngine();

      final job = restarted.jobs.single;
      expect(job.state, JobState.paused); // 重新绑定 ≠ 自动接着下
      expect(job.engineId, 42);
      expect(job.error, contains('重启后不会自动继续'));
      // 引擎侧也被按住了：边车自己恢复出来的那一份不许偷偷继续传。
      expect(h.engine.pauseCalls, contains(42));
      await restarted.dispose();
      await h.tearDown();
    });

    test('重启对齐：infoHash 缺失时按名称兜底', () async {
      final item = SourceItem(
        id: 'item-nohash',
        sourceId: 'mikan',
        title: '[组] 无 hash 的一集 - 07',
        magnet: null,
        infoHash: null,
        episodeHints: const <String>['07'],
      );
      final h = Harness();
      final job = (await h.manager.enqueue(item, subscriptionId: 's'))!;
      job.state = JobState.downloading;
      job.engineId = 7;
      job.fileIndex = 0;
      await h.store.put('jobs', <dynamic>[job.toJson()]);

      final restarted =
          QueueManager(engine: h.engine, store: h.store, autoPump: false);
      await restarted.load();
      h.engine.torrents
        ..clear()
        ..add(const EngineTorrentRef(id: 99, name: '[组] 无 hash 的一集 - 07'));
      await restarted.reconcileWithEngine();

      expect(restarted.jobs.single.engineId, 99);
      expect(restarted.jobs.single.error, contains('重启后不会自动继续'));
      await restarted.dispose();
      await h.tearDown();
    });

    test('重启对齐：引擎任务重新绑定但缺 fileIndex 时给出提示', () async {
      final item = SourceItem(
        id: 'item-nohash2',
        sourceId: 'mikan',
        title: '[组] 无索引的一集 - 08',
        magnet: 'magnet:?xt=urn:btih:${'8'.padLeft(40, '0')}',
        episodeHints: const <String>['08'],
      );
      final h = Harness();
      final job = (await h.manager.enqueue(item, subscriptionId: 's'))!;
      job.state = JobState.downloading;
      job.engineId = 7;
      await h.store.put('jobs', <dynamic>[job.toJson()]);

      final restarted =
          QueueManager(engine: h.engine, store: h.store, autoPump: false);
      await restarted.load();
      h.engine.torrents
        ..clear()
        ..add(EngineTorrentRef(
            id: 99, infoHash: '8'.padLeft(40, '0'), name: item.title));
      await restarted.reconcileWithEngine();

      expect(restarted.jobs.single.engineId, 99);
      expect(restarted.jobs.single.error, contains('文件索引'));
      await restarted.dispose();
      await h.tearDown();
    });

    test('重启对齐：引擎里找不到 → 暂停且绝不自动重新下载', () async {
      final h = Harness();
      await h.manager.playNow(ep('01'), subscriptionId: 's');

      final restarted =
          QueueManager(engine: h.engine, store: h.store, autoPump: false);
      await restarted.load();
      h.engine.torrents.clear();
      await restarted.reconcileWithEngine();

      final job = restarted.jobs.single;
      expect(job.state, JobState.paused);
      expect(job.engineId, isNull);
      expect(job.error, contains('不会自动重新下载'));

      // 调度器不会自己把它拉起来（旧行为是标 queued + pump → 又下一遍）
      await restarted.pump();
      expect(restarted.jobs.single.state, JobState.paused);
      expect(h.engine.addCalls, hasLength(1));

      // 用户点「继续」才会重新下
      await restarted.resumeJob(job.id);
      await restarted.pump();
      expect(restarted.jobs.single.state, JobState.downloading);
      expect(h.engine.addCalls, hasLength(2));
      await restarted.dispose();
      await h.tearDown();
    });

    test('重启后盘上排队的任务不会自动开始（要点继续）', () async {
      final h = Harness();
      final job = (await h.manager.enqueue(ep('01'), subscriptionId: 's'))!;
      expect(job.state, JobState.queued);

      final restarted =
          QueueManager(engine: h.engine, store: h.store, autoPump: true);
      await restarted.load();
      await restarted.pump();
      expect(restarted.jobs.single.state, JobState.paused);
      expect(restarted.isDeferred(job.id), isTrue);
      expect(h.engine.addCalls, isEmpty); // 一次 addMagnet 都没发生

      await restarted.resumeJob(job.id);
      await restarted.pump();
      expect(restarted.jobs.single.state, JobState.downloading);
      expect(h.engine.addCalls, hasLength(1));
      await restarted.dispose();
      await h.tearDown();
    });

    test('对齐时把引擎返回的 infoHash 补进条目（mikan RSS 原本没有）', () async {
      final item = SourceItem(
        id: 'item-mikan',
        sourceId: 'mikan',
        title: '[组] 蜜柑的一集 - 03',
        magnet: 'magnet:?xt=urn:btih:${'3'.padLeft(40, '0')}',
        episodeHints: const <String>['03'],
      );
      final h = Harness();
      final job = (await h.manager.enqueue(item, subscriptionId: 's'))!;
      job.state = JobState.downloading;
      await h.store.put('jobs', <dynamic>[job.toJson()]);

      final restarted =
          QueueManager(engine: h.engine, store: h.store, autoPump: false);
      await restarted.load();
      h.engine.torrents
        ..clear()
        ..add(EngineTorrentRef(
            id: 5, infoHash: '3'.padLeft(40, '0'), name: item.title));
      await restarted.reconcileWithEngine();

      expect(restarted.jobs.single.item.infoHash, '3'.padLeft(40, '0'));
      await restarted.dispose();
      await h.tearDown();
    });
  });

  test('changes 流每次变化都推一份完整快照', () async {
    final h = Harness();
    final seen = <List<QueueJob>>[];
    final sub = h.manager.changes.listen(seen.add);
    await h.manager.enqueue(ep('01'), subscriptionId: 's');
    await h.manager.pump();
    await Future<void>.delayed(Duration.zero);
    expect(seen, isNotEmpty);
    expect(seen.last.single.state, JobState.downloading);
    await sub.cancel();
    await h.tearDown();
  });
}
