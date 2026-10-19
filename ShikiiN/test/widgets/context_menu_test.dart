import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/anime4k_preset.dart';
import 'package:shikiin/models/player_action.dart';
import 'package:shikiin/models/theme_tokens.dart';
import 'package:shikiin/models/upscale_scheme.dart';
import 'package:shikiin/widgets/context_menu.dart';

Widget _host(List<ContextEntry> entries, {ValueChanged<PlayerAction>? onAction, ValueChanged<String>? onCommand}) =>
    MaterialApp(
      home: Scaffold(
        body: ContextMenuOverlay(
          tokens: ThemeTokens.fallback,
          entries: entries,
          onAction: onAction ?? (_) {},
          onSubmenuSelect: (_, _) {},
          onCommand: onCommand,
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

  testWidgets('超分子菜单：关 + Anime4K 三档 + Anime4K-Ultra，勾选当前项', (tester) async {
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
    expect(find.text('Anime4K-Ultra · 保颗粒'), findsOneWidget);
    // 当前是「极致」：Anime4K 三档里只有它被勾选，随包方案不带勾。
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

  group('NV-VSR 开关行（契约外的探针能力）', () {
    test('没有能力 → 菜单里没有这一项', () {
      final entries = defaultContextEntries();
      expect(entries.any((e) => e.elementId == 'contextMenu.nvVsr'), isFalse);
    });

    test('有能力且开着 → 文案是「关闭 NV-VSR」', () {
      final entry = defaultContextEntries(nvVsrAvailable: true, nvVsrEnabled: true)
          .firstWhere((e) => e.elementId == 'contextMenu.nvVsr');
      expect(entry.displayLabel, '关闭 NV-VSR');
      // 它必须是**命令条目**：不能占 PlayerAction（那份契约被 neo_guard 钉死为 19 项）。
      expect(entry.action, isNull);
      expect(entry.hasSubmenu, isFalse);
    });

    test('有能力但关着 → 文案是「开启 NV-VSR」', () {
      final entry = defaultContextEntries(nvVsrAvailable: true, nvVsrEnabled: false)
          .firstWhere((e) => e.elementId == 'contextMenu.nvVsr');
      expect(entry.displayLabel, '开启 NV-VSR');
    });

    testWidgets('点它 → onCommand 收到 elementId（不走 onAction）', (tester) async {
      PlayerAction? fired;
      String? command;
      await tester.pumpWidget(_host(
        defaultContextEntries(nvVsrAvailable: true, nvVsrEnabled: true),
        onAction: (a) => fired = a,
        onCommand: (id) => command = id,
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭 NV-VSR'));
      expect(command, 'contextMenu.nvVsr');
      expect(fired, isNull, reason: '命令条目不该落进 PlayerAction 分支');
    });
  });
}
