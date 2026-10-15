/// `NeoActionChip` 的按下/忙态反馈测试。
///
/// 用户 2026-10-10：「有些地方按下反馈不佳，比如今日推荐的刷新，按下去无响应，
/// 但是有效果因为要获取要点时间」——这些控件原来按下去画面毫无变化，而动作是秒级
/// 网络请求，用户只能判断成"没反应"并反复点。这个文件钉死两层反馈：
/// 按下当帧槽底压深、动作在跑时换文案且不吃重复点击。
library;

import 'dart:async';

import 'package:dsanima/ui/widgets/neo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  testWidgets('按下 → 槽底立刻压深一档；抬手 → 还原', (WidgetTester tester) async {
    await tester
        .pumpWidget(_host(NeoActionChip(label: '换一批 ↻', onTap: () async {})));
    expect(find.text('换一批 ↻'), findsOneWidget);

    // 常态：不覆盖槽底色（用 DsInset 的默认 sunken）。
    expect(tester.widget<DsInset>(find.byType(DsInset)).color, isNull);

    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(find.text('换一批 ↻')));
    await tester.pump();
    expect(tester.widget<DsInset>(find.byType(DsInset)).color, isNotNull,
        reason: '按下当帧必须有可见变化，否则用户以为没点着');

    await gesture.up();
    await tester.pump();
    expect(tester.widget<DsInset>(find.byType(DsInset)).color, isNull);
  });

  testWidgets('动作在跑 → 换成忙态文案，且不响应重复点击', (WidgetTester tester) async {
    int taps = 0;
    final Completer<void> gate = Completer<void>();
    await tester.pumpWidget(_host(NeoActionChip(
      label: '换一批 ↻',
      busyLabel: '换批中…',
      onTap: () async {
        taps++;
        await gate.future;
      },
    )));

    await tester.tap(find.text('换一批 ↻'));
    await tester.pump();
    expect(taps, 1);
    expect(find.text('换批中…'), findsOneWidget);

    // 忙态里再点：不再发第二次请求（连点=连发网络请求，是这些控件最容易踩的坑）。
    await tester.tap(find.text('换批中…'), warnIfMissed: false);
    await tester.pump();
    expect(taps, 1);

    gate.complete();
    // 动作 Future 完成 → finally 里 setState 退出忙态；它的续体在微任务里跑，
    // 所以要多泵一帧（一帧只保证重建，不保证微任务已经落地）。
    await tester.pump();
    await tester.pump();
    expect(find.text('换一批 ↻'), findsOneWidget);
  });

  testWidgets('外部 busy（数据在 provider 里拉）也能进忙态', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const NeoActionChip(
      label: '换一批 ↻',
      busyLabel: '换批中…',
      busy: true,
    )));
    expect(find.text('换批中…'), findsOneWidget);
    expect(find.text('换一批 ↻'), findsNothing);
  });
}
