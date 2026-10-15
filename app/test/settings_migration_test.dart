/// 观看记录保留期的**一次性迁移**（第三十三轮）。
///
/// 用户：「历史记录从默认30天改为不删」。
/// 新装默认已经是 0（`AppSettings` 的默认值），这里钉的是**存量数据**：
/// * 旧默认 30 → 改成 0（不改的话"新默认"对老用户完全不起作用）；
/// * 手选过 7 / 90 的**一个字不动**（那是显式选择）；
/// * 只跑一次（跑过之后再手动选回 30 天，不会被下次启动改掉）。
library;

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/state/settings_migration.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter_test/flutter_test.dart';

InMemoryKeyValueStore _store(int days) => InMemoryKeyValueStore(<String, Object?>{
  SettingsController.storageKey:
      const AppSettings(firstRunCompleted: true).copyWith(historyRetentionDays: days).toJson(),
});

int _saved(InMemoryKeyValueStore store) => AppSettings.fromJson(
  (store.get(SettingsController.storageKey) as Map?)?.cast<Object?, Object?>(),
).historyRetentionDays;

void main() {
  test('新装默认就是「不删除」（0）', () {
    expect(const AppSettings().historyRetentionDays, 0);
  });

  test('旧默认 30 天 → 迁移成不删除', () async {
    final InMemoryKeyValueStore store = _store(kLegacyDefaultHistoryRetentionDays);
    final bool changed = await migrateHistoryRetentionToNeverDelete(store);
    expect(changed, isTrue);
    expect(_saved(store), 0);
    expect(store.get(kHistoryRetentionMigrationKey), isTrue);
  });

  test('手选过的 7 / 90 天不动（那是显式选择，不是默认值）', () async {
    for (final int days in <int>[7, 90]) {
      final InMemoryKeyValueStore store = _store(days);
      final bool changed = await migrateHistoryRetentionToNeverDelete(store);
      expect(changed, isFalse, reason: '$days 天不该被改');
      expect(_saved(store), days);
    }
  });

  test('只跑一次：迁移过之后，用户手动选回 30 天不会再被改掉', () async {
    final InMemoryKeyValueStore store = _store(0);
    await migrateHistoryRetentionToNeverDelete(store); // 第一次：已经是 0，只落版本号

    // 用户后来自己选了 30 天。
    await store.put(
      SettingsController.storageKey,
      const AppSettings(firstRunCompleted: true).copyWith(historyRetentionDays: 30).toJson(),
    );
    final bool changed = await migrateHistoryRetentionToNeverDelete(store);
    expect(changed, isFalse, reason: '版本号已经写过 → 不再动用户的设置');
    expect(_saved(store), 30);
  });

  test('盘上没有设置记录（首启）→ 不写设置、只落版本号', () async {
    final InMemoryKeyValueStore store = InMemoryKeyValueStore(<String, Object?>{});
    final bool changed = await migrateHistoryRetentionToNeverDelete(store);
    expect(changed, isFalse);
    expect(store.get(SettingsController.storageKey), isNull, reason: '不许替用户凭空造一份设置');
    expect(store.get(kHistoryRetentionMigrationKey), isTrue);
  });
}
