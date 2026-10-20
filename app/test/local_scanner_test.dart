/// `IoLocalMediaScanner` 的真实 IO 测试（只碰 `Directory.systemTemp` 下的临时目录）。
///
/// 这一层是唯一碰磁盘的地方，钉住三件事：
/// * **递归**：子目录（番名 / 第 N 季 / 文件）里的视频都要扫到；
/// * **只收视频与字幕**：图片 / 说明文本 / 压缩包不进清单；
/// * **跳过系统目录**：`.git`、`System Volume Information`、`$RECYCLE.BIN` 这类
///   不该作为"番剧文件"出现在页面上（它们是根目录里的常客）；
/// * 目录不存在时抛 [LocalScanException]（页面把原因显示在那一行），而不是返回空清单
///   假装"扫过了，就是没有"。
library;

import 'dart:io';

import 'package:dsanima/domain/local_media.dart';
import 'package:dsanima/state/local_media_scanner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _TempTree {
  _TempTree(this.root);

  final Directory root;

  static Future<_TempTree> create() async {
    final Directory root = await Directory.systemTemp.createTemp('dsanima-local-scan-');
    return _TempTree(root);
  }

  Future<void> write(String relative, {String content = 'x'}) async {
    final File file = File(p.join(root.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  Future<void> dir(String relative) async {
    await Directory(p.join(root.path, relative)).create(recursive: true);
  }

  Future<void> dispose() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {
      // 临时目录删不掉不影响断言（Windows 上偶发占用）。
    }
  }
}

void main() {
  late _TempTree tree;

  setUp(() async {
    tree = await _TempTree.create();
  });

  tearDown(() async {
    await tree.dispose();
  });

  test('递归扫出视频 + 字幕，跳过图片 / 文本 / 系统目录', () async {
    await tree.write('Show/S1/Show - 01.mkv');
    await tree.write('Show/S1/Show - 01.ass');
    await tree.write('Show/S1/Show - 02.mp4');
    await tree.write('Show/S1/cover.jpg');
    await tree.write('Show/S1/说明.txt');
    await tree.write('Show/S1/pack.zip');
    await tree.write('.git/objects/deadbeef.mkv');
    await tree.write('System Volume Information/track.mkv');
    await tree.write(r'$RECYCLE.BIN/old.mkv');

    final List<LocalFileStat> files = await const IoLocalMediaScanner().scan(tree.root.path);
    final List<String> names = <String>[for (final LocalFileStat f in files) p.basename(f.path)]..sort();
    expect(names, <String>['Show - 01.ass', 'Show - 01.mkv', 'Show - 02.mp4']);
    expect(files.every((LocalFileStat f) => f.sizeBytes > 0), isTrue, reason: '大小要带上（页面显示它）');
  });

  test('子目录层级再深也扫得到', () async {
    await tree.write('a/b/c/d/deep - 03.mkv');
    final List<LocalFileStat> files = await const IoLocalMediaScanner().scan(tree.root.path);
    expect(files.map((LocalFileStat f) => p.basename(f.path)), <String>['deep - 03.mkv']);
  });

  test('目录不存在：抛 LocalScanException（不是静默返回空）', () async {
    final String missing = p.join(tree.root.path, 'not-there');
    await expectLater(
      const IoLocalMediaScanner().scan(missing),
      throwsA(isA<LocalScanException>()),
    );
  });

  test('空目录：扫出空清单（这不是错误）', () async {
    await tree.dir('empty');
    final List<LocalFileStat> files =
        await const IoLocalMediaScanner().scan(p.join(tree.root.path, 'empty'));
    expect(files, isEmpty);
  });

  test('扫出来的东西能被 domain 层直接整理成可播清单', () async {
    await tree.write('Anime/Show/Show - 02.mkv');
    await tree.write('Anime/Show/Show - 01.mkv');
    await tree.write('Anime/Show/Show - 01.ass');
    final List<LocalFileStat> files =
        await const IoLocalMediaScanner().scan(p.join(tree.root.path, 'Anime'));
    final List<LocalVideo> videos =
        localVideosFrom(folder: p.join(tree.root.path, 'Anime'), files: files);
    expect(videos.map((LocalVideo v) => v.episode), <int?>[1, 2]);
    expect(videos.first.subtitlePath, isNotNull);
  });
}
