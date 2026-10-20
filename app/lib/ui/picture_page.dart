/// 「画面调节」页（2026-10-20，用户：「给插件里的画面调节包…做独立页面，侧边栏进入，
/// 去除原本的设置位置」）。
///
/// 这一页**没有画面可看**：主窗口一个 mpv 都没有（播放窗口是独立引擎，用户 2026-10-10
/// 的硬要求），所以它是纯粹的配置台。页面上那句"改动立刻推给正在播放的窗口"不是客套话，
/// 而是这一页最容易被误解的地方 —— 用户看不到画面变化时，必须知道为什么。
///
/// 三条它**不做**的事（spec §3 / §8）：
/// * 不做预览（没有视频可播）；
/// * 不自己算夹值/量化（一律交给 `PictureParam.clampValue`，否则界面显示的数和渲染用的数
///   会漂成两份）；
/// * 不直接摸渲染/mpv（那一切都发生在播放窗口，见 `state/picture_editor.dart` 的文件头）。
///
/// 生效链路（方案 A，文件是唯一真相）：
/// 拖动/点预设 → 编辑器改内存（防抖 220ms，松手立刻一次）→ 写 `picture-settings.json`
/// → 发 `pictureChanged`（只带"变了"）→ 播放窗口重读文件 + 重读组合 → 重渲染 + 重挂链。
library;

import 'dart:async';
import 'dart:io';

import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/picture_combo.dart';
import '../state/extension_settings.dart';
import '../state/extensions.dart' show extensionsProvider;
import '../state/infra.dart' show supportDirProvider;
import '../state/packs_available.dart';
import '../state/picture_editor.dart';
import '../state/picture_pack.dart';
import '../state/providers.dart' show ShellTab, navProvider;
import '../theme/tokens.dart';
import 'widgets/ds_cards.dart';
import 'widgets/hues.dart';

// ── 测试锚点（都从这里导出，别在测试里手抄字符串）──────────────────────────────
//
// 为什么用 `ds-picture-*` 这个前缀：与设置页的 `dsSettings*` / 扩展页的
// `dsExtension*` 同一个命名习惯，测试里一眼能看出"这属于哪一页"。

/// 整页根节点。
const Key dsPicturePageKey = ValueKey<String>('ds-picture-page');

/// 「去扩展页管理」（页头那一行）。
const Key dsPictureManageKey = ValueKey<String>('ds-picture-manage');

/// 「关」chip。
const Key dsPictureOffKey = ValueKey<String>('ds-picture-off');

/// 「管理可见性」入口（预设 chips 末尾）。
const Key dsPictureVisibilityKey = ValueKey<String>('ds-picture-visibility');

/// 可见性对话框的「保存」。
const Key dsPictureVisibilitySaveKey = ValueKey<String>('ds-picture-visibility-save');

/// 「存为我的组合」。
const Key dsPictureSaveComboKey = ValueKey<String>('ds-picture-save-combo');

/// 命名对话框里的输入框 / 保存键。
const Key dsPictureComboNameKey = ValueKey<String>('ds-picture-combo-name');
const Key dsPictureComboSaveKey = ValueKey<String>('ds-picture-combo-save');

/// 「删除这个组合」/「重置为包默认」。
const Key dsPictureDeleteComboKey = ValueKey<String>('ds-picture-delete-combo');
const Key dsPictureResetKey = ValueKey<String>('ds-picture-reset');

/// 某个包的 chip。
Key dsPicturePackKey(String packId) => ValueKey<String>('ds-picture-pack-$packId');

/// 某个包自带预设的 chip。
Key dsPicturePresetKey(String presetId) =>
    ValueKey<String>('ds-picture-preset-$presetId');

/// 某个「我的组合」的 chip（[comboId] 是组合自己的 id，不是菜单里的全局 id）。
Key dsPictureComboKey(String comboId) =>
    ValueKey<String>('ds-picture-combo-$comboId');

/// 某个参数的滑杆。
Key dsPictureSliderKey(String paramKey) =>
    ValueKey<String>('ds-picture-slider-$paramKey');

/// 可见性对话框里某一档的勾选框。
Key dsPictureVisibilityToggleKey(String presetId) =>
    ValueKey<String>('ds-picture-visibility-$presetId');

class PicturePage extends ConsumerStatefulWidget {
  const PicturePage({super.key});

  @override
  ConsumerState<PicturePage> createState() => _PicturePageState();
}

