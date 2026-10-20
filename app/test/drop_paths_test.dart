/// 拖放分流规则（纯函数）。
///
/// 为什么单独测：真正的拖放通道在组件测试里造不出来，而"拖进来一堆东西会怎样"
/// 恰恰是用户最容易踩的（拖一个文件夹、拖字幕、拖 mkv+torrent 混着、拖 .TORRENT
/// 大写扩展名）。这些判断都在 [partitionDroppedPaths] 里，可以逐条钉死。
library;

import 'package:dsanima/domain/drop_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('视频 / 种子 / 其它 三类分开，保持原始顺序', () {
    final DroppedPaths paths = partitionDroppedPaths(<String>[
      p.join('F:', 'Anime', 'Show - 01.mkv'),
      p.join('F:', 'Anime', 'Show - 01.ass'),
      p.join('F:', 'Downloads', 'Show.torrent'),
      p.join('F:', 'Anime', 'Show - 02.mp4'),
      p.join('F:', 'Anime'),
    ]);
    expect(paths.videos, <String>[
      p.join('F:', 'Anime', 'Show - 01.mkv'),
      p.join('F:', 'Anime', 'Show - 02.mp4'),
    ]);
    expect(paths.torrents, <String>[p.join('F:', 'Downloads', 'Show.torrent')]);
    expect(paths.others, <String>[
      p.join('F:', 'Anime', 'Show - 01.ass'),
      p.join('F:', 'Anime'),
    ]);
    expect(paths.length, 5);
  });

  test('扩展名大小写不敏感；.TORRENT 也认', () {
    expect(droppedKindOf('F:/a/Show - 01.MKV'), DroppedKind.video);
    expect(droppedKindOf('F:/a/Show.TORRENT'), DroppedKind.torrent);
    expect(droppedKindOf('F:/a/Show.Torrent'), DroppedKind.torrent);
    expect(droppedKindOf('F:/a/cover.jpg'), DroppedKind.other);
    expect(droppedKindOf(''), DroppedKind.other);
  });

  test('空串与空白被丢掉（拖放时偶尔会带一条空的）', () {
    final DroppedPaths paths = partitionDroppedPaths(<String>['', '   ', 'F:/a/x.mkv']);
    expect(paths.length, 1);
    expect(paths.videos, <String>['F:/a/x.mkv']);
  });

  test('首尾空白会被去掉（资源管理器给的路径偶尔带尾空格）', () {
    final DroppedPaths paths = partitionDroppedPaths(<String>['  F:/a/x.mkv  ']);
    expect(paths.videos, <String>['F:/a/x.mkv']);
  });

  test('全空 = isEmpty（调用方据此什么都不做）', () {
    expect(partitionDroppedPaths(const <String>[]).isEmpty, isTrue);
  });
}
