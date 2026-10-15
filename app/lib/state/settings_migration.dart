/// 设置的一次性迁移（第三十三轮）：**观看记录保留期：默认 30 天 → 不删除**。
///
/// 用户原话：「历史记录从默认30天改为不删」。
///
/// 为什么要迁移、为什么只动 30：
/// * 30 是**旧版的默认值**，绝大多数人从没主动选过它 —— 不改的话"新默认"对老用户不起作用；
/// * 7 / 90 是**显式选择**（设置里那四个档位里挑的），抹掉它们就是替用户做决定；
/// * 有版本号守卫（[kHistoryRetentionMigrationKey]），**只跑一次**：
///   跑过之后用户再手动选回 30 天，下次启动不会被我们改回去。
library;

import 'package:dsanima_core/sources/kv.dart' show KeyValueStore;

import 'providers.dart' show SettingsController;

/// 迁移只跑一次：这个键一旦为 true，永不再动用户的保留期设置。
const String kHistoryRetentionMigrationKey =
    'dsanima.migrated.history_never_delete';

/// 旧版默认保留天数（迁移的唯一目标值）。
const int kLegacyDefaultHistoryRetentionDays = 30;

/// 把"旧默认 30 天"改成"不删除"（0）。返回 true = 这次真的改了。
///
/// 直接改盘上那份设置 JSON（而不是反序列化整个 `AppSettings` 再写回）：
/// 迁移只碰一个字段，整个模型往返一次反而可能把别的字段的默认值/新字段搅进来。
Future<bool> migrateHistoryRetentionToNeverDelete(KeyValueStore store) async {
  if (store.get(kHistoryRetentionMigrationKey) == true) return false;

  bool changed = false;
  final Object? raw = store.get(SettingsController.storageKey);
  if (raw is Map) {
    final Map<String, Object?> settings = raw.cast<String, Object?>();
    final Object? days = settings['historyRetentionDays'];
    if (days is num && days.toInt() == kLegacyDefaultHistoryRetentionDays) {
      settings['historyRetentionDays'] = 0;
      await store.put(SettingsController.storageKey, settings);
      changed = true;
    }
  }
  await store.put(kHistoryRetentionMigrationKey, true);
  return changed;
}
