/// 给窗口写「应用身份」（AppUserModelID + 重启命令 + 重启图标）。
///
/// 为什么需要它（2026-10-12 第十七轮 · 用户报「播放器的图标是白纸了」）：
/// 播放子窗口是 `desktop_multi_window` 用 `CreateWindowEx` 建的，它**没有应用身份**
/// （窗口的 `PKEY_AppUserModel_ID` 是空的），而 Windows 11 的任务栏按钮**不是**
/// "读窗口图标"那么直接 —— 真机把三处都量过：
/// * `WM_GETICON`(ICON_BIG / ICON_SMALL2) 都设成我们那张图标 → 任务栏那一格仍是**系统默认白纸**；
/// * 窗口类图标（`GCLP_HICON` / `GCLP_HICONSM`）本来就是对的 → 也没用；
/// * 同一个进程的**主窗口**（Flutter runner 自己建的类）反倒一直是正确图标。
///
/// 反过来的实验证实了真因：给这个窗口写上 AUMID + `RelaunchCommand` /
/// `RelaunchIconResource` 指向 `dsanima.exe` 之后，**同一格立刻变成 exe 的图标**
/// （`build/probe-ui-r17/` 里有前后两张实拍：白纸 → 猫图；按钮名字也从产品名
/// `DSAnima` 变成 exe 名 `dsanima`）。上游同类问题一直没修：
/// <https://github.com/MixinNetwork/flutter-plugins/issues/432>（"Secondary window does
/// not use the app's icon on windows"，只有一句 "same problem"）。
///
/// 实现走 `package:win32` 的 `IPropertyStore`（`state/recycle_bin.dart` 用同一个包），
/// 只有 `SHGetPropertyStoreForWindow` 这个函数 win32 没生成，自己 FFI 查一次 ——
/// **不新增任何原生代码/插件**，所以主窗口与播放子窗口两个引擎里都能直接用。
///
/// ⚠️ 调用前必须确认这真的是一个**活着的窗口**（`IsWindow`）：`SHGetPropertyStoreForWindow`
/// 拿到无效 HWND 时可能仍然返回成功，之后按 vtable 去调 `SetValue` 就是一次访问违例
/// —— 那是**整个进程**崩掉（实测：传 0x1234 直接把测试 isolate 干掉）。真机里
/// `windowManager.getId()` 也可能在同一毫秒里过期，所以这道校验留在生产路径上。
///
/// 失败一律**静默**（返回 false）：图标不好看绝不能挡住开窗。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// `PKEY_AppUserModel_*` 的公共 GUID（`9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3`）。
const String kAppUserModelKeyFmtid = '9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3';

/// win32 的 `GUID.setGUID` 走 `Guid.parse`，**要求带花括号**（不带会直接断言失败）。
const String _appUserModelKeyFmtidBraced = '{$kAppUserModelKeyFmtid}';

// PKEY_AppUserModel_* 的 pid（propsys.h 里写死的序号）。
const int _pidRelaunchCommand = 2;
const int _pidRelaunchIconResource = 3;
const int _pidAppUserModelId = 5;

typedef _IsWindowNative = Int32 Function(IntPtr hwnd);
typedef _IsWindowDart = int Function(int hwnd);

typedef _ShGetPropertyStoreForWindowNative = Int32 Function(
  IntPtr hwnd,
  Pointer<GUID> riid,
  Pointer<Pointer<IntPtr>> propertyStore,
);
typedef _ShGetPropertyStoreForWindowDart = int Function(
  int hwnd,
  Pointer<GUID> riid,
  Pointer<Pointer<IntPtr>> propertyStore,
);

/// 给 [windowHandle]（HWND）写应用身份；成功返回 true。
///
/// * [relaunchCommand]：一般是进程自己的 exe 路径（`Platform.resolvedExecutable`）；
/// * [relaunchIconResource]：`<exe 路径>,<图标序号>`，默认用 exe 的第 0 个图标；
/// * [appId]：这个窗口的应用身份字符串（与主窗口不同也没关系 —— 实测任务栏会按
///   重启命令去解析出 exe 的名字与图标）。
///
/// 任何一步失败（非 Windows / HWND 无效 / COM 拒绝）都返回 false，**不抛异常**。
bool applyWindowsAppIdentity({
  required int windowHandle,
  required String relaunchCommand,
  String? relaunchIconResource,
  String appId = 'DSAnima.Player',
}) {
  if (!Platform.isWindows || windowHandle == 0) return false;
  try {
    final _IsWindowDart isWindow = DynamicLibrary.open('user32.dll')
        .lookupFunction<_IsWindowNative, _IsWindowDart>('IsWindow');
    if (isWindow(windowHandle) == 0) return false;

    final _ShGetPropertyStoreForWindowDart getStore =
        DynamicLibrary.open('shell32.dll').lookupFunction<
            _ShGetPropertyStoreForWindowNative,
            _ShGetPropertyStoreForWindowDart>('SHGetPropertyStoreForWindow');

    // COM 已经初始化过（本线程是 STA/MTA）时这里返回 S_FALSE / RPC_E_CHANGED_MODE，
    // 都无所谓 —— 只要不是"没初始化"，后面那些调用就能走。
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    final Pointer<GUID> iid = convertToIID(IID_IPropertyStore);
    // ⚠️ 这块内存**归 `IPropertyStore` 的 finalizer 管**（它会 release + free），
    // 所以既不要自己 free，也不要再调 `release()`（那是第二次减引用）。
    final Pointer<COMObject> object = calloc<COMObject>();
    final int hr = getStore(windowHandle, iid, object.cast<Pointer<IntPtr>>());
    free(iid);
    if (hr != 0 || object.ref.isNull) return false;

    final IPropertyStore store = IPropertyStore(object);
    bool ok = true;
    void write(int pid, String value) {
      final Pointer<PROPERTYKEY> key = calloc<PROPERTYKEY>();
      final Pointer<PROPVARIANT> variant = calloc<PROPVARIANT>();
      final Pointer<Utf16> text = value.toNativeUtf16();
      try {
        key.ref.fmtid.setGUID(_appUserModelKeyFmtidBraced);
        key.ref.pid = pid;
        // `vt` / `pwszVal` 是 win32 给 PROPVARIANT 那层 union 加的扩展 getter/setter，
        // 挂在**解引用后的结构体**上（不是 Pointer 上）。
        variant.ref.vt = VT_LPWSTR;
        variant.ref.pwszVal = text;
        if (store.setValue(key, variant) != S_OK) ok = false;
      } catch (_) {
        // 单个属性写不进去（例如系统不认这个 pid）不该影响另外两个。
        ok = false;
      } finally {
        free(text);
        free(variant);
        free(key);
      }
    }

    write(_pidRelaunchCommand, relaunchCommand);
    write(_pidRelaunchIconResource, relaunchIconResource ?? '$relaunchCommand,0');
    write(_pidAppUserModelId, appId);
    if (store.commit() != S_OK) ok = false;
    return ok;
  } catch (_) {
    return false;
  }
}
