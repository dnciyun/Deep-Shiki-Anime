import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/anime4k_preset.dart';
import 'package:shikiin/models/player_action.dart';
import 'package:shikiin/models/theme_tokens.dart';
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

  testWidgets('超分子菜单列出四档且勾选当前档', (tester) async {
    await tester.pumpWidget(_host(defaultContextEntries(anime4k: Anime4kPreset.ultra)));
    await tester.pumpAndSettle();
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('超分')));
    await tester.pumpAndSettle();
    expect(find.text('关'), findsOneWidget);
    expect(find.text('轻'), findsOneWidget);
    expect(find.text('标'), findsOneWidget);
    expect(find.text('极'), findsOneWidget);
  });

  testWidgets('子菜单选择回调带出 elementId 与 value', (tester) async {
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
              elementId: 'contextMenu.anime4k',
              children: const [
                SubmenuItem(label: '轻', value: Anime4kPreset.light),
                SubmenuItem(label: '标', checked: true, value: Anime4kPreset.standard),
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
    await tester.tap(find.text('标'));
    await tester.pumpAndSettle();
    expect(gotId, 'contextMenu.anime4k');
    expect(gotValue, Anime4kPreset.standard);
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
