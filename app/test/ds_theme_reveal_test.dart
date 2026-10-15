/// 换外观的 **Circular Reveal** 与"不再做颜色插值"（第三十三轮）。
///
/// 用户原话：「点击外观直接转换，不用点保存，使用动画Circular Reveal」+
/// 「处于白色系时点击黑白，会出现黑白字消失的问题，可能是颜色混一起了」。
///
/// 这个文件钉四件事：
/// 1. 点击立刻换配色（不等任何"保存"）；
/// 2. 演的时候有一层"旧界面快照"盖在圆外，动画结束它必须收干净（不留残像、不留内存）；
/// 3. 系统「减少动画」→ **不演**，直接换（宁可没动画，也不要黑一下）；
/// 4. `kDsThemeAnimationDuration == 0`：那条"中灰 = 字消失"的插值路径必须关着
///    （`shell_widget_test` 另有一条从外壳侧盯它）。
library;

import 'package:dsanima/app.dart' show kDsThemeAnimationDuration;
import 'package:dsanima/theme/motion.dart';
import 'package:dsanima/theme/tokens.dart';
import 'package:dsanima/ui/widgets/ds_theme_reveal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 被换掉的"配色"（真实场景里是主题 provider；这里只要一个"到底换了没有"的记号）。
bool applied = false;

DsThemeRevealHostState _host(WidgetTester tester) =>
    tester.state<DsThemeRevealHostState>(find.byType(DsThemeRevealHost));

/// 与 `app.dart` 同构的最小场景：宿主挂在 `builder` 上（整窗），页面里一个按钮触发。
Widget _harness({bool disableAnimations = false}) {
  applied = false;
  return MaterialApp(
    theme: ThemeData(extensions: <ThemeExtension<dynamic>>[DsTokens.whiteInk]),
    builder: (BuildContext context, Widget? child) =>
        DsThemeRevealHost(child: child ?? const SizedBox.shrink()),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(
        body: Builder(
          builder: (BuildContext context) => Center(
            child: FilledButton(
              key: const Key('switch-appearance'),
              onPressed: () async {
                final DsThemeRevealHostState? host =
                    context.findAncestorStateOfType<DsThemeRevealHostState>();
                await host!.revealFrom(
                  origin: const Offset(120, 90),
                  apply: () => applied = true,
                );
              },
              child: const Text('换外观'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('点一下：立刻生效，旧界面快照在圆外，动画结束收干净', (WidgetTester tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('switch-appearance')));
    // 拍快照是异步的（`toImage`）：两次 pump 让它落地并画出那一层。
    await tester.pump();
    await tester.pump();

    expect(applied, isTrue, reason: '点一下就必须换好（不用点保存）');
    if (_host(tester).isRevealing) {
      // 测试环境里 `RepaintBoundary.toImage` 若不可用会走"直接换"这条路（也不算失败），
      // 但只要它演起来了，圆外那层旧界面快照就必须在。
      expect(find.byKey(const Key('ds-theme-reveal-veil')), findsOneWidget,
          reason: '演的时候圆外那层旧界面快照必须在');
    }

    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ds-theme-reveal-veil')), findsNothing,
        reason: '动画结束必须收干净（快照也 dispose 掉）');
    expect(_host(tester).isRevealing, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统「减少动画」→ 不演，直接换（也不许抛）', (WidgetTester tester) async {
    await tester.pumpWidget(_harness(disableAnimations: true));
    await tester.pumpAndSettle();
    applied = false;

    await tester.tap(find.byKey(const Key('switch-appearance')));
    await tester.pumpAndSettle();

    expect(applied, isTrue, reason: '不演也要换（这正是"减少动画"的意思）');
    expect(find.byKey(const Key('ds-theme-reveal-veil')), findsNothing);
    expect(_host(tester).isRevealing, isFalse);
    expect(tester.takeException(), isNull);
  });

  test('颜色插值必须关着（中灰那一段 = 用户报的「黑白字消失」）', () {
    expect(kDsThemeAnimationDuration, Duration.zero);
    // 时长 token 本身还在（揭开那一层用它），只是不再拿去插值颜色。
    expect(DsMotion.themeBase, const Duration(milliseconds: 240));
  });
}
