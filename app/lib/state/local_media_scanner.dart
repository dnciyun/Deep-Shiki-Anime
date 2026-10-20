/// 本地文件夹扫描的真实实现（`dart:io`）。
///
/// 只有这一层碰磁盘：递归、跳过系统目录、单个子目录出错就跳过、带上限
/// （[kLocalScanMaxFiles]）。剩下的"哪些算视频 / 字幕怎么配 / 怎么排序"全在
/// `domain/local_media.dart` 的纯函数里 —— 于是那部分可以逐条写测试。
///
/// ⚠️ 目录遍历用 `followLinks: false`：番剧目录里常有指向别处的 junction
/// （尤其是把素材盘挂进来的软链），跟进去既可能绕圈，也可能把整块网盘拖死。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/local_media.dart';
import '../domain/ports.dart';

/// 一定不扫的目录名（小写比较）。
///
/// 这些不是"视频目录"，但经常出现在根目录里：回收站、系统卷信息、
/// 代码仓库、Synology 的缩略图缓存、macOS 的元数据目录。
const Set<String> _kSkippedDirs = <String>{
  'system volume information',
  r'$recycle.bin',
  '.git',
  'node_modules',
  '.trash',
  '#recycle',
  '@eadir',
  'lost+found',
};

class IoLocalMediaScanner implements LocalMediaScannerPort {
  const IoLocalMediaScanner();

  @override
  bool get isSupported => true;

  @override
  Future<List<LocalFileStat>> scan(String folder) async {
    final String root = folder.trim();
    if (root.isEmpty) {
      throw const LocalScanException('文件夹路径是空的');
    }
    final Directory dir = Directory(root);
    if (!await dir.exists()) {
      throw LocalScanException('这个文件夹不存在了：$root');
    }
    final List<LocalFileStat> out = <LocalFileStat>[];
    // 自己走队列，不用 `dir.list(recursive: true)`：
    // * 递归模式**没法在遍历时剪枝** —— 它照样会钻进 `System Volume Information`
    //   这种访问被拒的目录，而 Windows 上这很常见（整盘被加成文件夹时）；
    // * 递归模式的错误是以**流事件**形式冒出来的，一崩就是整次扫描失败，
    //   用户看到的是"盘上的东西一个都没有"。
    // 自己走的话：每层单独 try，读不了的层跳过但不影响别的层；跳过名单在**进入前**
    // 就剪掉（`.git/objects` 之类几万个文件不会被扫一遍再丢掉）。
    final List<Directory> pending = <Directory>[dir];
    bool rootListed = false;
    while (pending.isNotEmpty) {
      if (out.length >= kLocalScanMaxFiles) break;
      final Directory current = pending.removeLast();
      List<FileSystemEntity> entries;
      try {
        entries = await current.list(followLinks: false).toList();
        if (identical(current, dir)) rootListed = true;
      } on FileSystemException catch (e) {
        // 根目录都读不了 = 这次扫描没有意义，直接告诉用户。
        if (identical(current, dir)) {
          throw LocalScanException('读不了这个文件夹：${e.message}（$root）');
        }
        continue; // 子目录读不了：跳过这一层，别的照扫。
      }
      for (final FileSystemEntity entity in entries) {
        if (entity is Directory) {
          if (_isSkippedDirName(entity.path)) continue;
          pending.add(entity);
          continue;
        }
        // 软链（Link）不跟：既可能是环，也可能把整块网盘拖进来。
        if (entity is! File) continue;
        if (!isLocalVideoPath(entity.path) && !isLocalSubtitlePath(entity.path)) continue;
        int size = 0;
        DateTime? modified;
        try {
          final FileStat stat = await entity.stat();
          size = stat.size;
          modified = stat.modified;
        } catch (_) {
          // 单个文件 stat 失败（被占用 / 权限）：当 0 字节处理，别丢这一条。
        }
        out.add(LocalFileStat(path: entity.path, sizeBytes: size, modifiedAt: modified));
        if (out.length >= kLocalScanMaxFiles) break;
      }
    }
    if (!rootListed && out.isEmpty) {
      // 理论上到不了（`exists()` 已经过了）；留一条明确的失败，而不是空清单。
      throw LocalScanException('读不了这个文件夹：$root');
    }
    return out;
  }

  /// 这个目录名是不是在跳过名单里（只按名字判，不按整条路径）。
  bool _isSkippedDirName(String path) =>
      _kSkippedDirs.contains(p.basename(path).toLowerCase());
}
