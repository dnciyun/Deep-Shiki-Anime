import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// 关闭本窗口的 DWM 过渡动画：最大化/还原/全屏切换瞬时无动画，消除「顿感」。
/// 平台/FFI 异常一律静默（非 Windows、拿不到窗口句柄等都不致命）。
void disableWindowTransitions() {
  try {
    // ShikiiN runner 的专属窗口类名，须与 windows/runner/win32_window.cpp 的
    // kWindowClassName 保持一致。
    final cls = 'SHIKIIN_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    int hwnd;
    try {
      hwnd = FindWindow(cls, nullptr);
    } finally {
      malloc.free(cls);
    }
    if (hwnd == 0) hwnd = GetForegroundWindow(); // 兜底：取前台窗口
    if (hwnd == 0) return;

    const dwmwaTransitionsForceDisabled = 3; // DWMWA_TRANSITIONS_FORCEDISABLED
    final pv = malloc<Int32>()..value = 1; // TRUE
    try {
      DwmSetWindowAttribute(hwnd, dwmwaTransitionsForceDisabled, pv, sizeOf<Int32>());
    } finally {
      malloc.free(pv);
    }
  } catch (_) {/* 非致命 */}
}
