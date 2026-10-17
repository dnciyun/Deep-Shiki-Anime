/// 主页网格的「2Hz 重建」有没有真的被掐断（1.1.0 M1/T2）。
///
/// ## 改之前的病灶（代码事实，不是猜）
///
/// * 引擎快照流是**每 2Hz 一帧**（`engineTorrentsProvider` → `cachedTorrentsProvider`），
///   而且每帧都是**新的 `List` 身份** → Riverpod 无条件通知下游；
/// * 旧实现里 `HomePage.build` 调 `_grid()`，`_grid()` 里 `ref.watch(cachedTorrentsProvider)`
///   再对**每张卡**跑 `anyTitleContains(cachedNames, title)`（把已下完的每个 torrent 名
///   逐字符归一化一遍）；
/// * 每张卡还各 `ref.watch(followingProvider)` 再 `any()` 一遍。
///
/// 所以"主页在下载时 2Hz 全页重建 + N×M 次逐字符扫描"这条链是真的。改法见
/// `cachedNormalizedTorrentNamesProvider` 与 `ui/home_page.dart` 的 `_UpdateGrid`。
///
/// 这里钉住的是**机制**（这条链的源头）：名字集合没变时下游一次都不许被通知；
/// 名字集合变了必须通知（否则「已缓存」角标再也不更新，那是另一种 bug）。
library;

import 'dart:async';

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/title_match.dart';
import 'package:dsanima/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 能让测试**逐帧推**引擎快照的替身（真实引擎是 2Hz 一帧的 `watch()`）。
class _StreamingEnginePort implements EnginePort {
  final StreamController<List<EngineTorrentView>> controller =
      StreamController<List<EngineTorrentView>>.broadcast();

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
  Future<List<EngineTorrentView>> list() async => const <EngineTorrentView>[];

  @override
  Future<void> pause(int id) async {}

  @override
  Future<void> resume(int id) async {}

  @override
  Future<void> remove(int id, {bool deleteFiles = false}) async {}

  @override
  Stream<List<EngineTorrentView>> watch() => controller.stream;

  @override
  Uri? streamUrl(int id, int fileIndex) => null;
}

EngineTorrentView _finished(
  String name, {
  double downloadBps = 0,
  int uploadedBytes = 0,
  int id = 1,
}) => EngineTorrentView(
  id: id,
  name: name,
  state: TorrentState.live,
  progress: 1,
  finished: true,
  downloadBps: downloadBps,
  uploadedBytes: uploadedBytes,
);

void main() {
  group('已缓存名字集合：2Hz 帧不许惊动下游（1.1.0 M1/T2）', () {
    late _StreamingEnginePort engine;
    late ProviderContainer container;
    late int rawNotifications;
    late int normalizedNotifications;

    setUp(() {
      engine = _StreamingEnginePort();
      container = ProviderContainer(
        overrides: [enginePortProvider.overrideWithValue(engine)],
      );
      rawNotifications = 0;
      normalizedNotifications = 0;
      // 旧路径（对照组）：下游拿到的是"新的 List 身份"，每帧都会被通知。
      container.listen<List<EngineTorrentView>>(
        cachedTorrentsProvider,
        (_, _) => rawNotifications++,
      );
      // 新路径：主页实际 watch 的就是它。
      container.listen<List<String>>(
        cachedNormalizedTorrentNamesProvider,
        (_, _) => normalizedNotifications++,
      );
      // 把 provider 真正拉起来（listen 已经会建，这里读一次确认初始值）。
      expect(container.read(cachedNormalizedTorrentNamesProvider), isEmpty);
    });

    tearDown(() async {
      container.dispose();
      await engine.controller.close();
    });

    test('同一批 torrent 连续 10 帧进度/速度 tick：旧路径 11 次，新路径 1 次', () async {
      engine.controller.add(<EngineTorrentView>[_finished('[ANi] 葬送的芙莉莲 - 01 [1080p]')]);
      await pumpEventQueue();
      expect(rawNotifications, 1, reason: '引擎第一帧就是新 List，下游被通知');
      expect(normalizedNotifications, 1, reason: '名字集合变了，主页该更新一次');
      expect(
        container.read(cachedNormalizedTorrentNamesProvider),
        <String>['ani葬送的芙莉莲011080p'],
        reason: '归一化在 provider 里做一次（去标点空白 + 小写）',
      );

      for (int frame = 0; frame < 10; frame++) {
        // 同一条 torrent，只是进度/速度在动 —— 名字集合完全没变。
        engine.controller.add(<EngineTorrentView>[
          _finished(
            '[ANi] 葬送的芙莉莲 - 01 [1080p]',
            downloadBps: 1024.0 * frame,
            uploadedBytes: frame * 4096,
          ),
        ]);
        await pumpEventQueue();
      }

      expect(rawNotifications, 11, reason: '旧路径每帧都换 List 身份 → 11 帧 11 次通知');
      expect(
        normalizedNotifications,
        1,
        reason: '新路径只在名字集合变过的那 1 次通知 —— 这就是整页不再 2Hz 重建的原因',
      );
    });

    test('又下完一部：名字集合变了，必须继续通知（角标不能冻住）', () async {
      engine.controller.add(<EngineTorrentView>[_finished('[ANi] 葬送的芙莉莲 - 01 [1080p]')]);
      await pumpEventQueue();
      expect(normalizedNotifications, 1);

      engine.controller.add(<EngineTorrentView>[
        _finished('[ANi] 葬送的芙莉莲 - 01 [1080p]', id: 1),
        _finished('[Lilith] 迷宫饭 - 02 [1080p]', id: 2),
      ]);
      await pumpEventQueue();
      expect(normalizedNotifications, 2, reason: '多了一部下完的番 → 主页角标必须跟着更新');
      expect(
        container.read(cachedNormalizedTorrentNamesProvider),
        containsAll(<String>['ani葬送的芙莉莲011080p', 'lilith迷宫饭021080p']),
      );
    });

    test('只有"没下完"的 torrent 变多：不进已缓存集合，也不通知', () async {
      engine.controller.add(<EngineTorrentView>[
        const EngineTorrentView(id: 9, name: '还没下完的东西', progress: 0.3),
      ]);
      await pumpEventQueue();
      // 旧路径照样通知（List 身份变了），但新路径不该动：已缓存集合还是空。
      expect(rawNotifications, 1);
      expect(normalizedNotifications, 0);
      expect(container.read(cachedNormalizedTorrentNamesProvider), isEmpty);
    });
  });

  group('归一化匹配：新函数与旧函数同语义', () {
    test('anyNormalizedTitleContains 与 anyTitleContains 在所有样例上结论一致', () {
      final List<String> rawHaystacks = <String>[
        '[ANi] 葬送的芙莉莲 - 01 [1080p]',
        '[Lilith] 迷宫饭 02 [1080p][Baha]',
        '【喵萌奶茶屋】★10月新番★[药屋少女的呢喃][25][1080p][简日双语]',
        '短名AB',
      ];
      final List<String> normalized = <String>[
        for (final String h in rawHaystacks) normalizeTitleForMatch(h),
      ];
      for (final String title in <String>[
        '葬送的芙莉莲',
        '迷宫饭',
        '药屋少女的呢喃',
        '不存在的番',
        '短',
        '01',
        '',
        '1080p',
      ]) {
        expect(
          anyNormalizedTitleContains(normalized, title),
          anyTitleContains(rawHaystacks, title),
          reason: '「$title」两边结论必须一致',
        );
      }
    });
  });
}
