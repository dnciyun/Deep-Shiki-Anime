/// Windows 回收站（用户 2026-10-12 第十四轮：删除要「可恢复」）。
///
/// 为什么不能复用引擎那条删除：`DELETE /torrents/{id}?deleteFiles=true` 是
/// **永久删除**，没有回收站语义。用户选的是「两个分开：移除任务 / 删文件到回收站」，
/// 所以"删文件"这半步必须宿主自己做。
///
/// 实现：`SHFileOperation(FO_DELETE | FOF_ALLOWUNDO | …)`（shell32）。
/// 为什么用 Win32 API 而不是 `Process.run('powershell', Microsoft.VisualBasic…)`：
/// * 已经在依赖图里的 `win32` 就是干这个的，不必为删一个文件起一个 PowerShell；
/// * PowerShell 受执行策略影响，**被禁时静默失败**，而删文件这种事不能有"看起来成功了
///   其实没删"的中间态。
///
/// ⚠️ 安全红线：**永远不要把整个下载根目录丢进来**。真机 dump（第十二轮）里引擎给的
/// `outputFolder` 就是下载根（`C:\Users\…\Downloads\Anime\`），把目录整个删掉 =
/// 把用户全部番剧连锅端。所以删除一律**按文件**走（见 `completed.dart` 的
/// `engineFileAbsolutePath`），并且过一遍 [recyclablePaths] 的护栏。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

/// 这些路径**绝不允许**被删（护栏，纯函数，可单测）。
///
/// 判据（全部是"这明显不是某个 torrent 的文件"）：
/// 1. 空串 / 非绝对路径（相对路径删起来指的是"当前工作目录"，最容易出事故）；
/// 2. 盘根（`C:\`）或只剩一两层的目录（`C:\Users`、`F:\Anime`）；
/// 3. 等于 [downloadRoot] 本身 —— 那是下载根，不是文件；
/// 4. 是 [downloadRoot] 的祖先（反了：用户在删库）；
/// 5. 路径里含 `..`（拼出来的野路径）。
///
/// 返回**通过护栏的**那一部分，顺序与入参一致。
List<String> recyclablePaths(
  Iterable<String> paths, {
  String? downloadRoot,
  Set<String> protectedPaths = const <String>{},
}) {
  final Set<String> protectedKeys = <String>{
    for (final String s in protectedPaths)
      if (s.trim().isNotEmpty) _key(s),
  };
  final String root = (downloadRoot ?? '').trim();
  final String? rootKey = root.isEmpty ? null : _key(root);

  final List<String> out = <String>[];
  for (final String raw in paths) {
    final String path = raw.trim();
    if (path.isEmpty) continue;
    if (path.contains('..')) continue;
    if (!p.isAbsolute(path)) continue;
    final String norm = p.normalize(path);
    if (!_hasEnoughDepth(norm)) continue;
    final String key = _key(norm);
    if (protectedKeys.contains(key)) continue;
    if (rootKey != null) {
      // 下载根本身、或它的祖先 → 拒绝（父子关系用路径分隔符判，避免 `Anime2` 撞 `Anime`）。
      if (key == rootKey) continue;
      if (rootKey.startsWith('$key${p.separator}')) continue;
    }
    out.add(norm);
  }
  return out;
}

/// 目录深度护栏：`C:\`（0 段）、`C:\Users`（1 段）、`F:\Anime`（1 段）都不删。
///
/// 为什么是 2 段：正常要删的是 `F:\Anime\Show\ep01.mkv` 这种，至少 2 段；
/// 而"1 段"的目录杀掉是灾难级的（`F:\Anime` 里可能躺着几百部番）。
bool _hasEnoughDepth(String absolutePath) {
  final List<String> parts = p
      .split(absolutePath)
      .where((String s) => s.trim().isNotEmpty && s != p.separator)
      .toList();
  if (p.isAbsolute(absolutePath)) {
    // Windows 的 `p.split('C:\a')` = ['C:\', 'a']，盘根那段要算进去但不增加深度。
    final int segments = parts.where((String s) => !s.endsWith(p.separator)).length;
    return segments >= 2;
  }
  return parts.length >= 3;
}

