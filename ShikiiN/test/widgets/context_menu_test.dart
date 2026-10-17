import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/anime4k_preset.dart';
import 'package:shikiin/models/player_action.dart';
import 'package:shikiin/models/theme_tokens.dart';
import 'package:shikiin/models/upscale_scheme.dart';
import 'package:shikiin/widgets/context_menu.dart';

Widget _host(List<ContextEntry> entries, {ValueChanged<PlayerAction>? onAction}) => MaterialApp(
      home: Scaffold(
        body: ContextMenuOverlay(
          tokens: ThemeTokens.fallback,
          entries: entries,
          onAction: onAction ?? (_) {},
          onSubmenuSelect: (_, _) {},
        ),
      ),
    );

void main() {
  testWidgets('默认 8 项：全屏/画中画/窗口置顶/音轨/字幕轨/加载字幕文件/超分/视频数据',
      (tester) async {
    await tester.pumpWidget(_host(defaultContextEntries()));
    await tester.pumpAndSettle();
    for (final label in ['全屏', '画中画', '窗口置顶', '音轨', '字幕轨', '加载字幕文件…', '超分', '视频数据']) {
      expect(find.text(label), findsOneWidget, reason: '缺少菜单项 $label');
    }
  });

  testWidgets('点「全屏」触发 toggleFullscreen', (tester) async {
    PlayerAction? fired;
    await tester.pumpWidget(_host(defaultContextEntries(), onAction: (a) => fired = a));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全屏'));
    expect(fired, PlayerAction.toggleFullscreen);
  });

  testWidgets('全屏/置顶态下文案切换', (tester) async {
    await tester.pumpWidget(_host(defaultContextEntries(fullscreen: true, alwaysOnTop: true)));
    await tester.pumpAndSettle();
    expect(find.text('退出全屏'), findsOneWidget);
    expect(find.text('取消置顶'), findsOneWidget);
  });

  testWidgets('超分子菜单：关 + Anime4K 三档 + mpv 缩放器方案，勾选当前项', (tester) async {
    await tester.pumpWidget(_host(defaultContextEntries(
      upscale: const UpscaleSelection(preset: Anime4kPreset.ultra),
    )));
    await tester.pumpAndSettle();
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('超分')));
    await tester.pumpAndSettle();
    expect(find.text('关'), findsOneWidget);
    expect(find.text('Anime4K · 轻量'), findsOneWidget);
    expect(find.text('Anime4K · 标准'), findsOneWidget);
    expect(find.text('Anime4K · 极致'), findsOneWidget);
    expect(find.text('mpv · EWA Lanczos Sharp'), findsOneWidget);
    // 当前是「极致」：Anime4K 三档里只有它被勾选，mpv 方案不带勾。
    final items = defaultContextEntries(
      upscale: const UpscaleSelection(preset: Anime4kPreset.ultra),
    ).where((e) => e.elementId == 'contextMenu.upscale').single.children!;
    expect(items.where((i) => i.checked).length, 1);
    expect(items.firstWhere((i) => i.checked).label, 'Anime4K · 极致');
  });

  testWidgets('子菜单选择回调带出 elementId 与 UpscaleSelection', (tester) async {
    String? gotId;
    Object? gotValue;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ContextMenuOverlay(
          tokens: ThemeTokens.fallback,
          entries: [
            ContextEntry.submenu(
              label: '超分',
              icon: Icons.auto_awesome_rounded,
              elementId: 'contextMenu.upscale',
              children: [
                SubmenuItem(
                  label: 'Anime4K · 轻量',
                  value: const UpscaleSelection(preset: Anime4kPreset.light),
                ),
                SubmenuItem(
                  label: 'Anime4K · 标准',
                  checked: true,
                  value: const UpscaleSelection(preset: Anime4kPreset.standard),
                ),
              ],
            ),
          ],
          onAction: (_) {},
          onSubmenuSelect: (id, item) {
            gotId = id;
            gotValue = item.value;
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('超分')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anime4K · 标准'));
    await tester.pumpAndSettle();
    expect(gotId, 'contextMenu.upscale');
    expect(gotValue, const UpscaleSelection(preset: Anime4kPreset.standard));
  });

  testWidgets('头尾与连续分隔线被清理（不留空杆）', (tester) async {
    await tester.pumpWidget(_host(const [
      ContextEntry.divider(),
      ContextEntry.action(PlayerAction.toggleFullscreen, Icons.fullscreen_rounded,
          elementId: 'contextMenu.fullscreen', label: '全屏'),
      ContextEntry.divider(),
      ContextEntry.divider(),
      ContextEntry.action(PlayerAction.toggleStats, Icons.monitor_heart_outlined,
          elementId: 'contextMenu.stats', label: '视频数据'),
      ContextEntry.divider(),
    ]));
    await tester.pumpAndSettle();
    expect(find.byType(Divider), findsOneWidget);
  });
}
