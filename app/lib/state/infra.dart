/// 最底层注入点（存储 / 支持目录 / 选择器 / 托盘 / 通知 / 磁盘探测）。
///
/// 单独成文件是为了避免 `providers.dart` 与 `host_store.dart` 互相 import：
/// 两边都只依赖这里的 provider，`providers.dart` 再 re-export 出去，
/// 所以业务代码仍然只 import `state/providers.dart`。
library;

import 'dart:io';

import 'package:dsanima_core/sources/kv.dart' show KeyValueStore;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/disk_space.dart';
import '../domain/ports.dart';
import '../domain/unavailable.dart';

/// 键值持久化（core 的 `KeyValueStore`，宿主提供 Hive 实现）。**必须注入**。
final Provider<KeyValueStore> keyValueStoreProvider = Provider<KeyValueStore>(
  (Ref ref) => throw StateError(
      'keyValueStoreProvider 未注入：main.dart 注入 HiveKeyValueStore，测试注入 InMemoryKeyValueStore'),
);

/// 应用支持目录（引擎状态目录、日志、缓存都挂在它下面）。
final Provider<Directory?> supportDirProvider =
    Provider<Directory?>((Ref ref) => null);

/// 目录/文件选择器（真实实现在 main.dart 注入 `FilePickerPort`）。
final Provider<PickerPort> pickerPortProvider =
    Provider<PickerPort>((Ref ref) => const UnavailablePickerPort());

/// 系统托盘（spec §7.3 Q14）。未注入时「后台常驻」不可用，设置页会明确说明。
final Provider<TrayPort> trayPortProvider =
    Provider<TrayPort>((Ref ref) => const UnavailableTrayPort());

/// 系统通知（spec §7.3 Q16）。未注入时只记录事件、不弹系统通知。
final Provider<NotificationPort> notificationPortProvider =
    Provider<NotificationPort>((Ref ref) => const UnavailableNotificationPort());

/// 封面图本地缓存（spec §7.5/§7.6，真实实现 `HttpCoverCache` 由 main.dart 注入）。
/// 未注入/测试注入假实现 → 封面降级成灰框，**不联网**。
final Provider<CoverCachePort> coverCacheProvider =
    Provider<CoverCachePort>((Ref ref) => const UnavailableCoverCachePort());

/// 磁盘剩余空间探测（底部状态条）。
final Provider<DiskSpaceProbe> diskSpaceProbeProvider =
    Provider<DiskSpaceProbe>((Ref ref) => DiskSpaceProbe());
