import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/theme_tokens.dart';
import 'package:shikiin/widgets/context_menu.dart';

void main() {
  // 回归：子菜单卡片必须贴内容收窄，不能被 CompositedTransformFollower 的全屏 tight
  // 约束撑成整屏大框（曾经 800x600）。
  testWidgets('submenu card hugs its content (not a full-screen box)', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ContextMenuOverlay(
          tokens: ThemeTokens.fallback,
          entries: [
            ContextEntry.submenu(
              label: '画面适配',
              icon: Icons.aspect_ratio_rounded,
              elementId: 'contextMenu.videoFit',
              children: const [
                SubmenuItem(label: '保持比例', checked: true),
                SubmenuItem(label: '填充裁切'),
                SubmenuItem(label: '拉伸'),
              ],
            ),
          ],
          onAction: (_) {},
          onSubmenuSelect: (_, _) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('画面适配')));
    await tester.pumpAndSettle();

    // 可见卡片 = IntrinsicWidth 内的 Container。
    final card = tester.getSize(find.descendant(
        of: find.byType(IntrinsicWidth), matching: find.byType(Container)).first);
    expect(card.width, lessThanOrEqualTo(240), reason: '子菜单卡片不应超过 maxWidth=240');
    expect(card.height, lessThan(300), reason: '三个短项不应撑高成大框');
  });
}
