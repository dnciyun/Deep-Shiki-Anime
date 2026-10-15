/// 动效 token 的守卫测试（规范 §8：分层时长 + 尊重系统「减少动画」+ 逐次淡入上限）。
library;

import 'package:dsanima/theme/motion.dart';
import 'package:dsanima/ui/widgets/ds_stagger.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<DsMotion> _motionOf(
  WidgetTester tester, {
  bool disableAnimations = false,
}) async {
  late DsMotion motion;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Builder(
        builder: (BuildContext context) {
          motion = DsMotion.of(context);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return motion;
}

Widget _stagger(int index) => MaterialApp(
      home: DsStaggerFade(index: index, child: Text('第 $index 项')),
    );

/// 当前**实际**渲染的透明度。
///
/// ⚠️ 不能读 `AnimatedOpacity.opacity`（那是目标值，一开始动画就恒为 1）—— 第二十九轮
/// 第一版测试就是这么写错的：`pump(20ms)` 时读出 1.0，看起来"动画没播"。
/// 真正在动的是它内部的 `FadeTransition` 的动画值。
double _opacity(WidgetTester tester) {
  final FadeTransition fade = tester.widget<FadeTransition>(
    find.descendant(
      of: find.byType(AnimatedOpacity),
      matching: find.byType(FadeTransition),
    ),
  );
  return fade.opacity.value;
}

void main() {
  test('分层时长：hover 90 / press 60 / 页面与列表与浮层 180 / 轮播 320 / 外观 240', () {
    expect(DsMotion.standard.hover, const Duration(milliseconds: 90));
    expect(DsMotion.standard.press, const Duration(milliseconds: 60));
    expect(DsMotion.standard.page, const Duration(milliseconds: 180));
    expect(DsMotion.standard.list, const Duration(milliseconds: 180));
    expect(DsMotion.standard.overlay, const Duration(milliseconds: 180));
    expect(DsMotion.standard.carousel, const Duration(milliseconds: 320));
    expect(DsMotion.standard.theme, const Duration(milliseconds: 240));
  });

  testWidgets('DsMotion.of：默认给标准时长（曲线固定）', (WidgetTester tester) async {
    final DsMotion m = await _motionOf(tester);
    expect(m.hover, const Duration(milliseconds: 90));
    expect(m.carousel, const Duration(milliseconds: 320));
    expect(m.theme, const Duration(milliseconds: 240));
    expect(DsMotion.carouselCurve, Curves.easeInOutCubic);
    expect(DsMotion.themeCurve, Curves.easeInOut);
  });

  testWidgets('系统「减少动画」：七档时长全部归零（曲线不变）', (WidgetTester tester) async {
    final DsMotion m = await _motionOf(tester, disableAnimations: true);
    for (final Duration d in <Duration>[
      m.hover,
      m.press,
      m.page,
      m.list,
      m.overlay,
      m.carousel,
      m.theme,
    ]) {
      expect(d, Duration.zero);
    }
    expect(DsMotion.carouselCurve, Curves.easeInOutCubic);
  });

  testWidgets('逐次淡入：第 0 项首帧透明，180ms 后完全显示', (WidgetTester tester) async {
    await tester.pumpWidget(_stagger(0));
    expect(_opacity(tester), 0, reason: '首帧必须是透明的（还没开始淡入）');
    await tester.pump(const Duration(milliseconds: 20));
    expect(_opacity(tester), lessThan(1), reason: '20ms 时还在淡入');
    await tester.pump(const Duration(milliseconds: 200));
    expect(_opacity(tester), 1, reason: '180ms 的淡入必须结束');
  });

  testWidgets('逐次淡入：错峰 20ms/项（第 3 项 60ms 后才开始）', (WidgetTester tester) async {
    await tester.pumpWidget(_stagger(3));
    await tester.pump(const Duration(milliseconds: 20));
    expect(_opacity(tester), 0, reason: '第 3 项的延迟是 60ms，20ms 时还没动');
    // 到 80ms：延迟已过，动画在这一帧开始；再给它 200ms 跑完 180ms 的淡入。
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 200));
    expect(_opacity(tester), 1);
  });

  testWidgets('逐次淡入：第 6 项起不参与淡入（首帧即完全显示）', (WidgetTester tester) async {
    await tester.pumpWidget(_stagger(DsMotion.staggerMax));
    expect(_opacity(tester), 1, reason: '第 7 项（index 6）起直接显示，不播动画');
  });

  testWidgets('逐次淡入：减少动画时不包 AnimatedOpacity', (WidgetTester tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: _stagger(0),
      ),
    );
    expect(find.byType(AnimatedOpacity), findsNothing);
    expect(find.text('第 0 项'), findsOneWidget);
  });
}
