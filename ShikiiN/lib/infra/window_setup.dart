import 'package:flutter/material.dart' show Colors, Offset, Rect, Size;
import 'package:window_manager/window_manager.dart';

/// 初始化窗口。宿主可覆盖初始尺寸、最小/最大尺寸与初始位置（契约 §1）：
/// 不传尺寸则仍是 1100×680 / 最小 640×400。
///
/// [position]（逻辑像素，桌面坐标）：**必须**在 `show()` 之前落位。
/// 多窗口宿主（DSAnima 的弹出播放窗口）用它把播放窗口放到位 —— 用户 2026-10-12
/// 要的是**工作区正中**（原话「播放器应该在中心位置出现」），所以宿主要么不传
/// （走下面的 `center: true`）、要么传一个自己算好的居中矩形（多显示器时才需要）。
/// 不传位置时的默认行为就是居中，别在这里改成别的落点。
///
/// [maxSize] / [maximizable]：给窗口封顶 / 禁掉原生最大化。
/// 用户 2026-10-11 第四次报（原话）：
/// > 然后就是一直修不好的开启播放器后，整个程序都不能用了，什么都点不了整个 DSanime。
/// 真机日志坐实：播放窗口自己报回来的几何是 `-7,-7 2062x1246`（工作区 2048×1232）——
/// 它**被最大化了**，铺满整屏，主窗口 100% 被盖住。所以无边框弹窗不该有原生最大化：
/// [maximizable] = false 去掉 `WS_MAXIMIZEBOX`（拖到屏幕顶边的 Aero Snap 也一起失效）。
///
/// ⚠️ **[maxSize] 请慎用：它会连"真全屏"一起夹死**（2026-10-11 第五轮实测）。
/// 它走 `setMaximumSize` → 原生 `WM_GETMINMAXINFO` 的 `ptMaxTrackSize`，而
/// `ptMaxTrackSize` **不只管用户拖边框与最大化，它会连 `SetWindowPos` 一起夹**
/// （实测：`ptMaxTrackSize=462x260` 的窗口执行 `SetWindowPos(0,0,2560,1440)` 之后
/// 仍然是 462×260）。而"真全屏"恰恰就是 `SetWindowPos` 到显示器尺寸
/// （`window_manager` 的 `SetFullScreen`）—— 于是全屏 / 双击画面 / 拖右边框拉宽
/// 全部失效、窗口被锁死在开窗尺寸上（DSAnima 用户报的
/// 「播放器全屏不了的 bug，无法……右边拉伸」就是它）。
/// DSAnima 因此**不再传**这个参数："不盖住主窗口"改由 [maximizable]=false +
/// 宿主收到最大化事件后立刻退回两层兜底（两层都不碰窗口尺寸）。
/// 宿主若确实要限制大小，先想清楚这个夹取会不会把它的全屏/拖边框一起夹掉。
Future<void> setupWindow({
  Size? size,
  Size? minSize,
  Size? maxSize,
  bool maximizable = true,
  Offset? position,
}) async {
  final Size effectiveSize = size ?? const Size(1100, 680);
  await windowManager.ensureInitialized();
  final options = WindowOptions(
    size: effectiveSize,
    minimumSize: minSize ?? const Size(640, 400),
    maximumSize: maxSize,
    center: true,
    backgroundColor: Colors.transparent,
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );
  // `waitUntilReadyToShow` 期间窗口是隐藏的：位置在这里落定，用户看到的第一帧
  // 就已经在正确位置上（不会"居中闪一下再跳走"）。
  await windowManager.waitUntilReadyToShow(options);
  final Offset? at = position;
  if (at != null) {
    await windowManager.setBounds(
      Rect.fromLTWH(at.dx, at.dy, effectiveSize.width, effectiveSize.height),
    );
  }
  if (!maximizable) {
    try {
      await windowManager.setMaximizable(false);
    } catch (_) {
      // 禁不掉也不让它挡住开窗：上限（maxSize）那道防线还在。
    }
  }
  await windowManager.show();
  await windowManager.focus();
}
