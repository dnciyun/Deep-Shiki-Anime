/// 「打开所在文件夹」（用户 2026-10-12 第十四轮：「已完成的可跳转文件夹位置」）。
///
/// ## 第十七轮修掉的缺陷：`/select,` 遇到**带空格**的路径会开到「文档」去
///
/// 用户原话：「已完成里点打开文件夹会跳到文档文件夹内而不是视频位置」。
///
/// 真机 A/B（`build/probe-reveal/`，同一个函数、两条路径）：
/// * `F:\…\probe-reveal\NoSpace.mp4` → 正确打开 `probe-reveal`；
/// * `F:\…\probe-reveal\With Space.mp4` → **打开「文档」**。
///
/// 真因不是路径算错了，而是**资源管理器的命令行解析**：老实现调
/// `Process.start('explorer.exe', ['/select,<绝对路径>'])`，而 Dart 在 Windows 上会
/// 给**含空格的参数整体加引号**（`"/select,C:\…\With Space.mp4"`）。资源管理器是靠
/// 命令行**逐 token** 认 `/select,` 这个开关的 —— 整体被引号包住之后它不再把开头当开关，
/// 于是整条参数变成一个它解析不了的"路径"，**回落到它自己的默认目录（文档）**。
/// 番剧文件名几乎都带空格，所以用户那边是"每次都跳文档"。
///
/// 现在的做法（两段，都不依赖命令行解析）：
/// 1. 要**选中**那个文件时走 `SHOpenFolderAndSelectItems`（Windows 专门为这件事提供的
///    接口，没有命令行参与）—— 失败就退到第 2 步；
/// 2. 退路是**打开所在目录**：`explorer.exe <绝对目录>`。这里传的是普通路径参数，
///    带空格也只是被正常加引号（这正是资源管理器文档里的常规用法）。
///
/// 交给资源管理器的东西有两条硬约束（都是这次缺陷的直接教训，单测盯着）：
/// * **一律绝对路径**：相对路径会被资源管理器按**它自己的**工作目录解析，
///   落到哪儿完全不可控（`explorer.exe .` 实测打开的是调用方的工作目录）；
/// * **目标必须存在**（文件、或往上找到的最近一个还存在的目录）。文件被外部删掉时
///   打开它所在的那一级，而不是把不存在的路径丢给资源管理器。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// 一个"在资源管理器里定位文件"的实现（可注入：测试里换成记录器）。
typedef RevealInExplorer = Future<void> Function(String path);

/// 交给资源管理器之前算出来的落点（[revealTargetFor] 的产物）。
///
/// * [folder]：要打开的目录（**绝对路径、且一定存在**）；
/// * [select]：要顺便选中的那个条目（文件/目录；不存在时为 null）。
class RevealTarget {
  const RevealTarget({required this.folder, this.select});

  final String folder;
  final String? select;

  @override
  String toString() => 'RevealTarget(folder=$folder, select=$select)';
}

/// 解析落点；拿不到**可信**的落点返回 null（调用方据此给出可行动提示）。
///
/// 非绝对路径一律返回 null：那种输入只可能来自上游算错（`outputFolder` 为空、
/// 或文件名里带 `..` 被安全护栏原样保留），猜一个目录打开比"什么都不做"更糟。
RevealTarget? revealTargetFor(String path) {
  final String raw = path.trim();
  if (raw.isEmpty || !p.isAbsolute(raw)) return null;

  final String abs = p.normalize(raw);
  if (Directory(abs).existsSync()) {
    return RevealTarget(folder: abs, select: abs);
  }
  if (File(abs).existsSync()) {
    final String dir = File(abs).parent.path;
    if (dir.isEmpty || !Directory(dir).existsSync()) return null;
    return RevealTarget(folder: dir, select: abs);
  }

  // 文件/目录都找不到了（被外部删掉或移走）：往上找最近一个还存在的目录。
  String dir = File(abs).parent.path;
  while (dir.isNotEmpty && !Directory(dir).existsSync()) {
    final String parent = File(dir).parent.path;
    if (parent == dir) break;
    dir = parent;
  }
  if (dir.isEmpty || !Directory(dir).existsSync()) return null;
  return RevealTarget(folder: dir);
}

/// 在资源管理器里打开 [path] 的父目录并选中它（失败则只打开父目录）。
///
/// 任何一个环节失败都**退到下一步**，最后一步是"打开目录"：
/// 用户点这个按钮要的是"文件在哪"，打开目录已经满足；打不开才是失败。
Future<void> revealInExplorer(String path) async {
  if (!Platform.isWindows) {
    throw const ProcessException('explorer.exe', <String>[], '只有 Windows 有资源管理器');
  }
  final RevealTarget? target = revealTargetFor(path);
  if (target == null) return;

  final String? select = target.select;
  if (select != null && _selectInExplorer(select)) return;

  await Process.start(
    'explorer.exe',
    <String>[target.folder],
    mode: ProcessStartMode.detached,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// 「选中并打开」：`SHOpenFolderAndSelectItems`（不经过命令行，空格/中文都安全）
// ─────────────────────────────────────────────────────────────────────────────

typedef _CoInitializeExNative = Int32 Function(IntPtr reserved, Uint32 coInit);
typedef _CoInitializeExDart = int Function(int reserved, int coInit);
typedef _IlCreateFromPathNative = Pointer<Void> Function(Pointer<Utf16> path);
typedef _IlCreateFromPathDart = Pointer<Void> Function(Pointer<Utf16> path);
typedef _IlFreeNative = Void Function(Pointer<Void> pidl);
typedef _IlFreeDart = void Function(Pointer<Void> pidl);
typedef _OpenFolderAndSelectNative = Int32 Function(
  Pointer<Void> pidl,
  Uint32 childCount,
  Pointer<Void> children,
  Uint32 flags,
);
typedef _OpenFolderAndSelectDart = int Function(
  Pointer<Void> pidl,
  int childCount,
  Pointer<Void> children,
  int flags,
);

/// 用 Shell 接口打开 [path] 所在目录并选中它；成功返回 true。
///
/// 需要本线程初始化过 COM（失败也无所谓：`SHOpenFolderAndSelectItems` 会返回错误，
/// 我们退到"只打开目录"那条路）。
bool _selectInExplorer(String path) {
  Pointer<Void> pidl = nullptr;
  Pointer<Utf16> text = nullptr;
  try {
    DynamicLibrary.open('ole32.dll')
        .lookupFunction<_CoInitializeExNative, _CoInitializeExDart>('CoInitializeEx')(0, 0x2);
    final _IlCreateFromPathDart create = DynamicLibrary.open('shell32.dll')
        .lookupFunction<_IlCreateFromPathNative, _IlCreateFromPathDart>('ILCreateFromPathW');
    final _OpenFolderAndSelectDart open = DynamicLibrary.open('shell32.dll')
        .lookupFunction<_OpenFolderAndSelectNative, _OpenFolderAndSelectDart>(
      'SHOpenFolderAndSelectItems',
    );
    text = path.toNativeUtf16();
    pidl = create(text);
    if (pidl == nullptr) return false;
    // `cidl = 0` + 空的子项数组 = "选中 pidl 指的那个条目"。
    return open(pidl, 0, nullptr, 0) == 0;
  } catch (_) {
    return false;
  } finally {
    if (pidl != nullptr) {
      try {
        DynamicLibrary.open('shell32.dll')
            .lookupFunction<_IlFreeNative, _IlFreeDart>('ILFree')(pidl);
      } catch (_) {
        // 释放失败不影响结果。
      }
    }
    if (text != nullptr) malloc.free(text);
  }
}
