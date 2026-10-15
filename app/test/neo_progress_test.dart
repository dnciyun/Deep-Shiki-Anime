/// 进度条填充方向的回归测试（用户 2026-10-12 第八轮：
/// 「下载进度条不要从中间开始，从左到右」）。
///
/// 根因：`NeoProgress` 里那个 `Align` 没给 `alignment`，`Align` 默认是
/// `Alignment.center`，于是填充块**以轨道中线为轴往两边长** —— 看起来就是从中间
/// 开始。这几条断言盯的就是「填充钉在左端、向右生长」，覆盖队列页每一条任务那条
/// 细进度条与首页追番卡片（两处都走 `NeoProgress`）。
library;

import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/ui/widgets/neo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 轨道宽固定 200，方便断言像素位置。
const double _trackWidth = 200;

Widget _host(double value) => MaterialApp(
      theme: buildDsanimaTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: _trackWidth, child: NeoProgress(value: value)),
        ),
      ),
    );

/// 填充块：`NeoProgress` 里那个 [FractionallySizedBox]。
Finder _fill() => find.descendant(
      of: find.byType(NeoProgress),
      matching: find.byType(FractionallySizedBox),
    );

void main() {
  testWidgets('填充钉在左端：左边界不随进度移动，且贴住轨道左端', (WidgetTester tester) async {
    double? firstLeft;
    for (final double v in <double>[0.25, 0.5, 0.75, 1]) {
      await tester.pumpWidget(_host(v));
      final Rect track = tester.getRect(find.byType(NeoProgress));
      final Rect fill = tester.getRect(_fill());
      firstLeft ??= fill.left;
      expect(
        fill.left,
        closeTo(firstLeft, 0.5),
        reason: 'v=$v：填充左边界必须钉死（从中间开始的话这里会随进度变）',
      );
      expect(fill.left, closeTo(track.left, 1.5), reason: 'v=$v：填充要贴住轨道左端');
    }
  });

  testWidgets('填充向右生长：宽度、中心、右边界都随进度变大/右移', (WidgetTester tester) async {
    final List<double> widths = <double>[];
    final List<double> centers = <double>[];
    final List<double> rights = <double>[];
    for (final double v in <double>[0.25, 0.5, 0.75, 1]) {
      await tester.pumpWidget(_host(v));
      final Rect fill = tester.getRect(_fill());
      widths.add(fill.width);
      centers.add(fill.center.dx);
      rights.add(fill.right);
    }
    for (int i = 1; i < widths.length; i++) {
      expect(widths[i], greaterThan(widths[i - 1]), reason: '宽度必须随进度增长');
      expect(centers[i], greaterThan(centers[i - 1]), reason: '中心必须随进度右移');
      expect(rights[i], greaterThan(rights[i - 1]), reason: '右边界必须随进度右移');
    }
  });

  testWidgets('0 与 1 两个端点：0 不留填充，1 铺满轨道', (WidgetTester tester) async {
    await tester.pumpWidget(_host(0));
    expect(tester.getRect(_fill()).width, closeTo(0, 0.5));

    await tester.pumpWidget(_host(1));
    final Rect track = tester.getRect(find.byType(NeoProgress));
    final Rect fill = tester.getRect(_fill());
    expect(fill.width, closeTo(track.width, 0.5));
    expect(fill.left, closeTo(track.left, 0.5));
    expect(fill.right, closeTo(track.right, 0.5));
  });
}
