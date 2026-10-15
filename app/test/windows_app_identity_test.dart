/// Windows「应用身份」写入的测试（2026-10-12 第十七轮 · 播放窗口任务栏图标）。
///
/// 这一层是 COM/FFI，**可见效果**（任务栏那一格从系统默认白纸变成我们那张图标）靠
/// `build/probe-ui-r17/` 的实拍验证；这里钉的是两件能在这里钉住的事：
/// 1. 拿一个**真窗口**（预定义类 `STATIC`，不用注册）走完整条路 → true
///    （回归价值：`SHGetPropertyStoreForWindow` 的签名、IID、PROPERTYKEY / PROPVARIANT
///    的搭法，任何一处写错都只会得到 false）；
/// 2. 无效窗口一律 false 且**不崩**（`IsWindow` 那道校验就是为它加的，见模块头注释）。
library;

import 'dart:ffi';

import 'package:dsanima/domain/windows_app_identity.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _CreateWindowExWNative = IntPtr Function(
  Uint32 exStyle,
  Pointer<Utf16> className,
  Pointer<Utf16> windowName,
  Uint32 style,
  Int32 x,
  Int32 y,
  Int32 width,
  Int32 height,
  IntPtr parent,
  IntPtr menu,
  IntPtr instance,
  IntPtr param,
);
typedef _CreateWindowExWDart = int Function(
  int exStyle,
  Pointer<Utf16> className,
  Pointer<Utf16> windowName,
  int style,
  int x,
  int y,
  int width,
  int height,
  int parent,
  int menu,
  int instance,
  int param,
);
typedef _DestroyWindowNative = Int32 Function(IntPtr hwnd);
typedef _DestroyWindowDart = int Function(int hwnd);

/// 造一个真窗口当"播放窗口"用（预定义类不需要注册）。
int _createTestWindow() {
  final DynamicLibrary user32 = DynamicLibrary.open('user32.dll');
  final _CreateWindowExWDart create = user32
      .lookupFunction<_CreateWindowExWNative, _CreateWindowExWDart>('CreateWindowExW');
  final Pointer<Utf16> cls = 'STATIC'.toNativeUtf16();
  final Pointer<Utf16> title = 'dsanima-app-identity-test'.toNativeUtf16();
  try {
    // WS_OVERLAPPEDWINDOW = 0x00CF0000
    return create(0, cls, title, 0x00CF0000, 0, 0, 40, 40, 0, 0, 0, 0);
  } finally {
    malloc.free(cls);
    malloc.free(title);
  }
}

void _destroyTestWindow(int hwnd) =>
    DynamicLibrary.open('user32.dll')
        .lookupFunction<_DestroyWindowNative, _DestroyWindowDart>('DestroyWindow')(hwnd);

void main() {
  test('真窗口：三个属性都写得进去（返回 true）', () {
    final int hwnd = _createTestWindow();
    expect(hwnd, isNonZero, reason: '拿不到测试窗口');
    addTearDown(() => _destroyTestWindow(hwnd));

    final bool ok = applyWindowsAppIdentity(
      windowHandle: hwnd,
      relaunchCommand: r'C:\nonexistent\dsanima.exe',
      relaunchIconResource: r'C:\nonexistent\dsanima.exe,0',
    );
    expect(ok, isTrue, reason: '真窗口上整条 COM 路径必须走通');
  });

  test('HWND = 0 → false，不抛（没窗口时不许炸）', () {
    expect(
      applyWindowsAppIdentity(
        windowHandle: 0,
        relaunchCommand: r'C:\nonexistent\dsanima.exe',
      ),
      isFalse,
    );
  });

  test('不是窗口的句柄 → false，不抛、不崩（IsWindow 那道校验）', () {
    expect(
      applyWindowsAppIdentity(
        windowHandle: 0x1234,
        relaunchCommand: r'C:\nonexistent\dsanima.exe',
      ),
      isFalse,
    );
  });
}
