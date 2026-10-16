/// iOS 风格加载圆环的守卫 / 动画 / 形状测试（用户 2026-10-12 第八轮）。
///
/// 这轮把 Material 的 `CircularProgressIndicator` 全部换成了 [DsSpinner]：用户要的是
/// 「单圈渐变弧线（Safari / 新 iOS 那种圆环）」，而 Material 那个是弧长会呼吸伸缩的
/// 另一种观感。所以这里守四件事：
/// 1. 三档尺寸/线宽/底轨就是问答里定下的值（16+轨 / 14 / 13）；
/// 2. 真的在转，而且**每帧只重画不重建**（`repaint: controller`，不 `setState`）；
/// 3. **一整圈里每一帧的形状必须一致**（第四十八轮用户报「转一半就重新转了」：
///    第一版把旋转量累加进 `SweepGradient` 的角度，越过 2π 被引擎绕回来，渐变当场翻转）；
/// 4. `lib/` 下再也**不许出现** Material 那个转圈（防止又被顺手加回来）。
///
/// ⚠️ 像素断言能成立的关键：`RenderRepaintBoundary.toImage()` 必须包在
/// `tester.runAsync(...)` 里（默认的 fake async 下 GPU 读回永远不会完成 ——
/// 第八轮当初就是因为没包它，量了 10 分钟超时，于是整条路被放弃、只敢断言行为）。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/theme/tokens.dart';
import 'package:dsanima/ui/widgets/ds_spinner.dart';
import 'package:dsanima/ui/widgets/neo.dart';
import 'package:dsanima/ui/widgets/state_views.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

  // ── 第四十八轮：一整圈里形状必须一致（用户：「转一半就重新转了」） ──────────────

  testWidgets('一整圈里每一帧都是同一个形状（只有位置在变）', (WidgetTester tester) async {
    // 放大到 120px：几何是等比的，放大只是为了让按角度采样干净
    // （14px 真身上一个采样点跨好几个像素，量出来全是锯齿）。
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: RepaintBoundary(
              key: const Key('spinner-shape'),
              // 黑底 + 白墨：取红通道就等于取 alpha，而且存出来的 PNG 人眼能看。
              child: Container(
                color: Colors.black,
                child: const DsSpinner(
                  size: 120,
                  strokeWidth: 12,
                  showTrack: false,
                  color: Color(0xFFFFFFFF),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    List<int>? reference;
    for (int i = 0; i < 8; i++) {
      // 每个相位都从 0 重新累计（`repeat` 是线性的：value = 累计时长 / 周期）。
      await tester.pump(const Duration(milliseconds: 125)); // 1/8 圈
      final List<int> profile = await _alphaProfile(tester);
      final List<int> sorted = List<int>.of(profile)..sort();

      expect(
        _runs(sorted, 96),
        1,
        reason: '第 $i 帧：亮的那一段必须**连续**（被 2π 绕回来的渐变会切成两三段，'
            '看上去就是"转一半重新开始"）',
      );
      if (reference == null) {
        reference = sorted;
        expect(sorted.last, greaterThan(240), reason: '弧头要是实心的');
        continue;
      }
      for (int k = 0; k < sorted.length; k++) {
        expect(
          (sorted[k] - reference[k]).abs(),
          lessThanOrEqualTo(12),
          reason: '第 $i 帧的形状与第一帧不一致（第 $k 个采样：'
              '${sorted[k]} vs ${reference[k]}）—— 转圈不该改变形状',
        );
      }
    }
    await tester.pumpWidget(_host(const SizedBox.shrink()));
  });
}

/// 抓那个 RepaintBoundary 并按角度采一圈 alpha（见文件头：必须走 `runAsync`）。
Future<List<int>> _alphaProfile(WidgetTester tester) async {
  final RenderRepaintBoundary boundary =
      tester.renderObject(find.byKey(const Key('spinner-shape'))) as RenderRepaintBoundary;
  final ui.Image image = (await tester.runAsync(() => boundary.toImage()))!;
  final ByteData data = (await tester.runAsync<ByteData?>(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  final int width = image.width;
  final int height = image.height;
  image.dispose();

  const double ringSize = 120;
  const double ringRadius = (ringSize - 12) / 2;
  final double ratio = width / ringSize;
  final double cx = width / 2;
  final double cy = height / 2;
  final int band = (width * 0.06).round().clamp(1, 400);

  final List<int> out = <int>[];
  for (int deg = 0; deg < 360; deg += 3) {
    final double a = deg * math.pi / 180;
    int best = 0;
    // 取径向 ±(线宽/2) 范围内的最大值：避开"采样圆偏一点就落到笔触边缘"的锯齿。
    for (int d = -band; d <= band; d++) {
      final double r = (ringRadius + d / ratio) * ratio;
      final int x = (cx + r * math.cos(a)).round().clamp(0, width - 1);
      final int y = (cy + r * math.sin(a)).round().clamp(0, height - 1);
      final int alpha = data.getUint8((y * width + x) * 4); // 黑底白墨：R 就是 alpha
      if (alpha > best) best = alpha;
    }
    out.add(best);
  }
  return out;
}

/// 一串 alpha 里 ≥ [threshold] 的点构成几段（循环计；从第一个"不亮"处切一刀）。
int _runs(List<int> alphas, int threshold) {
  final List<bool> bright = <bool>[for (final int a in alphas) a >= threshold];
  final int cut = bright.indexOf(false);
  if (cut < 0) return 1;
  int runs = 0;
  bool inRun = false;
  for (int i = 0; i < bright.length; i++) {
    final bool b = bright[(cut + i) % bright.length];
    if (b && !inRun) {
      runs++;
      inRun = true;
    } else if (!b) {
      inRun = false;
    }
  }
  return runs;
}
