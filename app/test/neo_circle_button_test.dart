/// `NeoCircleButton`（圆形图标按钮）的行为测试。
///
/// 用户 2026-10-14 第二十八轮：「优化刷新和换一批，**改为圆形按钮，仅保留矢量图，
/// 去除文字**」。这个文件钉死三件事：
/// 1. 按钮里**只有矢量图、没有文字**（文字只活在 tooltip 里）；
/// 2. 按下当帧有可见反馈（面沉成凹槽色） —— 否则用户以为没点着（第二十七轮之前的老毛病）；
/// 3. 忙态是**静态**的（面沉 + 图标降为三级色）且不吃重复点击。
///
/// ⚠️ 为什么忙态刻意不转圈：这块区域同时挂着骨架与网格，无限动画会让 `pumpAndSettle`
/// 永远不 settle（同 NeoActionChip 的那条决策，见 `app/lib/ui/widgets/neo.dart`）。
library;

import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/theme/tokens.dart';
import 'package:dsanima/ui/widgets/neo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
  theme: buildDsanimaTheme(),
  home: Scaffold(body: Center(child: child)),
);

/// 取按钮那层 `AnimatedContainer` 的装饰（圆面）。
BoxDecoration _face(WidgetTester tester) => tester
    .widget<AnimatedContainer>(
      find.descendant(of: find.byType(NeoCircleButton), matching: find.byType(AnimatedContainer)),
    )
    .decoration! as BoxDecoration;

/// 取按钮里那颗图标。
Icon _icon(WidgetTester tester) => tester.widget<Icon>(
  find.descendant(of: find.byType(NeoCircleButton), matching: find.byType(Icon)),
);

void main() {
  testWidgets('只有矢量图，没有文字；文字信息只在 tooltip 里', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(NeoCircleButton(icon: Icons.refresh, tooltip: '立即刷新追番表', onPressed: () {})),
    );

    expect(find.byType(Icon), findsOneWidget);
    expect(_icon(tester).icon, Icons.refresh);
    expect(
      find.descendant(of: find.byType(NeoCircleButton), matching: find.byType(Text)),
      findsNothing,
      reason: '用户第二十八轮：去除文字（tooltip 不算界面上的文字）',
    );
    expect(
      tester.widget<Tooltip>(find.byType(Tooltip)).message,
      '立即刷新追番表',
      reason: '按钮上没字，语义只能靠 tooltip 兜住',
    );
  });

  testWidgets('圆形面：按下当帧沉成凹槽色，抬手还原', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(NeoCircleButton(icon: Icons.shuffle, tooltip: '换一批', onPressed: () {})),
    );
    final DsTokens t = DsTokens.whiteInk;

    expect(_face(tester).shape, BoxShape.circle, reason: '用户第二十八轮：必须是圆形按钮');
    expect(_face(tester).color, t.raised);

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(NeoCircleButton)),
    );
    // ⚠️ 要过 100ms（TapGestureRecognizer 的 kPressTimeout）才断言：这颗按钮外面套着
    // Tooltip，Tooltip 自己有一个长按识别器在竞技场里，所以 `onTapDown` 不会在指针落下
    // 当帧就发，而是等按下超时（`_checkDown`）。150ms 覆盖它，别用 `pump()` 空推一帧。
    await tester.pump(const Duration(milliseconds: 150));
    // ⚠️ 第二十九轮扁平化：按下不再是「沉成 sunken」（那一档给悬停），而是 `dsPressedFace`
    // —— 在 sunken 上再压一档，保证「悬停」与「按下」看得到区别。
    expect(_face(tester).color, dsPressedFace(t), reason: '按下必须有可见变化，否则用户以为没点着');

    await gesture.up();
    await tester.pump();
    expect(_face(tester).color, t.raised);
  });

  testWidgets('忙态：面沉下去、图标降为三级色、不吃重复点击（静态，不转圈）', (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(
      _host(
        NeoCircleButton(
          icon: Icons.refresh,
          tooltip: '立即刷新',
          busyTooltip: '正在刷新…',
          busy: true,
          onPressed: () => taps++,
        ),
      ),
    );
    final DsTokens t = DsTokens.whiteInk;

    expect(_face(tester).color, dsPressedFace(t), reason: '忙态用静态的面沉表达');
    expect(_icon(tester).color, t.text3);
    expect(
      tester.widget<Tooltip>(find.byType(Tooltip)).message,
      '正在刷新…',
      reason: '按钮上没字，忙态只能靠 tooltip 说清',
    );

    await tester.tap(find.byType(NeoCircleButton), warnIfMissed: false);
    await tester.pump();
    expect(taps, 0, reason: '忙态里连点 = 连发请求，是这些控件最容易踩的坑');
  });

  testWidgets('onPressed 为 null：不可点、图标降为三级色，但形态不变', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const NeoCircleButton(icon: Icons.shuffle)));

    expect(_icon(tester).color, DsTokens.whiteInk.text3);
    expect(find.byType(Tooltip), findsNothing, reason: '没给 tooltip 就不渲染 Tooltip');
    // 不可点也要保持同一个圆面形态（不跳成另一种控件）。
    expect(_face(tester).shape, BoxShape.circle);
  });
}
