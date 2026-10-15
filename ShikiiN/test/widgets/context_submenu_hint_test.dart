import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/theme_tokens.dart';
import 'package:shikiin/widgets/context_menu.dart';
import 'package:shikiin/widgets/context_submenu.dart';

void main() {
  testWidgets('带 hint 的子菜单项显示标题与小字', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ContextSubmenu(
          tokens: ThemeTokens.fallback,
          items: const [SubmenuItem(label: '标准', hint: '均衡，推荐日常用')],
          onSelect: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('标准'), findsOneWidget);
    expect(find.text('均衡，推荐日常用'), findsOneWidget);
  });

  testWidgets('checked 项显示勾选图标，未选中不显示', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ContextSubmenu(
          tokens: ThemeTokens.fallback,
          items: const [
            SubmenuItem(label: '关', checked: true),
            SubmenuItem(label: '轻'),
          ],
          onSelect: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('点项回调该项（value 原样带出）', (tester) async {
    SubmenuItem? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ContextSubmenu(
          tokens: ThemeTokens.fallback,
          items: const [SubmenuItem(label: '极', value: 'max')],
          onSelect: (i) => picked = i,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('极'));
    expect(picked?.value, 'max');
  });
}
