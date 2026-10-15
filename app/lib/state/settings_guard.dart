/// 设置页「有未保存的改动」的登记处（2026-10-12 第十六轮：手动保存）。
///
/// 用户原话：
/// > 「去除设置自动保存的逻辑，仅手动保存」
///
/// 为什么需要这么一个登记处：草稿的**唯一真相**在 `SettingsPage` 的 State 里
/// （`_draft` / `_baseline`），而"离开设置页"这件事有两个入口都不认识它 ——
/// * 切页：`ui/shell.dart` 的导航项与左下角那颗设置齿轮；
/// * 关窗：`state/window_close.dart` 的 `CloseCoordinator`（它只有 ProviderContainer）。
/// 页面在 `IndexedStack` 里一直活着、State 是私有的，所以让页面把自己登记进来，
/// 那两处只问一句 [resolveUnsavedSettings] 就行。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 能回答"设置页现在有未保存的改动吗"并处理它的人（唯一实现 = 设置页自己）。
class SettingsDraftGuard {
  const SettingsDraftGuard({required this.dirty, required this.resolve});

  /// 有未保存的改动吗。
  final bool Function() dirty;

  /// 弹一次三选（保存并生效 / 放弃改动 / 留在这）并真的执行。
  ///
  /// 返回 true = 可以离开（已保存或已放弃）；false = 留在设置页。
  final Future<bool> Function(BuildContext context) resolve;
}

/// 当前挂出来的处理器；**没打开过设置页时是 null**（那就没什么可拦的）。
final Provider<ValueNotifier<SettingsDraftGuard?>> settingsDraftGuardProvider =
    Provider<ValueNotifier<SettingsDraftGuard?>>((Ref ref) {
      final ValueNotifier<SettingsDraftGuard?> holder = ValueNotifier<SettingsDraftGuard?>(null);
      ref.onDispose(holder.dispose);
      return holder;
    });

/// 「要离开设置页了，先问一句」：没有未保存的改动（或设置页根本没挂出来）→ 直接放行。
///
/// [context] 为 null（或已卸载）时**放行**：拿不到界面就没法问，此时把用户困在
/// "关不掉的窗口"里比丢一次未保存的改动更糟。
Future<bool> resolveUnsavedSettings(
  ValueNotifier<SettingsDraftGuard?> holder,
  BuildContext? context,
) async {
  final SettingsDraftGuard? guard = holder.value;
  if (guard == null || !guard.dirty()) return true;
  if (context == null || !context.mounted) return true;
  return guard.resolve(context);
}
