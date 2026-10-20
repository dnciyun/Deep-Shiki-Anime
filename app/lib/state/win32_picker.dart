/// 桌面选择器：**目录**用自己实现的 Win32 对话框，**文件**仍走 `file_picker`。
///
/// ## 为什么不再用 `file_picker` 的 `getDirectoryPath`
///
/// 用户 2026-10-20：「刚选完会闪退一下」。
///
/// 证据（Windows 事件查看器 · Application · Id=1000）：
/// ```
/// 2026/10/20 3:38:20  出错模块 comdlg32.dll  异常代码 0xc0000005  偏移 0x4f82
/// ```
/// 时间点正好是「选完文件夹」的那一刻（`DSAnima-data/logs` 里那次进程在 3:38:06 启动、
/// 3:38:20 死掉，紧接着 3:38:24 是用户重新点开的那一次）。
///
/// `file_picker` 8.0.0 的 Windows `getDirectoryPath` 是**在 UI 线程上直接**跑的，
/// 而且它自己 `CoInitializeEx` / `CoUninitialize` 之后**既不 release 那个 `IFileOpenDialog`、
/// 也不释放 `getDisplayName` 用 CoTaskMemAlloc 出来的路径**。UI 线程的 COM 是
/// `windows/runner/main.cpp` 里 `CoInitializeEx(APARTMENTTHREADED)` 建起来的 ——
/// 在那上面反复初始/反初始化 + 遗留未释放的 COM 对象，就会在**对话框关闭之后**
/// 于 comdlg32 里踩空。
///
/// 现在这条路：
/// 1. **在单独的 isolate 里弹**（就是 `file_picker` 的 `pickFiles` 用的那套做法，
///    那条路在本机一直是好的）：COM 是那个线程自己的，用完就 `CoUninitialize`，
///    不会动到 UI 线程的公寓；
/// 2. **每个 COM 对象都 release、每个 CoTaskMemAlloc 出来的字符串都 CoTaskMemFree**
///    （`getDisplayName` 的返回值按 MSDN 必须 `CoTaskMemFree`）；
/// 3. `CoInitializeEx` 与 `CoUninitialize` 严格配对；
/// 4. 失败如实抛 [PortUnavailableException]，页面退回「手动输入路径」。
///
/// 为什么 `IFileDialog::Show` 要自己绑 vtable：`win32` 5.15.0 生成的 `IFileDialog`
/// 里**没有** `Show`（vtable 第 3 槽），而它是唯一必须的方法。
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../domain/ports.dart';
import 'hive_store.dart' show FilePickerPort;

/// 一次「选文件夹」的结果：要么 [path]，要么 [error]（也可能是"用户取消"= 两者都空）。
typedef FolderDialogResult = ({String? path, String? error});

/// 可注入的"弹对话框"函数闭包（测试用假实现，真机用 [win32FolderDialog]）。
typedef FolderDialog = Future<FolderDialogResult> Function({String? title});

/// 弹出系统「选择文件夹」对话框（Windows，modal，自己弹自己的消息循环）。
Future<FolderDialogResult> win32FolderDialog({String? title}) async {
  final ReceivePort port = ReceivePort();
  try {
    await Isolate.spawn<Object?>(
      _folderDialogIsolate,
      <Object?>[port.sendPort, title],
    );
    final Object? raw = await port.first;
    if (raw is Map) {
      return (path: raw['path'] as String?, error: raw['error'] as String?);
    }
    return (path: null, error: '选择器返回了看不懂的结果：$raw');
  } catch (error) {
    return (path: null, error: '$error');
  } finally {
    port.close();
  }
}

