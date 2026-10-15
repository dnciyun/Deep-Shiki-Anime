import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/theme_tokens.dart';
import 'package:shikiin/widgets/seek_bar.dart';
import 'package:shikiin/widgets/styled_track.dart';

Widget _host(SeekBar bar) =>
    MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: 400, child: bar))));

SeekBar _bar({ValueChanged<Duration>? onSeek, ValueChanged<bool>? onDragging}) => SeekBar(
      tokens: ThemeTokens.fallback,
      position: Duration.zero,
      duration: const Duration(seconds: 100),
      onSeek: onSeek ?? (_) {},
      onDragging: onDragging,
    );

void main() {
  testWidgets('拖动上报 onDragging(true→false)，松手落 onSeek', (tester) async {
    final drags = <bool>[];
    Duration? seeked;
    await tester.pumpWidget(_host(_bar(onSeek: (d) => seeked = d, onDragging: drags.add)));
    final gesture = await tester.startGesture(tester.getCenter(find.byType(StyledTrack)));
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    expect(drags, [true]);
    await gesture.up();
    await tester.pump();
    expect(drags, [true, false]);
    expect(seeked, isNotNull);
  });

  testWidgets('pointer cancel 仍上报 onDragging(false)（框架把已接受手势的 cancel 走 onEnd）',
      (tester) async {
    final drags = <bool>[];
    await tester.pumpWidget(_host(_bar(onDragging: drags.add)));
    final gesture = await tester.startGesture(tester.getCenter(find.byType(StyledTrack)));
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    await gesture.cancel();
    await tester.pump();
    // 关键回归点：不管哪条路径结束拖动，dragging 必须回 false，否则控制栏永不自动隐藏。
    expect(drags, [true, false]);
  });

  testWidgets('点击轨道落 onSeek（位置按命中比例换算）', (tester) async {
    Duration? seeked;
    await tester.pumpWidget(_host(_bar(onSeek: (d) => seeked = d)));
    final box = tester.getRect(find.byType(StyledTrack));
    await tester.tapAt(Offset(box.left + box.width * 0.5, box.center.dy));
    await tester.pump();
    expect(seeked, isNotNull);
    expect(seeked!.inSeconds, closeTo(50, 3));
  });

  testWidgets('时间文字为「位置 / 总时长」', (tester) async {
    await tester.pumpWidget(_host(_bar()));
    expect(find.text('00:00 / 01:40'), findsOneWidget);
  });
}
