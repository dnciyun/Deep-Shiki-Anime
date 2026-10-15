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
}
