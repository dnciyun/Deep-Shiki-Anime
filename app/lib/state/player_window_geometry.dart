/// 播放窗口的落点与"记住用户拖到哪儿"（用户 2026-10-12 第七轮修正）。
///
/// 两个来源，优先级从高到低：
/// 1. **用户上次自己拖出来的位置/大小**（落盘在宿主 KV 里，子窗口每次移动/改大小都会报回来）；
/// 2. 按工作区**居中**算一个默认落点（`domain/window_placement.dart` 的
///    [centeredPlayerWindowBounds]，纯函数、有单测）。
///
/// ⚠️ 这里**不再动主窗口**。原来主窗口铺满工作区时会先 `unmaximize()` 给它腾地方，
/// 用户 2026-10-12 报的「点开播放后为什么会取消主窗口的最大化」就是那一步 ——
/// 那是用户自己的窗口状态，播放这条路不该顺手改掉。落点改成居中之后，"腾地方"也没必要了。
///
/// 只 import 装配根能碰的东西（`window_manager` / `screen_retriever`）——
/// UI 与 state 层不碰插件。
library;

import 'package:dsanima_core/sources/kv.dart' show KeyValueStore;
import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../domain/window_placement.dart';

/// 落盘键：`{left, top, width, height}`（逻辑像素）。
///
/// **`.v2`**：v1 里躺着的多半是第六轮之前"被挤到主窗口旁边那条 462×260 空地"的矩形 ——
/// 用户 2026-10-12 要求播放器居中弹出，继续尊重那条记录就会永远开在角落里。
/// 换键等于把旧记录一次性作废（不删用户数据，只是不再读它），下一版还能再换。
const String kPlayerWindowBoundsKey = 'dsanima.player_window_bounds.v2';

/// 读回用户上次的位置；没有/坏了返回 null（坏了就重新算，不让一条坏记录卡住播放）。
Rect? storedPlayerWindowBounds(KeyValueStore store) {
  final Object? raw = store.get(kPlayerWindowBoundsKey);
  if (raw is! Map) return null;
  return _rectOf(raw);
}

/// 记住用户拖出来的位置/大小。
Future<void> savePlayerWindowBounds(KeyValueStore store, Rect rect) =>
    store.put(kPlayerWindowBoundsKey, <String, Object?>{
      'left': rect.left,
      'top': rect.top,
      'width': rect.width,
      'height': rect.height,
    });

/// 开窗那一次该把播放窗口放哪儿（逻辑像素）；null = 交给插件默认（居中）。
///
/// 任何一步失败都返回 null（退回默认居中），**绝不因为"算位置"把播放挡住**；
/// 但失败原因必须写进日志（[log]）—— 落点悄悄失效过一次，只能靠日志定位。
Future<Rect?> resolvePlayerWindowBounds(
  KeyValueStore store, {
  void Function(String message)? log,
}) async {
  final PlayerWindowPlan? plan = await playerWindowPlan(store, log: log);
  return plan?.bounds;
}

/// 开窗计划：落点（**没有尺寸上限** —— 那把锁会把全屏和拖右边框一起夹死，
/// 原因见 `domain/window_placement.dart` 里 `playerWindowMaxSize` 被删掉的那段长注释）。
///
/// 用户拖过的位置优先，但要过 [reusableSavedBounds] 两条否决线（工作区内 + 不太小）；
/// 没有可用记录就按工作区居中算一个（用户 2026-10-12：「播放器应该在中心位置出现」）。
Future<PlayerWindowPlan?> playerWindowPlan(
  KeyValueStore store, {
  void Function(String message)? log,
}) async {
  final Rect? saved = storedPlayerWindowBounds(store);
  try {
    final Rect main = await windowManager.getBounds();
    final Rect area = await _workAreaOfMain(main);
    final bool useSaved =
        saved != null && reusableSavedBounds(saved: saved, workArea: area);
    if (saved != null && !useSaved) {
      log?.call('落点：记住的位置 ${_fmt(saved)} 不能用（超出工作区/太小）→ 重新算');
    }
    final Rect box =
        useSaved ? saved : centeredPlayerWindowBounds(workArea: area);
    log?.call(
      '落点：主窗口 ${_fmt(main)}，工作区 ${_fmt(area)} '
      '→ 播放窗口 ${_fmt(box)}（${useSaved ? '用记住的位置' : '居中'}）',
    );
    return PlayerWindowPlan(bounds: box);
  } catch (error) {
    log?.call('落点计算失败（退回默认居中）：$error');
    return saved == null ? null : PlayerWindowPlan(bounds: saved);
  }
}

/// 主窗口中心点所在显示器的工作区。
Future<Rect> _workAreaOfMain(Rect main) async {
  final List<Display> displays = await screenRetriever.getAllDisplays();
  return _workAreaOf(displays, main.center);
}

String _fmt(Rect r) =>
    '${r.left.toStringAsFixed(0)},${r.top.toStringAsFixed(0)} '
    '${r.width.toStringAsFixed(0)}x${r.height.toStringAsFixed(0)}';

/// 主窗口中心点落在哪块显示器上，就用那块的工作区（多显示器：副屏主窗口时
/// 播放窗口不会被放到主屏去）。
Rect _workAreaOf(List<Display> displays, Offset point) {
  return workAreaFor(
    <({Offset position, Size size})>[
      for (final Display d in displays)
        (
          position: d.visiblePosition ?? Offset.zero,
          size: d.visibleSize ?? d.size,
        ),
    ],
    point,
  );
}

Rect? _rectOf(Map<dynamic, dynamic> map) {
  double? value(Object? v) => v is num ? v.toDouble() : null;
  final double? left = value(map['left']);
  final double? top = value(map['top']);
  final double? width = value(map['width']);
  final double? height = value(map['height']);
  if (left == null || top == null || width == null || height == null) return null;
  if (width < 200 || height < 100) return null; // 明显坏掉的记录：当作没有
  return Rect.fromLTWH(left, top, width, height);
}
