import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/anime4k_preset.dart';
import 'package:shikiin/models/theme_tokens.dart';
import 'package:shikiin/widgets/control_bar.dart';
import 'package:shikiin/widgets/seek_bar.dart';
import 'package:shikiin/widgets/styled_track.dart';

/// 某颗按钮在**控制栏那一行**里的横向位置（`Row` 的父数据偏移）。
///
/// 用 `Row` 的 `BoxParentData.offset.dx` 而不是 `tester.getTopLeft` 的全局坐标：
/// 直接读布局结果，不受外层 `Column`/`Scaffold` 的定位影响。
double _dxInRow(WidgetTester tester, Key key) {
  final RenderBox box = tester.renderObject<RenderBox>(find.byKey(key));
  return (box.parentData! as BoxParentData).offset.dx;
}

ControlBar _bar({
  ThemeTokens? tokens,
  VoidCallback? onPlay,
  VoidCallback? onPrev,
  VoidCallback? onNext,
  VoidCallback? onCycle,
  Anime4kPreset anime4k = Anime4kPreset.off,
  bool playing = false,
}) =>
    ControlBar(
      tokens: tokens ?? ThemeTokens.fallback,
      playing: playing,
      position: Duration.zero,
      duration: const Duration(seconds: 100),
      volume: 100,
      onPlayPause: onPlay ?? () {},
      onFullscreen: () {},
      onSeek: (_) {},
      onVolume: (_) {},
      onPrevious: onPrev,
      onNext: onNext,
      anime4k: anime4k,
      onCycleAnime4k: onCycle ?? () {},
    );

Future<void> _pump(WidgetTester tester, ControlBar bar) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(mainAxisAlignment: MainAxisAlignment.end, children: [bar]))));

void main() {
  testWidgets('点播放/暂停触发回调', (tester) async {
    var tapped = false;
    await _pump(tester, _bar(onPlay: () => tapped = true));
    await tester.tap(find.byKey(const Key('btn_playPause')));
    expect(tapped, true);
  });

  testWidgets('没有剧集组时不渲染上一集/下一集；有则渲染', (tester) async {
    await _pump(tester, _bar());
    expect(find.byKey(const Key('btn_prev')), findsNothing);
    expect(find.byKey(const Key('btn_next')), findsNothing);

    await _pump(tester, _bar(onPrev: () {}, onNext: () {}));
    expect(find.byKey(const Key('btn_prev')), findsOneWidget);
    expect(find.byKey(const Key('btn_next')), findsOneWidget);
  });

  testWidgets('上一集/下一集并排在进度条右边，且「下一集」在「上一集」右边（第二十六轮）', (tester) async {
    await _pump(tester, _bar(onPrev: () {}, onNext: () {}));

    final RenderBox seek = tester.renderObject<RenderBox>(find.byType(SeekBar));
    final double seekX = (seek.parentData! as BoxParentData).offset.dx;
    final double prevX = _dxInRow(tester, const Key('btn_prev'));
    final double nextX = _dxInRow(tester, const Key('btn_next'));

    expect(prevX, greaterThan(seekX), reason: '「上一集」要在进度条**右边**（旧摆法它在左边）');
    expect(nextX, greaterThan(prevX), reason: '「下一集」要在「上一集」右边');
    expect(
      nextX - prevX,
      closeTo(ThemeTokens.fallback.controlHeight, 0.5),
      reason: '两颗切集键**相邻**：中间只隔一个按钮宽度（不能隔着进度条）',
    );
    // 与进度条也紧挨着（中间只有 t.spacing 的间隔）。
    expect(
      prevX - (seekX + seek.size.width),
      closeTo(ThemeTokens.fallback.spacing, 0.5),
      reason: '进度条与「上一集」之间只有 spacing 的间隔',
    );
  });

  testWidgets('进度条填充用 tokens.accent', (tester) async {
    final tokens = ThemeTokens.fallback.copyWith(accent: const Color(0xFF00C2FF));
    await _pump(tester, _bar(tokens: tokens));
    final track = tester.widget<StyledTrack>(
      find.descendant(of: find.byType(SeekBar), matching: find.byType(StyledTrack)),
    );
    expect(track.accent, const Color(0xFF00C2FF));
  });

  testWidgets('超分胶囊显示当前档，点一下循环切档', (tester) async {
    var cycled = 0;
    await _pump(tester, _bar(anime4k: Anime4kPreset.standard, onCycle: () => cycled++));
    expect(find.text('超分 标'), findsOneWidget);
    await tester.tap(find.byKey(const Key('anime4kPill')));
    expect(cycled, 1);

    await _pump(tester, _bar(anime4k: Anime4kPreset.off));
    expect(find.text('超分 关'), findsOneWidget);
  });

  testWidgets('全屏按钮存在；时间文字在控制栏里', (tester) async {
    await _pump(tester, _bar());
    expect(find.byKey(const Key('btn_fullscreen')), findsOneWidget);
    expect(find.text('00:00 / 01:40'), findsOneWidget);
  });
}