/// 比较用的规范键：去尾部斜杠、统一分隔符、小写（Windows 大小写不敏感）。
String _key(String path) =>
    p.normalize(path).replaceAll('/', p.separator).replaceAll(RegExp(r'\\+$'), '').toLowerCase();

/// 一个"把一批路径移进回收站"的实现（可注入：测试里换成假实现，绝不真删文件）。
typedef RecycleToTrash = Future<int> Function(List<String> paths);

/// 把文件 / 目录**移进回收站**（`FOF_ALLOWUNDO`），返回真的动过的条目数。
///
/// 不存在/已删掉的路径会被跳过（不是错误）。只删 [paths] 里明确给出的那些路径，
/// **不做任何递归/父目录推导** —— 那是调用方的责任（见 `completed.dart`）。
///
/// 抛出 [RecycleBinException] = 一个都没删成（含 Windows 拒绝、路径全不合法）。
/// 部分成功的常见情形（某几个文件已被外部删掉）不算失败，计数会体现。
Future<int> moveToRecycleBin(List<String> paths) async {
  if (!Platform.isWindows) {
    throw const RecycleBinException('只有 Windows 有回收站', hint: '这个平台请在资源管理器里删');
  }
  final List<String> existing = <String>[
    for (final String path in paths)
      if (File(path).existsSync() || Directory(path).existsSync()) path,
  ];
  if (existing.isEmpty) return 0;

  final Pointer<SHFILEOPSTRUCT> op = calloc<SHFILEOPSTRUCT>();
  // pFrom 是「以 \0 结尾、再以一个 \0 收尾」的双重终止字符串（Win32 的老规矩）。
  final String joined = '${existing.join('\u0000')}\u0000\u0000';
  final Pointer<Utf16> from = joined.toNativeUtf16();
  try {
    op.ref
      ..hwnd = 0
      ..wFunc = FO_DELETE
      // FOF_ALLOWUNDO 才是"进回收站"；少了它就是永久删除。
      // FOF_NOCONFIRMATION/FOF_SILENT/FOF_NOERRORUI：确认框由我们自己的对话框负责，
      // 不让系统再弹一个（否则一次删多个文件会连着弹）。
      ..fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI
      ..pFrom = from
      ..pTo = nullptr
      ..fAnyOperationsAborted = 0;

    final int code = SHFileOperation(op);
    if (code != 0) {
      throw RecycleBinException(
        'Windows 拒绝把这个文件放进回收站（错误码 $code）',
        hint: '可能是文件被占用、或所在盘不支持回收站（网络盘/U 盘常见）：'
            '关掉正在播它的播放器后重试，或到「队列 → 打开文件夹」自己删',
      );
    }
    return existing.length;
  } finally {
    calloc.free(op);
    calloc.free(from);
  }
}

/// 回收站当前的大小与条目数。用来在真机探针里证明"文件确实进了回收站"
/// （而不只是从原位置消失了）。
typedef RecycleBinStats = ({int bytes, int items});

/// 查回收站（`SHQueryRecycleBin(null)` = 所有盘合计）。
///
/// 失败返回 null（调用方不要拿它当错误：查不到回收站不该挡任何功能）。
RecycleBinStats? recycleBinStats() {
  if (!Platform.isWindows) return null;
  final Pointer<SHQUERYRBINFO> info = calloc<SHQUERYRBINFO>();
  try {
    info.ref.cbSize = sizeOf<SHQUERYRBINFO>();
    final int code = SHQueryRecycleBin(nullptr, info);
    if (code != 0) return null;
    return (bytes: info.ref.i64Size, items: info.ref.i64NumItems);
  } finally {
    calloc.free(info);
  }
}

/// 回收站这一步失败（用户要看到原因与下一步，所以带 [hint]）。
class RecycleBinException implements Exception {
  const RecycleBinException(this.message, {this.hint});

  final String message;
  final String? hint;

  @override
  String toString() => hint == null ? message : '$message（$hint）';
}
