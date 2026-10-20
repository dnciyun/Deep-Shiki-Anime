import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/controllers/playlist_controller.dart';
import 'package:shikiin/models/media_item.dart';

MediaItem item(String path) => MediaItem(path: path, title: path);

void main() {
  test('hasPrevious / hasNext 反映位置（边界为 false，按钮隐藏而非禁用）', () {
    final g = EpisodeGroup(items: [item('/a'), item('/b'), item('/c')], currentIndex: 1);
    expect(g.hasPrevious, isTrue);
    expect(g.hasNext, isTrue);

    final first = g.copyWith(currentIndex: 0);
    expect(first.hasPrevious, isFalse);
    expect(first.hasNext, isTrue);

    final last = g.copyWith(currentIndex: 2);
    expect(last.hasPrevious, isTrue);
    expect(last.hasNext, isFalse);
  });

  test('previous / next 到边界返回 null', () {
    final g = EpisodeGroup(items: [item('/a'), item('/b')], currentIndex: 0);
    expect(g.previous, isNull);
    expect(g.next?.path, '/b');

    final end = g.copyWith(currentIndex: 1);
    expect(end.previous?.path, '/a');
    expect(end.next, isNull);
  });

  test('空组：既无上一集也无下一集', () {
    const g = EpisodeGroup(items: []);
    expect(g.isEmpty, isTrue);
    expect(g.hasPrevious, isFalse);
    expect(g.hasNext, isFalse);
  });

  test('copyWith 只换给定字段', () {
    final g = EpisodeGroup(items: [item('/a')], currentIndex: 0);
    final g2 = g.copyWith(currentIndex: 0);
    expect(g2.items, g.items);
    expect(g2.currentIndex, 0);
  });

  // 「播完自动下一集」（2026-10-20）：开关随宿主的分组带过来，缺省必须是关
  // —— 宿主没带这个字段时（内嵌宿主 / 旧分组）不该多跳一集。
  test('autoNext 默认关，copyWith 能打开', () {
    final g = EpisodeGroup(items: [item('/a'), item('/b')]);
    expect(g.autoNext, isFalse);
    expect(g.copyWith(autoNext: true).autoNext, isTrue);
    expect(g.copyWith(autoNext: true).items, g.items, reason: '只换开关，不动条目');
  });

  // 本地文件换集时字幕要跟着走（宿主把每一集的同名字幕都带过来了）。
  test('MediaItem 带字幕路径（本地文件换集不丢字幕）', () {
    const MediaItem withSub = MediaItem(
      path: '/a/ep01.mkv',
      title: 'ep01',
      subtitlePath: '/a/ep01.ass',
    );
    expect(withSub.subtitlePath, '/a/ep01.ass');
    expect(const MediaItem(path: '/a/ep01.mkv', title: 'ep01').subtitlePath, isNull);
  });
}
