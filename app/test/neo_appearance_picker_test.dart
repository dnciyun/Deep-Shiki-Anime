/// 外观选择器测试（规范 §5.6：8 格、分组、选中态 = accent 12% 底 + 2px accent 描边）。
library;

import 'package:dsanima/theme/tokens.dart';
import 'package:dsanima/ui/widgets/neo_appearance_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _harness({
  DsAppearance value = DsAppearance.wOrange,
  AppearancePicked? onChanged,
  String prefix = 'appearance',
}) {
  return MaterialApp(
    theme: ThemeData(extensions: <ThemeExtension<dynamic>>[DsTokens.whiteInk]),
    home: Scaffold(
      backgroundColor: DsTokens.whiteInk.base,
      body: NeoAppearancePicker(
        value: value,
        onChanged: onChanged ?? (DsAppearance _, Offset _) {},
        keyPrefix: prefix,
      ),
    ),
  );
}

BoxDecoration _decorationOf(WidgetTester tester, String key) => tester
    .widget<AnimatedContainer>(find.byKey(Key(key)))
    .decoration! as BoxDecoration;

void main() {
  testWidgets('8 套外观各一格，分两行（白色系 / 黑色系）', (WidgetTester tester) async {
    await tester.pumpWidget(_harness());
    for (final DsAppearance a in DsAppearance.values) {
      expect(find.byKey(Key('appearance-${a.code}')), findsOneWidget,
          reason: '缺 ${a.code} 这一格');
      expect(find.text(a.label), findsOneWidget);
    }
    expect(find.text('白色系'), findsOneWidget);
    expect(find.text('黑色系'), findsOneWidget);
  });

  testWidgets('点某一格 → onChanged 收到对应外观', (WidgetTester tester) async {
    DsAppearance? picked;
    await tester.pumpWidget(_harness(onChanged: (DsAppearance a, Offset _) => picked = a));
    await tester.tap(find.byKey(const Key('appearance-b_red')));
    await tester.pumpAndSettle();
    expect(picked, DsAppearance.bRed);
  });

  testWidgets('选中格 = accent 12% 底 + accent 文字 + 2px accent 描边；未选中 = raised + 1px line',
      (WidgetTester tester) async {
    const DsTokens t = DsTokens.whiteInk;
    await tester.pumpWidget(_harness(value: DsAppearance.bNeon));

    final BoxDecoration selected = _decorationOf(tester, 'appearance-b_neon');
    // 选中格用的是**该外观自己的** accent（草稿制下主题还没切，不能跟着当前主题画）。
    expect(selected.color, DsTokens.blackNeon.accentSoft);
    expect((selected.border! as Border).top.width, 2);
    expect((selected.border! as Border).top.color, DsTokens.blackNeon.accent);
    expect(
      tester.widget<Text>(find.text(DsAppearance.bNeon.label)).style!.color,
      DsTokens.blackNeon.accent,
    );

    final BoxDecoration other = _decorationOf(tester, 'appearance-w_orange');
    expect(other.color, t.raised);
    expect((other.border! as Border).top.width, 1);
    expect((other.border! as Border).top.color, t.line);
  });

  testWidgets('每格都有 tooltip（外观名 + 分组名）', (WidgetTester tester) async {
    await tester.pumpWidget(_harness());
    for (final DsAppearance a in DsAppearance.values) {
      final Tooltip tip = tester.widget<Tooltip>(
        find.ancestor(
          of: find.byKey(Key('appearance-${a.code}')),
          matching: find.byType(Tooltip),
        ),
      );
      expect(tip.message, contains(a.label));
      expect(tip.message, contains(a.family.label));
    }
  });

  testWidgets('keyPrefix 让同一页能放多个选择器', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: <ThemeExtension<dynamic>>[DsTokens.whiteInk]),
        home: Scaffold(
          backgroundColor: DsTokens.whiteInk.base,
          body: Column(
            children: <Widget>[
              NeoAppearancePicker(
                value: DsAppearance.wInk,
                onChanged: (DsAppearance _, Offset _) {},
                keyPrefix: 'settings',
              ),
              NeoAppearancePicker(
                value: DsAppearance.bMono,
                onChanged: (DsAppearance _, Offset _) {},
                keyPrefix: 'preview',
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('settings-w_ink')), findsOneWidget);
    expect(find.byKey(const Key('preview-b_mono')), findsOneWidget);
    expect(find.byKey(const Key('appearance-w_ink')), findsNothing);
  });
}
