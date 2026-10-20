/// 侧栏「插件」收纳组的展开/收起（2026-10-20 用户：「在侧边栏做一个收纳按钮，点开后
/// 展开插件的功能，不然侧边栏会越做越多」）。
///
/// 为什么要持久化：这是**布局偏好**，不是每次启动都要重挑一次的动作。收起来的意图是
/// "我平时不用这几页，别占我侧栏"，重启后又自己弹开会很烦。
///
/// 为什么放 KV 而不是 `AppSettings` / 设置页：
/// * 设置页（`SettingsPage`）是**手动保存**的（改完点保存才生效、切页还会弹三选）；
///   把"点一下折叠"这种即时动作塞进去，用户点开折叠再切页会被拦一次「未保存」——荒谬；
/// * `AppSettings` 是引擎/播放那套要紧配置的载体（`applier` 会据此重启边车等），
///   一个 UI 折叠状态不该跟它同命运；
/// * 与「本地」页的文件夹清单（`dsanima.local.folders`）同一套做法：小偏好直接进 KV。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'infra.dart' show keyValueStoreProvider;

/// KV 键。默认（键不存在）= 收起。
const String kPluginGroupExpandedKey = 'dsanima.shell.plugins.expanded';

/// 「插件」组是否展开。
class PluginGroupController extends Notifier<bool> {
  @override
  bool build() {
    // 同步读（Hive `Box.get` 也是同步的）：侧栏第一帧就要按真实状态画，
    // 否则会先画一帧"收起"再跳成"展开"，看着像闪一下。
    final Object? raw = ref.watch(keyValueStoreProvider).get(kPluginGroupExpandedKey);
    return raw is bool && raw;
  }

  /// 展开/收起并落盘。
  ///
  /// 顺序是**先写盘成功再改内存**（与 `LastPlaybackController.save` 同一口径）：
  /// 反过来的话写失败会让界面以为"已经记住了"，重启又变回去 —— 用户只会觉得这按钮时灵时不灵。
  Future<void> setExpanded(bool expanded) async {
    if (state == expanded) return;
    try {
      await ref.read(keyValueStoreProvider).put(kPluginGroupExpandedKey, expanded);
      state = expanded;
    } catch (error) {
      // 存不下就退化成"只在本次生效"：折叠本身不该因为写盘失败而点不动。
      state = expanded;
    }
  }

  Future<void> toggle() => setExpanded(!state);
}

final NotifierProvider<PluginGroupController, bool> pluginGroupExpandedProvider =
    NotifierProvider<PluginGroupController, bool>(PluginGroupController.new);
