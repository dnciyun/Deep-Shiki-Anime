/// `mergeDraftForSave` / `settingsEqual` 的纯函数单测（2026-10-12 第十六轮：手动保存）。
///
/// 这两个函数是"手动保存"里唯一有判断的地方：脏没脏、以及保存时到底写哪几个字段。
library;

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/settings_draft.dart';
import 'package:flutter_test/flutter_test.dart';

const AppSettings _base = AppSettings(
  firstRunCompleted: true,
  downloadDir: r'F:\Anime',
  uploadLimitKbps: 100,
  extraTrackers: 'udp://old.example:6969/announce',
  defaultSourceId: 'mikan',
);

void main() {
  group('settingsEqual：脏没脏的判据', () {
    test('同一份相等；任一个字段不同就不等', () {
      expect(settingsEqual(_base, const AppSettings(firstRunCompleted: true, downloadDir: r'F:\Anime', uploadLimitKbps: 100, extraTrackers: 'udp://old.example:6969/announce', defaultSourceId: 'mikan')), isTrue);
      expect(settingsEqual(_base, _base.copyWith(uploadLimitKbps: 101)), isFalse);
      // 嵌套结构（bandwidth）与列表（trackerSourceUrls）也算得出来。
      expect(
        settingsEqual(_base, _base.copyWith(bandwidth: _base.bandwidth.copyWith(excludePatterns: <String>['x']))),
        isFalse,
      );
      expect(
        settingsEqual(_base, _base.copyWith(trackerSourceUrls: <String>['https://a/b.txt'])),
        isFalse,
      );
    });
  });

  group('mergeDraftForSave：用户改的写下去，没碰过的留给"现在的已保存值"', () {
    test('后台在用户改东西的同时写了 tracker → 不能被草稿里的旧值吞掉', () {
      final AppSettings draft = _base.copyWith(uploadLimitKbps: 500);
      // 后台写者（每日 tracker 刷新 / 搜索页勾选）在用户改的时候写进了新值。
      final AppSettings current = _base.copyWith(
        extraTrackers: 'udp://new.example:6969/announce',
      );
      final AppSettings saved = mergeDraftForSave(
        baseline: _base,
        draft: draft,
        current: current,
      );
      expect(saved.uploadLimitKbps, 500, reason: '用户改过的字段用草稿');
      expect(
        saved.extraTrackers,
        'udp://new.example:6969/announce',
        reason: '用户没碰过 tracker → 保留后台刚写进去的那份',
      );
    });

    test('什么都没改 → 结果等于"现在的已保存值"（后台改动原样保留）', () {
      final AppSettings current = _base.copyWith(defaultSourceId: 'nyaa');
      final AppSettings saved = mergeDraftForSave(
        baseline: _base,
        draft: _base,
        current: current,
      );
      expect(settingsEqual(saved, current), isTrue);
    });

    test('把下载目录清空（null）也算一次改动', () {
      final AppSettings draft = _base.copyWith(clearDownloadDir: true);
      final AppSettings current = _base.copyWith(downloadDir: r'D:\Elsewhere');
      expect(draft.downloadDir, isNull);
      expect(
        mergeDraftForSave(baseline: _base, draft: draft, current: current).downloadDir,
        isNull,
        reason: '用户明确清空了目录，不能被后台那份目录覆盖回去',
      );
    });

    test('两边改的是同一个字段 → 用户赢（保存的意义所在）', () {
      final AppSettings draft = _base.copyWith(uploadLimitKbps: 500);
      final AppSettings current = _base.copyWith(uploadLimitKbps: 900);
      expect(
        mergeDraftForSave(baseline: _base, draft: draft, current: current).uploadLimitKbps,
        500,
      );
    });
  });

  group('⚠️ 逐字段比较不能靠字符串插值（把值直接拼进字符串）', () {
    // 审查发现：`'${from[key]}' != '${entry.value}'` 对列表是 `toString()` 比较，
    // 于是 `['a, b']` 与 `['a', 'b']` 的字符串**完全相同** → "用户真的改了"被判成没改：
    // 脏标记不翻（保存按钮一直灰着），合成落盘那份也会把用户的改动丢掉。
    const AppSettings baseline = AppSettings(
      aggregateExcludedSourceIds: <String>['a', 'b'],
    );
    final AppSettings draft =
        baseline.copyWith(aggregateExcludedSourceIds: <String>['a, b']);

    test('settingsEqual：这种改动必须算"改过了"', () {
      expect(
        settingsEqual(baseline, draft),
        isFalse,
        reason: '真的改了 → 脏标记必须翻，否则用户点不动「保存并生效」',
      );
    });

    test('mergeDraftForSave：这种改动必须写下去（不能被 current 顶掉）', () {
      final AppSettings current =
          baseline.copyWith(aggregateExcludedSourceIds: <String>['x']);
      expect(
        mergeDraftForSave(baseline: baseline, draft: draft, current: current)
            .aggregateExcludedSourceIds,
        <String>['a, b'],
      );
    });

    test('DateTime 字段照旧比得出来（不能用 jsonEncode 直接炸）', () {
      final DateTime t = DateTime(2026, 10, 11, 12);
      expect(
        settingsEqual(
          AppSettings(trackerListUpdatedAt: t),
          AppSettings(trackerListUpdatedAt: t),
        ),
        isTrue,
      );
      expect(
        settingsEqual(
          AppSettings(trackerListUpdatedAt: t),
          AppSettings(trackerListUpdatedAt: t.add(const Duration(seconds: 1))),
        ),
        isFalse,
      );
    });
  });
}