/// isolate 入口：拿一个全新的线程，COM 在那个线程上自生自灭。
void _folderDialogIsolate(Object? args) {
  final List<Object?> list = args! as List<Object?>;
  final SendPort port = list[0]! as SendPort;
  final String? title = list[1] as String?;

  final int hrInit = CoInitializeEx(
    nullptr,
    COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE,
  );
  if (hrInit < 0) {
    Isolate.exit(port, <String, String?>{
      'error': 'COM 初始化失败：0x${hrInit.toRadixString(16)}',
    });
  }

  String? path;
  String? error;
  FileOpenDialog? dialog;
  try {
    dialog = FileOpenDialog.createInstance();
    final Pointer<Uint32> options = calloc<Uint32>();
    try {
      _check(dialog.getOptions(options));
      _check(
        dialog.setOptions(
          options.value |
              FOS_PICKFOLDERS |
              FOS_FORCEFILESYSTEM |
              FOS_NOCHANGEDIR,
        ),
      );
    } finally {
      free(options);
    }
    final String name = (title ?? '').trim();
    if (name.isNotEmpty) {
      final Pointer<Utf16> text = TEXT(name);
      try {
        _check(dialog.setTitle(text));
      } finally {
        free(text);
      }
    }
    final int hrShow = _show(dialog);
    if (hrShow == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
      path = null; // 用户按了取消，不是错误
    } else {
      _check(hrShow);
      path = _readPath(dialog);
    }
  } catch (e) {
    error = '$e';
  } finally {
    // 顺序要紧：先放 COM 对象，再反初始化这个线程的公寓。
    if (dialog != null) {
      try {
        dialog.release();
      } catch (_) {
        // release 失败只影响这一线程的清理，不该盖住真实错误。
      }
    }
    CoUninitialize();
  }
  Isolate.exit(port, <String, String?>{'path': ?path, 'error': ?error});
}

/// `IFileDialog::Show(HWND)` —— vtable 第 3 槽（win32 5.15.0 没生成这个方法）。
///
/// HWND 是**指针大小**的整数：用 `IntPtr` 传，0 = 没有 owner（与 `file_picker`
/// 的默认行为一致；没有 owner 也不会被主窗口吞掉，对话框自己会置前）。
int _show(IFileDialog dialog) => (dialog.ptr.ref.vtable + 3)
    .cast<Pointer<NativeFunction<Int32 Function(Pointer, IntPtr)>>>()
    .value
    .asFunction<int Function(Pointer, int)>()(dialog.ptr.ref.lpVtbl, 0);

/// `IFileDialog::GetResult` 拿到的 `IShellItem` → 文件系统路径。
String _readPath(IFileDialog dialog) {
  final Pointer<Pointer<COMObject>> ppItem = calloc<Pointer<COMObject>>();
  try {
    _check(dialog.getResult(ppItem));
    final Pointer<COMObject> itemPtr = ppItem.value;
    if (itemPtr == nullptr) {
      throw WindowsException(0x80004005); // E_FAIL
    }
    final IShellItem item = IShellItem(itemPtr);
    final Pointer<Pointer<Utf16>> pPath = calloc<Pointer<Utf16>>();
    try {
      _check(item.getDisplayName(SIGDN_FILESYSPATH, pPath));
      final String path = pPath.value.toDartString();
      // MSDN：getDisplayName 返回的字符串是 CoTaskMemAlloc 的，调用方必须
      // CoTaskMemFree —— file_picker 8.0.0 这里漏了（每次选目录泄漏一次）。
      CoTaskMemFree(pPath.value.cast<Void>());
      return path;
    } finally {
      free(pPath);
    }
  } finally {
    if (ppItem.value != nullptr) {
      try {
        IShellItem(ppItem.value).release();
      } catch (_) {
        // 同上：清理失败不盖住真实错误。
      }
    }
    free(ppItem);
  }
}

void _check(int hr) {
  if (hr < 0) throw WindowsException(hr);
}

/// 桌面选择器端口：目录走 Win32 对话框，文件仍交给 `file_picker`。
///
/// 文件那条路不动：`file_picker` 的 `pickFiles` 本来就在**它自己 spawn 的 isolate** 里跑
/// （本机一直正常），而目录那条是在 UI 线程上直接跑的 —— 出事的正是后者。
class DsDesktopPicker implements PickerPort {
  const DsDesktopPicker({
    this.folderDialog = win32FolderDialog,
    this.filePicker = const FilePickerPort(),
  });

  /// 弹目录对话框（测试注入假实现：真机打不开原生对话框）。
  final FolderDialog folderDialog;

  /// 选文件的实际实现（`file_picker`）。
  final PickerPort filePicker;

  @override
  Future<String?> pickDirectory({String? title}) async {
    final FolderDialogResult result = await folderDialog(title: title);
    final String? error = result.error;
    if (error != null) {
      // 让页面走「手动输入路径」那条兜底（`local_page.dart` 认这个异常）。
      throw PortUnavailableException('系统目录选择器打不开', hint: error);
    }
    final String path = (result.path ?? '').trim();
    return path.isEmpty ? null : path;
  }

  @override
  Future<String?> pickFile({
    String? title,
    List<String> extensions = const <String>[],
  }) => filePicker.pickFile(title: title, extensions: extensions);
}
