import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/anime4k_preset.dart';
import 'package:shikiin/models/audio_fx.dart';
import 'package:shikiin/models/player_action.dart';
import 'package:shikiin/models/theme_tokens.dart';
import 'package:shikiin/models/upscale_scheme.dart';
import 'package:shikiin/widgets/context_menu.dart';

Widget _host(List<ContextEntry> entries, {ValueChanged<PlayerAction>? onAction, ValueChanged<String>? onCommand, void Function(String, SubmenuItem)? onSubmenuSelect}) =>
    MaterialApp(
      home: Scaffold(
        body: ContextMenuOverlay(
          tokens: ThemeTokens.fallback,
          entries: entries,
          onAction: onAction ?? (_) {},
          onSubmenuSelect: onSubmenuSelect ?? (_, _) {},
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

  group('子菜单要能收回去（用户 2026-10-19 报的真 bug）', () {
    // 复现路径：悬停「超分」展开子菜单 → 把鼠标移到同级的普通行（例如「视频数据」）。
    // 修复前 `_openSubmenuId` 除了「选中子项」和「整个菜单关掉」永不复位，
    // 于是子菜单一直挂着不消失。
    testWidgets('鼠标从展开的行移到普通行 → 子菜单收起', (tester) async {
      await tester.pumpWidget(_host(defaultContextEntries()));
      await tester.pumpAndSettle();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      // 展开
      await gesture.moveTo(tester.getCenter(find.text('超分')));
      await tester.pumpAndSettle();
      expect(find.text('Anime4K · 标准'), findsOneWidget, reason: '悬停应展开子菜单');

      // 移到普通行：子菜单应收起
      await gesture.moveTo(tester.getCenter(find.text('视频数据')));
      await tester.pumpAndSettle();
      expect(find.text('Anime4K · 标准'), findsNothing, reason: '离开子菜单行后应该收起');
    });

    testWidgets('移到另一个可展开行 → 只显示新展开的那个', (tester) async {
      await tester.pumpWidget(_host(defaultContextEntries(
        audioItems: const [
          SubmenuItem(label: '音轨 A', value: 1),
        ],
      )));
      await tester.pumpAndSettle();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      await gesture.moveTo(tester.getCenter(find.text('超分')));
      await tester.pumpAndSettle();
      expect(find.text('Anime4K · 标准'), findsOneWidget);

      await gesture.moveTo(tester.getCenter(find.text('音轨')));
      await tester.pumpAndSettle();
      expect(find.text('音轨 A'), findsOneWidget);
      expect(find.text('Anime4K · 标准'), findsNothing, reason: '同时只应有一个子菜单');
    });

    testWidgets('鼠标移出整个菜单（到画面上）→ 子菜单收起', (tester) async {
      await tester.pumpWidget(_host(defaultContextEntries()));
      await tester.pumpAndSettle();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      await gesture.moveTo(tester.getCenter(find.text('超分')));
      await tester.pumpAndSettle();
      expect(find.text('Anime4K · 标准'), findsOneWidget);

      // 移出菜单卡片：卡片在 body 左上角（宽 206），所以取右下角很远处。
      // 注意两件事：① 别用 (2,2) 之类的小坐标（还在卡片里）；
      // ② 先 pump 一帧让指针事件把"离开"回调派发完，再推进时间让缓冲计时到点。
      await gesture.moveTo(const Offset(790, 10));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.text('Anime4K · 标准'), findsNothing, reason: '离开菜单后子菜单应收起');
    });

    testWidgets('从菜单行挪进子菜单里 → 不许被缓冲期误收', (tester) async {
      await tester.pumpWidget(_host(defaultContextEntries()));
      await tester.pumpAndSettle();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      await gesture.moveTo(tester.getCenter(find.text('超分')));
      await tester.pumpAndSettle();
      expect(find.text('Anime4K · 标准'), findsOneWidget);

      // 走进子菜单里并停住：期间经过菜单与子菜单之间的间隙
      await gesture.moveTo(tester.getCenter(find.text('Anime4K · 标准')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Anime4K · 标准'), findsOneWidget, reason: '在子菜单里不该被收起');
    });
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

  group('音效子菜单（audio-pack）', () {
    const List<AudioFxPreset> presets = <AudioFxPreset>[
      AudioFxPreset(id: 'audio-a/vocal', name: '人声增强'),
      AudioFxPreset(id: 'audio-a/bass', name: '低音增强'),
    ];

    test('没装音效包 → 「音效」整项不出现（用户 2026-10-19 决定）', () {
      expect(
        defaultContextEntries().any((e) => e.elementId == 'contextMenu.audioFx'),
        isFalse,
      );
    });

    test('有包 → 出现子菜单，第一项是「原声」且默认打勾', () {
      final ContextEntry entry = defaultContextEntries(
        audioFxPresets: presets,
      ).firstWhere((e) => e.elementId == 'contextMenu.audioFx');
      expect(entry.displayLabel, '音效');
      expect(entry.action, isNull, reason: '音效不占 PlayerAction');
      expect(entry.hasSubmenu, isTrue);
      expect(entry.children!.first.label, '原声');
      expect(entry.children!.first.checked, isTrue);
      expect(
        entry.children!.map((SubmenuItem i) => i.label),
        containsAll(<String>['人声增强', '低音增强']),
      );
    });

    test('选中某档 → 该项打勾、原声不勾', () {
      final ContextEntry entry = defaultContextEntries(
        audioFxPresets: presets,
        audioFxSelection: const AudioFxSelection('audio-a/bass'),
      ).firstWhere((e) => e.elementId == 'contextMenu.audioFx');
      final List<SubmenuItem> items = entry.children!;
      expect(items.first.checked, isFalse);
      final SubmenuItem bass = items.firstWhere(
        (SubmenuItem i) =>
            i.value is AudioFxSelection &&
            (i.value! as AudioFxSelection).presetId == 'audio-a/bass',
      );
      expect(bass.checked, isTrue);
    });

    testWidgets('展开「音效」→ 点「人声增强」把 AudioFxSelection 交给播放面', (tester) async {
      String? elementId;
      SubmenuItem? selected;
      final List<ContextEntry> entries = defaultContextEntries(audioFxPresets: presets);
      await tester.pumpWidget(_host(
        entries,
        onSubmenuSelect: (String id, SubmenuItem item) {
          elementId = id;
          selected = item;
        },
      ));
      await tester.pumpAndSettle();
      final TestGesture gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.text('音效')));
      await tester.pumpAndSettle();
      expect(find.text('原声'), findsOneWidget);
      await tester.tap(find.text('人声增强'));
      await tester.pumpAndSettle();
      expect(elementId, 'contextMenu.audioFx');
      expect(selected!.value, const AudioFxSelection('audio-a/vocal'));
    });
  });
}
