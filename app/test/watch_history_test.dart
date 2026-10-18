/// 观看记录领域层（第二十七轮）：键口径、保留档位清理、去重写入、导出 JSON、坏数据。
///
/// 全是纯函数 + 内存 KV，不联网不起引擎。
library;

import 'package:dsanima/domain/watch_history.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter_test/flutter_test.dart';

WatchRecord _record({
  String id = 'mikan:1||e1',
  String title = '某番',
  String? group = 'ANi',
  int? episode = 1,
  DateTime? at,
  int positionMs = 0,
  int durationMs = 0,
  String? infoHash,
  int? engineId,
  int? fileIndex,
}) => WatchRecord(
  id: id,
  title: title,
  group: group,
  episode: episode,
  watchedAt: at ?? DateTime(2026, 10, 1, 12),
  positionMs: positionMs,
  durationMs: durationMs,
  infoHash: infoHash,
  engineId: engineId,
  fileIndex: fileIndex,
);

void main() {
  group('watchRecordId：键 = 番剧 + 字幕组 + 集数', () {
    test('有 mikan id 时用 id（不看番名），同一集稳定', () {
      final String a = watchRecordId(mikanBangumiId: '3887', title: 'A', group: 'ANi', episode: 3);
      final String b = watchRecordId(mikanBangumiId: '3887', title: 'A 第二季', group: 'ANi', episode: 3);
      expect(a, b, reason: '同番同组同集：番名写法不同也必须是同一条（否则每次改名都多一条）');
      expect(a, 'mikan:3887|ANi|e3');
    });

    test('没有 id 时退化成番名（小写归一），仍然带字幕组与集数', () {
      expect(watchRecordId(title: 'Some Show', group: 'G', episode: 2), 'some show|G|e2');
      expect(
        watchRecordId(title: '某番', group: 'G', episode: 2) ==
            watchRecordId(title: '某番', group: 'H', episode: 2),
        isFalse,
        reason: '不同字幕组的同一集是两条（用户按字幕组订阅，正是要分清这件事）',
      );
    });

    test('认不出集数时用集号文案兜底，再认不出用 all', () {
      expect(watchRecordId(title: 'X', group: 'G', episodeLabel: 'SP1'), 'x|G|SP1');
      expect(watchRecordId(title: 'X', group: 'G'), 'x|G|all');
    });
  });

  group('pruneWatchHistory：保留档位', () {
    final DateTime now = DateTime(2026, 10, 31, 12);

    test('30 天档位：正好 30 天前的丢掉、29 天前的留着（边界逐日）', () {
      final List<WatchRecord> records = <WatchRecord>[
        _record(id: 'a', at: now.subtract(const Duration(days: 31))),
        _record(id: 'b', at: now.subtract(const Duration(days: 30))),
        _record(id: 'c', at: now.subtract(const Duration(days: 29))),
      ];
      final List<WatchRecord> kept =
          pruneWatchHistory(records, retentionDays: 30, now: now);
      expect(kept.map((WatchRecord r) => r.id), <String>['c'],
          reason: '判据是"晚于 now-30天"：正好 30 天前那一条已经过期');
    });

    test('7 / 90 天档位各自生效', () {
      final List<WatchRecord> records = <WatchRecord>[
        _record(id: 'a', at: now.subtract(const Duration(days: 10))),
        _record(id: 'b', at: now.subtract(const Duration(days: 40))),
      ];
      expect(pruneWatchHistory(records, retentionDays: 7, now: now), isEmpty);
      expect(
        pruneWatchHistory(records, retentionDays: 90, now: now).length,
        2,
      );
    });

    test('0 = 永不删除（用户可选项）：一条都不丢', () {
      final List<WatchRecord> records = <WatchRecord>[
        _record(id: 'a', at: DateTime(2020, 1, 1)),
      ];
      expect(pruneWatchHistory(records, retentionDays: 0, now: now), hasLength(1));
      expect(pruneWatchHistory(records, retentionDays: -1, now: now), hasLength(1));
    });
  });

  group('upsertWatchRecord / updateWatchProgress', () {
    test('同键覆盖（不追加）：反复看同一集只留一条，时间刷新', () {
      final List<WatchRecord> first = upsertWatchRecord(
        const <WatchRecord>[],
        _record(at: DateTime(2026, 10, 1)),
      );
      final List<WatchRecord> second = upsertWatchRecord(
        first,
        _record(at: DateTime(2026, 10, 2), positionMs: 1000, durationMs: 2000),
      );
      expect(second, hasLength(1));
      expect(second.single.watchedAt, DateTime(2026, 10, 2));
      expect(second.single.positionMs, 1000);
    });

    test('按看过时间倒序；超过上限丢最旧的', () {
      final List<WatchRecord> records = upsertWatchRecord(
        <WatchRecord>[
          _record(id: 'old', at: DateTime(2026, 9, 1)),
          _record(id: 'new', at: DateTime(2026, 10, 5)),
        ],
        _record(id: 'mid', at: DateTime(2026, 9, 20)),
      );
      expect(records.map((WatchRecord r) => r.id), <String>['new', 'mid', 'old']);

      final List<WatchRecord> capped = upsertWatchRecord(
        <WatchRecord>[
          _record(id: 'a', at: DateTime(2026, 10, 1)),
          _record(id: 'b', at: DateTime(2026, 10, 2)),
        ],
        _record(id: 'c', at: DateTime(2026, 10, 3)),
        maxEntries: 2,
      );
      expect(capped.map((WatchRecord r) => r.id), <String>['c', 'b']);
    });

    test('updateWatchProgress 只动进度与时间；没有这条就原样返回（不凭空造记录）', () {
      final List<WatchRecord> records = <WatchRecord>[_record(id: 'a', positionMs: 5)];
      final List<WatchRecord> updated = updateWatchProgress(
        records,
        id: 'a',
        positionMs: 600000,
        durationMs: 1440000,
        at: DateTime(2026, 10, 9),
      );
      expect(updated.single.positionMs, 600000);
      expect(updated.single.durationMs, 1440000);
      expect(updated.single.watchedAt, DateTime(2026, 10, 9));
      expect(updated.single.title, '某番', reason: '身份字段不许被进度更新改掉');

      final List<WatchRecord> missing =
          updateWatchProgress(records, id: 'nope', positionMs: 1, durationMs: 2);
      expect(missing.single.positionMs, 5);
    });

    test('progress / finished：时长未知一律不猜（0 / false）', () {
      expect(_record(positionMs: 90, durationMs: 100).progress, closeTo(0.9, 1e-9));
      expect(_record(positionMs: 90, durationMs: 100).finished, isTrue);
      expect(_record(positionMs: 89, durationMs: 100).finished, isFalse);
      expect(_record(positionMs: 500, durationMs: 0).progress, 0);
      expect(_record(positionMs: 500, durationMs: 0).finished, isFalse);
      expect(_record(positionMs: 999, durationMs: 100).progress, 1.0, reason: '夹到 0..1');
    });
  });

  group('WatchHistoryStore / watchHistoryJson', () {
    test('往返：写入 → 再读；单条坏数据跳过', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore();
      final WatchHistoryStore history = WatchHistoryStore(store);
      expect(history.load(), isEmpty);
      await history.save(<WatchRecord>[
        _record(id: 'a', infoHash: 'aa', engineId: 7, fileIndex: 1),
      ]);
      final WatchRecord back = WatchHistoryStore(store).load().single;
      expect(back.id, 'a');
      expect(back.infoHash, 'aa');
      expect(back.engineId, 7);
      expect(back.fileIndex, 1);

      final InMemoryKeyValueStore dirty = InMemoryKeyValueStore(<String, Object?>{
        WatchHistoryStore.defaultKey: <Object?>[
          'not-a-map',
          <String, Object?>{'id': '', 'title': 'x', 'watchedAt': '2026-10-01T00:00:00'},
          <String, Object?>{'id': 'b', 'title': 'y', 'watchedAt': '坏时间'},
          _record(id: 'c').toJson(),
        ],
      });
      expect(WatchHistoryStore(dirty).load().single.id, 'c');
    });

    test('导出 JSON：含 schema / 条数 / 保留档位与每条记录（进度也在里面）', () {
      final String json = watchHistoryJson(
        <WatchRecord>[_record(id: 'a', positionMs: 60, durationMs: 120)],
        exportedAt: DateTime(2026, 10, 9, 8),
        retentionDays: 30,
      );
      expect(json, contains('dsanima.watch-history/1'));
      expect(json, contains('"count": 1'));
      expect(json, contains('"retention": "30 days"'));
      expect(json, contains('"positionMs": 60'));
      expect(json, contains('2026-10-09T08:00:00.000'));
      // 不删除档位写 keep（读的人能一眼看出"这份是全量"）。
      expect(
        watchHistoryJson(const <WatchRecord>[], retentionDays: 0),
        contains('"retention": "keep"'),
      );
    });

    test('clear 之后读回空', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore();
      final WatchHistoryStore history = WatchHistoryStore(store);
      await history.save(<WatchRecord>[_record()]);
      await history.clear();
      expect(history.load(), isEmpty);
    });
  });

  group('「已看过」标记（WatchedMarkStore / watchedKey）', () {
    test('watchedKey 与观看记录的键同一套口径（否则打勾对不上记录）', () {
      expect(
        watchedKey('3887', group: 'ANi', episode: 3),
        watchRecordId(mikanBangumiId: '3887', title: '3887', group: 'ANi', episode: 3),
      );
    });

    test('往返：打勾 → 读回带时间；没打勾的键不在表里', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore();
      final WatchedMarkStore marks = WatchedMarkStore(store);
      expect(marks.load(), isEmpty);
      await marks.save(<String, DateTime>{'k1': DateTime(2026, 10, 9, 20)});
      final Map<String, DateTime> back = WatchedMarkStore(store).load();
      expect(back.keys, <String>['k1']);
      expect(back['k1'], DateTime(2026, 10, 9, 20));
      expect(back.containsKey('k2'), isFalse);
    });

    test('坏数据（非 map / 坏时间）跳过，不炸', () {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore(<String, Object?>{
        WatchedMarkStore.defaultKey: <String, Object?>{'good': '2026-10-09T20:00:00', 'bad': 'x'},
      });
      final Map<String, DateTime> marks = WatchedMarkStore(store).load();
      expect(marks.keys, <String>['good']);
    });
  });

  group('WatchMeta（开播那一刻算好的键）', () {
    test('buildWatchMeta：recordId 与 watchedKey 同值，缺 id 时退化成番名', () {
      final WatchMeta meta = buildWatchMeta(
        title: '葬送的芙莉莲',
        group: 'ANi',
        episode: 8,
        mikanBangumiId: '3887',
      );
      expect(meta.recordId, 'mikan:3887|ANi|e8');
      expect(meta.watchedKey, meta.recordId);
      final WatchMeta noId = buildWatchMeta(title: '某番', group: 'G', episode: 1);
      expect(noId.recordId, '${'某番'.toLowerCase()}|G|e1');
      expect(noId.mikanBangumiId, isNull);
    });
  });

  // 用户 2026-10-18：「发现bug继续观看回不到上一次的观看位置」。
  // 续播的位置只能有一个口径 —— 观看记录里那条 `positionMs`（按番剧+字幕组+集数记，
  // 跨重启有效）。这两个函数就是"任何入口点开一集"都该走的那条查表路径。
  group('续播查表（从任何入口点播都接着上次的位置）', () {
    test('按记录键查：命中就给位置；已看完 / 没进度 → null（从头）', () {
      final List<WatchRecord> records = <WatchRecord>[
        _record(id: 'a|G|e1', positionMs: 754000, durationMs: 1440000),
        _record(id: 'a|G|e2', positionMs: 1400000, durationMs: 1440000),
        _record(id: 'a|G|e3'),
      ];
      expect(resumePositionForRecord(records, 'a|G|e1'), 754000);
      expect(
        resumePositionForRecord(records, 'a|G|e2'),
        isNull,
        reason: '看到 97% 算看完 —— 「继续播放」不该把人扔到片尾',
      );
      expect(resumePositionForRecord(records, 'a|G|e3'), isNull, reason: '本来就没有进度');
      expect(resumePositionForRecord(records, 'a|G|e9'), isNull, reason: '没这条记录 → 从头');
    });

    test('按引擎坐标查：infoHash + 文件序号都要对上（不猜"大概是这集"）', () {
      final List<WatchRecord> records = <WatchRecord>[
        _record(id: 'k1', infoHash: 'h1', fileIndex: 0, positionMs: 300000, durationMs: 1440000),
        _record(id: 'k2', infoHash: 'h1', fileIndex: 1, positionMs: 600000, durationMs: 1440000),
      ];
      expect(resumePositionForFile(records, infoHash: 'h1', fileIndex: 1), 600000);
      expect(resumePositionForFile(records, infoHash: 'h1', fileIndex: 0), 300000);
      expect(
        resumePositionForFile(records, infoHash: 'h1', fileIndex: 2),
        isNull,
        reason: '同一个种子的别的文件没有记录 → 从头，不许借别的集的位置',
      );
      expect(
        resumePositionForFile(records, infoHash: 'h2', fileIndex: 1),
        isNull,
        reason: '换了种子（infohash 不同）就不是同一集',
      );
      expect(resumePositionForFile(records, infoHash: null, fileIndex: 1), isNull);
      expect(resumePositionForFile(records, infoHash: '   ', fileIndex: 1), isNull);
    });

    test('同一坐标有多条记录时取最近看的那条', () {
      final List<WatchRecord> records = <WatchRecord>[
        _record(id: 'old', infoHash: 'h1', fileIndex: 0, positionMs: 100000,
            durationMs: 1440000, at: DateTime(2026, 9, 1)),
        _record(id: 'new', infoHash: 'h1', fileIndex: 0, positionMs: 900000,
            durationMs: 1440000, at: DateTime(2026, 10, 1)),
      ];
      expect(resumePositionForFile(records, infoHash: 'h1', fileIndex: 0), 900000);
    });
  });
}
