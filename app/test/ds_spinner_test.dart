/// iOS 风格加载圆环的守卫 / 动画测试（用户 2026-10-12 第八轮）。
///
/// 这轮把 Material 的 `CircularProgressIndicator` 全部换成了 [DsSpinner]：用户要的是
/// 「单圈渐变弧线（Safari / 新 iOS 那种圆环）」，而 Material 那个是弧长会呼吸伸缩的
/// 另一种观感。所以这里守三件事：
/// 1. 三档尺寸/线宽/底轨就是问答里定下的值（16+轨 / 14 / 13）；
/// 2. 真的在转，而且**每帧只重画不重建**（`repaint: controller`，不 `setState`）；
/// 3. `lib/` 下再也**不许出现** Material 那个转圈（防止又被顺手加回来）。
///
/// ⚠️ 本来还想把渲染结果写成 PNG 给人眼看，但 `RenderRepaintBoundary.toImage()` 在
/// `flutter test` 里会**挂住不返回**（实测 10 分钟超时），所以按当时的约定退回：
/// 只断言行为，观感由用户在真机上看。别再加回截图，除非确认能跑通。
library;

import 'dart:io';

import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/theme/tokens.dart';
import 'package:dsanima/ui/widgets/ds_spinner.dart';
import 'package:dsanima/ui/widgets/neo.dart';
import 'package:dsanima/ui/widgets/state_views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {DsTokens tokens = DsTokens.whiteInk}) => MaterialApp(
      theme: buildDsanimaTheme(tokens: tokens),
      home: Scaffold(body: Center(child: child)),
    );

/// 圆环内部那个画笔 widget。
Finder _paint() => find.descendant(
      of: find.byType(DsSpinner),
      matching: find.byType(CustomPaint),
    );

void main() {
  test('三档参数就是问答里定下的值', () {
    const DsSpinner page = DsSpinner.page();
    const DsSpinner inline = DsSpinner.inline();
    const DsSpinner button = DsSpinner.button();

    expect(<double>[page.size, page.strokeWidth], <double>[16, 2]);
    expect(page.showTrack, isTrue, reason: '页面加载那一档要带底轨');
    expect(<double>[inline.size, inline.strokeWidth], <double>[14, 1.6]);
    expect(<double>[button.size, button.strokeWidth], <double>[13, 1.6]);
    expect(inline.showTrack, isFalse, reason: '小尺寸省略底轨，否则 14px 下糊成小饼');
    expect(button.showTrack, isFalse);
    expect(DsSpinner.period, const Duration(seconds: 1));
    expect(DsSpinner.sweepRatio, closeTo(300 / 360, 1e-9));
  });

  testWidgets('按给定尺寸渲染，并且一直在转', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const DsSpinner.page()));
    expect(tester.getSize(find.byType(DsSpinner)), const Size(16, 16));
    expect(
      tester.binding.transientCallbackCount,
      greaterThan(0),
      reason: '圆环必须是持续动画（AnimationController.repeat）',
    );

    // 转一圈再验一次：不会自己停下，也不会抛。
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    // 换掉整棵树，让 controller 正常 dispose（别把活动 ticker 留给下一个测试）。
    await tester.pumpWidget(_host(const SizedBox.shrink()));
  });

  testWidgets('三处调用点用的都是 DsSpinner，不再是 Material 转圈', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const DsLoading(label: '加载中…')));
    expect(find.byType(DsSpinner), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('加载中…'), findsOneWidget, reason: '文字提示保留（用户 2026-10-12 确认）');

    await tester.pumpWidget(_host(const NeoButton(label: '忙', busy: true)));
    expect(find.byType(DsSpinner), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.pumpWidget(_host(const SizedBox.shrink()));
  });

  test('守卫：lib 下不得再出现 Material 的 CircularProgressIndicator', () {
    // 三处（页面加载 / 按钮忙碌 / 搜索结果行内）都已经换成 DsSpinner；
    // 再冒出第四个就是没走统一组件，小尺寸那套"省底轨 + 细线宽"的取舍会丢。
    final List<String> offenders = <String>[];
    for (final FileSystemEntity e in Directory('lib').listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final String rel = e.path.replaceAll(r'\', '/');
      final List<String> lines = e.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) continue;
        if (lines[i].contains('CircularProgressIndicator')) {
          offenders.add('$rel:${i + 1}  ${lines[i].trim()}');
        }
      }
    }
    expect(offenders, isEmpty, reason: '转圈统一走 DsSpinner。\n${offenders.join('\n')}');
  });

  testWidgets('每帧只重画、不重建（repaint: controller，不 setState）', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const DsSpinner.page()));
    final CustomPaint first = tester.widget<CustomPaint>(_paint());
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    final CustomPaint later = tester.widget<CustomPaint>(_paint());
    expect(
      identical(first, later),
      isTrue,
      reason: '转圈走 CustomPainter(repaint: controller)：多帧之后不该产生新的 widget 实例',
    );
    expect(
      find.descendant(of: find.byType(DsSpinner), matching: find.byType(RepaintBoundary)),
      findsOneWidget,
      reason: '圆环自带的 RepaintBoundary 不能丢：搜索结果里可能同时挂几十个',
    );
    await tester.pumpWidget(_host(const SizedBox.shrink()));
  });
}