class _PicturePageState extends ConsumerState<PicturePage> {
  @override
  void initState() {
    super.initState();
    // postFrame：首帧之前改 provider 状态会撞 Riverpod 的"build 期不许改状态"。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final Directory? dir = ref.read(supportDirProvider);
      if (dir != null) {
        // 预设可见性要从 `extension-settings.json` 读（谁关掉了哪几档）。
        unawaited(ref.read(extensionUserSettingsProvider.notifier).ensureLoaded(dir));
      }
      // 直接深链进这一页（没走过侧栏那次探测）时也把包扫一次。
      unawaited(ref.read(packAvailabilityProvider.notifier).ensureLoaded());
      unawaited(ref.read(pictureEditorProvider.notifier).ensureLoaded());
    });
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final PictureEditorState editor = ref.watch(pictureEditorProvider);
    final String? packName = editor.editingPack?.name;
    return ListView(
      key: dsPicturePageKey,
      padding: EdgeInsets.fromLTRB(t.spacing, t.spacing, t.spacing, t.spacing * 2),
      children: <Widget>[
        DsSection(
          title: '画面调节',
          hue: hueOfTab(ShellTab.picture),
          subtitle: '画面调节包 · 预设与滑杆 · 我的组合',
          // 页头那一行「<包名> · 去扩展页管理」（spec §3 第 1 条）：入口在管理页里，
          // 但用户"想调一下"应该在这一页就能看到自己调的是哪个包、从哪儿去管它。
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (packName != null)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(
                    '$packName · ',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
                  ),
                ),
              TextButton(
                key: dsPictureManageKey,
                onPressed: _gotoExtensions,
                child: const Text('去扩展页管理'),
              ),
            ],
          ),
          child: _body(t, editor),
        ),
      ],
    );
  }

  // ── 主体 ──────────────────────────────────────────────────────────────────

  Widget _body(DsTokens t, PictureEditorState editor) {
    final PicturePack? pack = editor.editingPack;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 一句实话：没有画面可看这件事必须写在最上面，否则用户会以为"调了没反应"。
        Text(
          '主窗口没有画面，改动会立刻推给正在播放的窗口；没开播放窗口时下次开播生效。',
          style: TextStyle(color: t.text2, fontSize: DsTypeScale.caption, height: 1.5),
        ),
        const SizedBox(height: 12),
        if (!editor.loaded)
          Text(
            '正在读画面设置…',
            style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
          )
        else if (pack == null)
          _emptyState(t, editor)
        else ...<Widget>[
          if (editor.packs.length > 1) ...<Widget>[
            _packChips(t, editor),
            const SizedBox(height: 12),
          ],
          _presetChips(t, editor, pack),
          const SizedBox(height: 16),
          ..._sliders(t, editor, pack),
          const SizedBox(height: 12),
          _actions(t, editor, pack),
        ],
      ],
    );
  }

  /// 没有可用的包（清单坏 / 模板缺 / 还没装）：一句说明 + 去扩展页，绝不留一片空白。
  Widget _emptyState(DsTokens t, PictureEditorState editor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          editor.problem ?? '没有可用的画面调节包',
          style: TextStyle(color: t.text2, fontSize: DsTypeScale.secondary, height: 1.6),
        ),
        const SizedBox(height: 8),
        Text(
          '装好之后回到这一页就能选预设、拖滑杆；播放窗口开着的话会当场生效。',
          style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption, height: 1.5),
        ),
      ],
    );
  }

  /// 多包才出包选择器（单包时 chips 纯属噪音，spec §3 第 3 条）。
  Widget _packChips(DsTokens t, PictureEditorState editor) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final PicturePack pack in editor.packs)
          _chip(
            t,
            pack.name,
            key: dsPicturePackKey(pack.id),
            selected: editor.editingPack?.id == pack.id,
            onTap: () => ref.read(pictureEditorProvider.notifier).selectPack(pack.id),
          ),
      ],
    );
  }

  /// 「关」+ 包自带预设 + 「我的 · 组合」+ 可见性入口。
  Widget _presetChips(DsTokens t, PictureEditorState editor, PicturePack pack) {
    final String? presetId = editor.settings.presetId;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        _chip(
          t,
          '关',
          key: dsPictureOffKey,
          selected: editor.isOff,
          onTap: () => ref.read(pictureEditorProvider.notifier).turnOff(),
        ),
        for (final core.PicturePreset preset in pack.spec.presets)
          _chip(
            t,
            preset.name,
            key: dsPicturePresetKey(preset.id),
            selected: !editor.isOff && presetId == preset.id,
            onTap: () => ref.read(pictureEditorProvider.notifier).applyPreset(preset.id),
          ),
        for (final PictureCombo combo in editor.currentCombos)
          _chip(
            t,
            '我的 · ${combo.name}',
            key: dsPictureComboKey(combo.id),
            selected: !editor.isOff && presetId == '$kPictureComboPrefix${combo.id}',
            onTap: () =>
                ref.read(pictureEditorProvider.notifier).applyCombo(combo.id),
          ),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: dsPictureVisibilityKey,
            onTap: _openVisibilityDialog,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Text(
                '管理可见性',
                style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 按 `param.group` 分组的滑杆（组顺序 = 清单里第一次出现的顺序）。
  List<Widget> _sliders(DsTokens t, PictureEditorState editor, PicturePack pack) {
    final List<String> groups = <String>[];
    for (final core.PictureParam param in pack.spec.params) {
      if (!groups.contains(param.group)) groups.add(param.group);
    }
    return <Widget>[
      for (final String group in groups) ...<Widget>[
        if (group.isNotEmpty) ...<Widget>[
          Text(
            group,
            style: TextStyle(
              color: t.text2,
              fontSize: DsTypeScale.caption,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
        ],
        for (final core.PictureParam param in pack.spec.params)
          if (param.group == group)
            _sliderRow(t, editor, pack, param),
      ],
    ];
  }

  Widget _sliderRow(
    DsTokens t,
    PictureEditorState editor,
    PicturePack pack,
    core.PictureParam param,
  ) {
    // 取不到取值（理论上不会：`values` 总是"默认值 + 覆盖"）就退回默认值 ——
    // 滑杆的 value 必须在 [min, max] 内，否则 Slider 会断言。
    final double value = editor.values[param.key] ?? param.defaultValue;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 96,
          child: Text(
            param.label,
            style: TextStyle(color: t.text, fontSize: DsTypeScale.caption),
          ),
        ),
        Expanded(
          child: Slider(
            key: dsPictureSliderKey(param.key),
            value: value.clamp(param.min, param.max).toDouble(),
            min: param.min,
            max: param.max,
            divisions: _divisionsOf(param),
            // 每帧只改内存（编辑器自己在 220ms 后落盘 + 推送）；
            // 松手立刻一次，所以手感是"松手即生效"。
            onChanged: (double next) {
              ref.read(pictureEditorProvider.notifier).setValue(param.key, next);
            },
            onChangeEnd: (double _) {
              unawaited(ref.read(pictureEditorProvider.notifier).commit());
            },
          ),
        ),
        SizedBox(
          width: 60,
          child: Text(
            '${_formatValue(value)}${param.unit}',
            textAlign: TextAlign.right,
            style: TextStyle(color: t.text2, fontSize: DsTypeScale.caption),
          ),
        ),
      ],
    );
  }

  /// 底部动作：存为组合 / 删除当前组合 / 重置为包默认。
  Widget _actions(DsTokens t, PictureEditorState editor, PicturePack pack) {
    final String? activeComboId = _activeComboId(editor);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        OutlinedButton.icon(
          key: dsPictureSaveComboKey,
          onPressed: _promptSaveCombo,
          icon: const Icon(Icons.bookmark_add_outlined, size: 16),
          label: const Text('存为我的组合'),
        ),
        OutlinedButton.icon(
          key: dsPictureDeleteComboKey,
          onPressed: activeComboId == null
              ? null
              : () => ref.read(pictureEditorProvider.notifier).deleteCombo(activeComboId),
          icon: const Icon(Icons.bookmark_remove_outlined, size: 16),
          label: const Text('删除这个组合'),
        ),
        OutlinedButton.icon(
          key: dsPictureResetKey,
          onPressed: () => ref.read(pictureEditorProvider.notifier).resetPack(),
          icon: const Icon(Icons.restart_alt, size: 16),
          label: const Text('重置为包默认'),
        ),
      ],
    );
  }

  // ── 动作 ──────────────────────────────────────────────────────────────────

  void _gotoExtensions() {
    ref.read(navProvider.notifier).select(ShellTab.extensions);
  }

  /// 当前亮着的组合 id（没亮着 = null：删除按钮据此禁用）。
  String? _activeComboId(PictureEditorState editor) {
    final String? presetId = editor.settings.presetId;
    if (presetId == null || !presetId.startsWith(kPictureComboPrefix)) return null;
    final String comboId = presetId.substring(kPictureComboPrefix.length);
    for (final PictureCombo combo in editor.currentCombos) {
      if (combo.id == comboId) return comboId;
    }
    return null;
  }

  Future<void> _promptSaveCombo() async {
    // 不用 `TextEditingController`：对话框的退场动画期间 TextField 还会重建，
    // 而控制器一旦提前 dispose 就会撞 "used after being disposed"（真机上就是一片红）。
    // 用 `onChanged` 记下文本，生命周期问题从源头上不存在。
    String typed = '';
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('存为我的组合'),
        content: TextField(
          key: dsPictureComboNameKey,
          autofocus: true,
          decoration: const InputDecoration(hintText: '例如：夜间'),
          onChanged: (String value) => typed = value,
          onSubmitted: (String value) => Navigator.of(ctx).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: dsPictureComboSaveKey,
            onPressed: () => Navigator.of(ctx).pop(typed),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    final String trimmed = (name ?? '').trim();
    if (trimmed.isEmpty) return; // 空名字不存（编辑器那边也返回 null）
    await ref.read(pictureEditorProvider.notifier).saveCombo(trimmed);
  }

  /// 预设可见性（spec §5：扩展页删掉的那个能力搬到这里，否则等于悄悄丢功能）。
  ///
  /// ⚠️ 列表必须用**不过滤**的包：`packAvailabilityProvider` 里那份已经摘掉了用户关掉的
  /// 预设 —— 只列它的话，"已经被关掉的那几档"永远看不到，也就永远打不开。
  Future<void> _openVisibilityDialog() async {
    final PictureEditorState editor = ref.read(pictureEditorProvider);
    final PicturePack? pack = editor.editingPack;
    if (pack == null) return;

    List<core.PicturePreset> presets = pack.spec.presets;
    final Directory? dir = ref.read(supportDirProvider);
    if (dir != null) {
      try {
        for (final PicturePack candidate in await loadPicturePacks(dir)) {
          if (candidate.id == pack.id) presets = candidate.spec.presets;
        }
      } catch (error) {
        // 重扫失败就用过滤过的那份（最多是"看不到已关掉的那几档"，功能不崩）。
        debugPrint('[picture] 读全量预设失败（只能用当前可见的）：$error');
      }
    }
    if (!mounted) return;
    if (presets.isEmpty) {
      // 这个包没有声明预设（只有滑杆）：没有可关的东西，说一句而不是静默。
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('这个包没有预设可以关')),
      );
      return;
    }

    final Set<String> hidden =
        ref.read(extensionUserSettingsProvider).hiddenPresetsOf(pack.id);
    final Map<String, bool> draft = <String, bool>{
      for (final core.PicturePreset preset in presets) preset.id: !hidden.contains(preset.id),
    };

    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) => AlertDialog(
          title: const Text('预设可见性'),
          content: SizedBox(
            width: 360,
            child: ListView(
              shrinkWrap: true,
              children: <Widget>[
                for (final core.PicturePreset preset in presets)
                  CheckboxListTile(
                    key: dsPictureVisibilityToggleKey(preset.id),
                    dense: true,
                    value: draft[preset.id] ?? true,
                    title: Text(preset.name),
                    onChanged: (bool? checked) =>
                        setLocal(() => draft[preset.id] = checked ?? true),
                  ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: dsPictureVisibilitySaveKey,
              // 什么算"关掉"：勾掉的那些。全部勾上 = 一个都不关（不是"没设置过"，
              // 但结果一样：菜单列全部）。
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;

    final Set<String> nextHidden = <String>{
      for (final MapEntry<String, bool> entry in draft.entries)
        if (!entry.value) entry.key,
    };
    await ref
        .read(extensionUserSettingsProvider.notifier)
        .setHiddenPresets(pack.id, nextHidden);
    // 版本号 +1：侧栏可用性、播放窗口的菜单都会跟着重扫（否则关掉的预设下次开播才消失）。
    ref.read(extensionsProvider.notifier).bumpRevision();
  }

  // ── 小组件 ────────────────────────────────────────────────────────────────

  Widget _chip(
    DsTokens t,
    String label, {
    required bool selected,
    required VoidCallback onTap,
    Key? key,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          key: key,
          padding: EdgeInsets.symmetric(horizontal: t.spacing, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? t.accent : t.sunken,
            borderRadius: BorderRadius.circular(t.radiusPill),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? t.onAccent : t.text,
              fontSize: DsTypeScale.caption,
            ),
          ),
        ),
      ),
    );
  }

  /// 滑杆的档位数：`step` 决定，算不出来（step ≤ 0 / 太多档）就不分段。
  int? _divisionsOf(core.PictureParam param) {
    if (param.step <= 0) return null;
    final double count = (param.max - param.min) / param.step;
    if (!count.isFinite || count <= 0 || count > 1000) return null;
    return count.round();
  }

  /// 数值显示：整数就不带小数点，否则两位小数（与 `clampValue` 的量化一致，不会再长）。
  String _formatValue(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toStringAsFixed(2);
}
