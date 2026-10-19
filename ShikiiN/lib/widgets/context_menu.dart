import 'package:flutter/material.dart';
import '../models/anime4k_preset.dart';
import '../models/player_action.dart';
import '../models/theme_tokens.dart';
import '../models/track.dart';
import '../models/picture_menu.dart';
import '../models/upscale_scheme.dart';
import 'context_submenu.dart';

/// 子菜单项。`value` 由调用方解释（轨道 id / 超分档 / 画面适配模式）。
class SubmenuItem {
  final String label;
  final bool checked;
  final Object? value;

  /// 稳定标识（主题显隐系统已删，保留给调用方做定位/测试）。
  final String? elementId;

  /// 小字注释（效果说明）。
  final String? hint;

  /// 非空时此项是一个可展开的「子子组」。
  final List<SubmenuItem>? children;

  const SubmenuItem({
    required this.label,
    this.checked = false,
    this.value,
    this.elementId,
    this.hint,
    this.children,
  });

  bool get isGroup => children != null && children!.isNotEmpty;
}

class ContextEntry {
  final PlayerAction? action;
  final String label;
  final IconData icon;
  final String elementId;
  final List<SubmenuItem>? children;
  final bool isDivider;

  const ContextEntry._(this.action, this.label, this.icon, this.elementId, this.children,
      {this.isDivider = false});

  const ContextEntry.action(PlayerAction action, IconData icon,
      {required String elementId, String label = ''})
      : this._(action, label, icon, elementId, null);

  factory ContextEntry.submenu({
    required String label,
    required IconData icon,
    required String elementId,
    required List<SubmenuItem> children,
  }) =>
      ContextEntry._(null, label, icon, elementId, children);

  /// 普通命令条目：**不占 [PlayerAction]**，点击时按 [elementId] 交给
  /// `ContextMenuOverlay.onCommand`。
  ///
  /// 为什么需要它：`PlayerAction` 的取值被 `neo_guard_test` 钉死为「契约保留的 19 个」，
  /// 临时 / 探针能力（例如 NV-VSR 开关）不该为了一个菜单项去改那份契约。
  const ContextEntry.command({
    required String label,
    required IconData icon,
    required String elementId,
  }) : this._(null, label, icon, elementId, null);

  /// 分组分隔线（不可点击）。
  const ContextEntry.divider() : this._(null, '', Icons.remove, '', null, isDivider: true);

  bool get hasSubmenu => children != null && children!.isNotEmpty;

  String get displayLabel => label.isNotEmpty ? label : (action?.label ?? '');
}

/// 右键菜单（契约 §7，8 项）：全屏 / 画中画 / 窗口置顶 / —— / 音轨 ▸ / 字幕轨 ▸ /
/// 加载字幕文件… / —— / 超分 ▸ / 视频数据。
///
/// 不再读主题显隐配置：所有项恒显示，`elementId` 仅作稳定标识。
///
/// 2026-10-17：「超分」子菜单从固定四档扩成 **方案 + 档位**；经用户真机筛选后
/// 只剩 关 / Anime4K 三档 / Anime4K-Ultra（mpv 缩放器、ACNet、ARNet、FSR、RCAS 已删）。
List<ContextEntry> defaultContextEntries({
  List<SubmenuItem> audioItems = const [],
  List<SubmenuItem> subtitleItems = const [],
  UpscaleSelection upscale = UpscaleSelection.off,
  List<UpscaleScheme>? upscaleSchemes,
  PictureMenu? pictureMenu,
  bool alwaysOnTop = false,
  bool fullscreen = false,
  bool pip = false,
  /// 本构建有没有 NV-VSR 能力（没有就不显示这一项）。
  bool nvVsrAvailable = false,
  /// VSR 当前开着还是关着（决定文案是「关闭」还是「开启」）。
  bool nvVsrEnabled = false,
}) {
  final List<UpscaleScheme> schemes = upscaleSchemes ?? builtinUpscaleSchemes();
  return [
    ContextEntry.action(
      PlayerAction.toggleFullscreen,
      fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
      elementId: 'contextMenu.fullscreen',
      label: fullscreen ? '退出全屏' : '全屏',
    ),
    ContextEntry.action(
      PlayerAction.togglePip,
      Icons.picture_in_picture_alt_rounded,
      elementId: 'contextMenu.pip',
      label: pip ? '退出画中画' : '画中画',
    ),
    ContextEntry.action(
      PlayerAction.toggleAlwaysOnTop,
      alwaysOnTop ? Icons.push_pin_rounded : Icons.push_pin_outlined,
      elementId: 'contextMenu.alwaysOnTop',
      label: alwaysOnTop ? '取消置顶' : '窗口置顶',
    ),
    const ContextEntry.divider(),
    ContextEntry.submenu(
      label: '音轨',
      icon: Icons.audiotrack_rounded,
      elementId: 'contextMenu.audioTrack',
      children: audioItems,
    ),
    ContextEntry.submenu(
      label: '字幕轨',
      icon: Icons.subtitles_rounded,
      elementId: 'contextMenu.subtitleTrack',
      children: subtitleItems,
    ),
    ContextEntry.action(
      PlayerAction.openSubtitleFile,
      Icons.folder_open_rounded,
      elementId: 'contextMenu.openSubtitleFile',
      label: '加载字幕文件…',
    ),
    const ContextEntry.divider(),
    ContextEntry.submenu(
      label: '超分',
      icon: Icons.auto_awesome_rounded,
      elementId: 'contextMenu.upscale',
      children: upscaleSubmenuItems(upscale, schemes),
    ),
    if (pictureMenu != null && pictureMenu.params.isNotEmpty)
      ContextEntry.submenu(
        label: '画面调节',
        icon: Icons.tune_rounded,
        elementId: 'contextMenu.picture',
        children: pictureSubmenuItems(pictureMenu),
      ),
    // NV-VSR（NVIDIA 超分）：只在「本构建真有这条滤镜能力」时出现，直接一行开关。
    // 它和「超分」子菜单里的 Anime4K 方案是叠加关系（vf 滤镜链 vs glsl-shaders），
    // 所以放在这一层而不是塞进超分子菜单里。
    if (nvVsrAvailable)
      ContextEntry.command(
        label: nvVsrEnabled ? '关闭 NV-VSR' : '开启 NV-VSR',
        icon: nvVsrEnabled ? Icons.hd_rounded : Icons.hd_outlined,
        elementId: 'contextMenu.nvVsr',
      ),
    ContextEntry.action(
      PlayerAction.toggleStats,
      Icons.monitor_heart_outlined,
      elementId: 'contextMenu.stats',
      label: '视频数据',
    ),
  ];
}

/// 「超分」子菜单项：关 + Anime4K 三档 + Anime4K-Ultra。
List<SubmenuItem> upscaleSubmenuItems(
  UpscaleSelection current,
  List<UpscaleScheme> schemes,
) {
  final List<SubmenuItem> items = [
    SubmenuItem(
      label: '关',
      checked: current.isOff,
      value: UpscaleSelection.off,
      elementId: 'upscale.off',
    ),
  ];
  for (final UpscaleScheme scheme in schemes) {
    if (scheme.isAnime4k) {
      for (final UpscaleTier tier in scheme.tiers) {
        final Anime4kPreset preset =
            Anime4kPreset.values.asNameMap()[tier.id] ?? Anime4kPreset.off;
        items.add(SubmenuItem(
          label: 'Anime4K · ${tier.label}',
          checked: current.schemeId == scheme.id && current.preset == preset,
          value: UpscaleSelection(preset: preset),
          hint: preset.hint,
          elementId: 'upscale.${scheme.id}.${tier.id}',
        ));
      }
    } else {
      items.add(SubmenuItem(
        label: scheme.name,
        checked: current.schemeId == scheme.id,
        value: UpscaleSelection(schemeId: scheme.id),
        hint: scheme.note,
        elementId: 'upscale.${scheme.id}',
      ));
    }
  }
  return items;
}

/// 轨道子菜单项：`value` 是 `int?` 轨道 id（null = 关闭字幕 / 自动选音轨）。
List<SubmenuItem> trackSubmenuItems(List<TrackInfo> tracks, int? activeId,
        {String noneLabel = '关闭'}) =>
    [
      SubmenuItem(label: noneLabel, checked: activeId == null, value: null),
      for (final t in tracks)
        SubmenuItem(label: t.label, checked: t.id == activeId, value: t.id),
    ];

/// 右键菜单项对应的可寻址元素 id（保留：稳定标识，主题显隐已删）。
String contextElementId(PlayerAction a) {
  switch (a) {
    case PlayerAction.toggleFullscreen:
      return 'contextMenu.fullscreen';
    case PlayerAction.togglePip:
      return 'contextMenu.pip';
    case PlayerAction.toggleAlwaysOnTop:
      return 'contextMenu.alwaysOnTop';
    case PlayerAction.toggleStats:
      return 'contextMenu.stats';
    case PlayerAction.openSubtitleFile:
      return 'contextMenu.openSubtitleFile';
    case PlayerAction.openSettings:
      return 'contextMenu.settings';
    default:
      return 'contextMenu.${a.name}';
  }
}

class ContextMenuOverlay extends StatefulWidget {
  final ThemeTokens tokens;
  final List<ContextEntry> entries;
  final ValueChanged<PlayerAction> onAction;
  final void Function(String elementId, SubmenuItem item)? onSubmenuSelect;

  /// 命令条目（[ContextEntry.command]，不占 [PlayerAction]）被点时回调 [ContextEntry.elementId]。
  final ValueChanged<String>? onCommand;

  /// 子菜单向左弹（贴近屏幕右缘时由宿主决定）。
  final bool submenuOnLeft;

  /// 主菜单可用最大高度（超出则内部滚动，避免被屏幕底裁断）。
  final double? maxHeight;

  const ContextMenuOverlay({
    super.key,
    required this.tokens,
    required this.entries,
    required this.onAction,
    this.onSubmenuSelect,
    this.onCommand,
    this.submenuOnLeft = false,
    this.maxHeight,
  });

  @override
  State<ContextMenuOverlay> createState() => _ContextMenuOverlayState();
}

class _ContextMenuOverlayState extends State<ContextMenuOverlay> {
  String? _openSubmenuId;
  double _submenuOffsetY = 0;
  bool _submenuOpenUp = false;
  final LayerLink _link = LayerLink();
  final OverlayPortalController _portal = OverlayPortalController();

  void _openSubmenu(String id, double offsetY, bool openUp) {
    setState(() {
      _openSubmenuId = id;
      _submenuOffsetY = offsetY;
      _submenuOpenUp = openUp;
    });
    if (!_portal.isShowing) _portal.show();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tokens;

    // 清理分隔线：去掉头尾、合并连续。
    final visibleEntries = <ContextEntry>[];
    for (final e in widget.entries) {
      if (e.isDivider) {
        if (visibleEntries.isEmpty || visibleEntries.last.isDivider) continue;
      }
      visibleEntries.add(e);
    }
    while (visibleEntries.isNotEmpty && visibleEntries.last.isDivider) {
      visibleEntries.removeLast();
    }

    final rows = <Widget>[
      for (final e in visibleEntries)
        if (e.isDivider)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 5, 12, 5),
            child: Divider(height: 1, thickness: 1, color: t.line),
          )
        else if (e.hasSubmenu)
          _SubmenuRow(
            key: ValueKey(e.elementId),
            icon: e.icon,
            label: e.displayLabel,
            tokens: t,
            isOpen: _openSubmenuId == e.elementId,
            submenuItemCount: e.children?.length ?? 0,
            onEnter: (offset, openUp) => _openSubmenu(e.elementId, offset, openUp),
          )
        else
          _MenuRow(
            icon: e.icon,
            label: e.displayLabel,
            tokens: t,
            // 三种行：占动作的（onAction）/ 命令条目（onCommand）/ 都没有（不可点，
            // 例如未注入轨道列表的空子菜单）。别让 action! 抛异常。
            onTap: e.action != null
                ? () => widget.onAction(e.action!)
                : (widget.onCommand == null ? () {} : () => widget.onCommand!(e.elementId)),
          ),
    ];

    final menuWidget = Material(
      color: Colors.transparent,
      // 吸收菜单空白/分隔线上的点击，避免穿透到背后遮罩误关。
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        // 1px 柔光内边（规范 §5 允许的「高光」而非硬边框）：外圈面色 + 1px 内缩。
        child: Container(
          decoration: BoxDecoration(
            color: t.line.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(t.radiusCard),
          ),
          padding: const EdgeInsets.all(1),
          child: Container(
            width: 206,
            constraints: widget.maxHeight != null
                ? BoxConstraints(maxHeight: (widget.maxHeight! - 2).clamp(60.0, 10000.0))
                : const BoxConstraints(),
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: t.raised,
              borderRadius: BorderRadius.circular(t.radiusCard - 1),
            ),
            // 超出可用高度时内部滚动，避免被屏幕底部裁断。
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: rows),
            ),
          ),
        ),
      ),
    );

    ContextEntry? openEntry;
    if (_openSubmenuId != null) {
      for (final e in visibleEntries) {
        if (e.elementId == _openSubmenuId) {
          openEntry = e;
          break;
        }
      }
    }

    final onLeft = widget.submenuOnLeft;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      builder: (context, t2, child) => Opacity(
        opacity: t2.clamp(0, 1),
        child: Transform.translate(offset: Offset(0, (1 - t2) * -2), child: child),
      ),
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: (ctx) {
            final entry = openEntry;
            if (_openSubmenuId == null || entry == null) return const SizedBox.shrink();
            final up = _submenuOpenUp;
            return CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: onLeft ? Alignment.topLeft : Alignment.topRight,
              followerAnchor: Alignment(onLeft ? 1 : -1, up ? 1 : -1),
              offset: Offset(onLeft ? -4 : 4, _submenuOffsetY),
              child: ContextSubmenu(
                tokens: t,
                onLeft: onLeft,
                openUp: up,
                items: entry.children!,
                onSelect: (item) {
                  widget.onSubmenuSelect?.call(_openSubmenuId!, item);
                  setState(() => _openSubmenuId = null);
                  _portal.hide();
                },
              ),
            );
          },
          child: menuWidget,
        ),
      ),
    );
  }
}

class _MenuRow extends StatefulWidget {
  final IconData icon;
  final String label;
  final ThemeTokens tokens;
  final VoidCallback onTap;
  const _MenuRow({required this.icon, required this.label, required this.tokens, required this.onTap});

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.tokens;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: _hover ? t.accent.withValues(alpha: 0.14) : Colors.transparent,
              borderRadius: BorderRadius.circular(t.radiusControl - 4),
            ),
            child: Row(
              children: [
                Icon(widget.icon, size: 16, color: t.iconColor.withValues(alpha: 0.72)),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.text, fontSize: t.fontSize, height: 1.0),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 悬停开子菜单的行。
class _SubmenuRow extends StatefulWidget {
  final IconData icon;
  final String label;
  final ThemeTokens tokens;
  final bool isOpen;
  final int submenuItemCount;
  final void Function(double offsetY, bool openUp) onEnter;

  const _SubmenuRow({
    super.key,
    required this.icon,
    required this.label,
    required this.tokens,
    required this.isOpen,
    required this.submenuItemCount,
    required this.onEnter,
  });

  @override
  State<_SubmenuRow> createState() => _SubmenuRowState();
}

class _SubmenuRowState extends State<_SubmenuRow> {
  bool _hover = false;
  final _key = GlobalKey();

  void _handleEnter(PointerEvent event) {
    setState(() => _hover = true);
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box != null) {
      RenderObject? ancestor;
      context.visitAncestorElements((el) {
        if (el.widget is ContextMenuOverlay) {
          ancestor = el.findRenderObject();
          return false;
        }
        return true;
      });
      if (ancestor is RenderBox) {
        final ancestorBox = ancestor! as RenderBox;
        final rowPos = box.localToGlobal(Offset.zero);
        final menuPos = ancestorBox.localToGlobal(Offset.zero);
        // 估算子菜单高度（每项约 32px + 卡片上下内边距 16），判断向下是否会超出屏幕底部。
        final estHeight = widget.submenuItemCount * 32.0 + 16;
        final screenH = MediaQuery.of(context).size.height;
        final openUp = rowPos.dy + estHeight > screenH - 8;
        final rowTop = rowPos.dy - menuPos.dy;
        final offsetY = openUp ? rowTop + box.size.height : rowTop;
        widget.onEnter(offsetY, openUp);
        return;
      }
      widget.onEnter(event.localPosition.dy, false);
    } else {
      widget.onEnter(0, false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tokens;
    final active = _hover || widget.isOpen;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: _handleEnter,
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
        key: _key,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: active ? t.accent.withValues(alpha: 0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(t.radiusControl - 4),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 16, color: t.iconColor.withValues(alpha: 0.72)),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.text, fontSize: t.fontSize, height: 1.0),
                ),
              ),
              Icon(Icons.chevron_right, size: 15, color: t.text2),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「画面调节」子菜单项：关 + 各包预设 + 「调节…」。
///
/// 纯函数（不碰 widget）：菜单是右键时现建的，所以这里读到的就是最新状态。
///
/// **每一项只有名称，不带说明**（用户 2026-10-18：「右键菜单内不要有太多介绍，
/// 全在扩展内就好了」）：预设的说明在扩展页「设置」里逐条列着，菜单里再放一遍
/// 就是一层灰字噪音。多包重名时由宿主把包名拼进 `name`
/// （`app/lib/state/picture_menu_adapter.dart` 只在包数 > 1 时拼），这里不重复拼装。
List<SubmenuItem> pictureSubmenuItems(PictureMenu menu) => <SubmenuItem>[
      SubmenuItem(
        label: '关',
        checked: menu.isOff,
        value: const PictureMenuSelection.off(),
        elementId: 'picture.off',
      ),
      for (final PicturePresetInfo preset in menu.presets)
        SubmenuItem(
          label: preset.name,
          checked: !menu.isOff && menu.activePresetId == preset.id,
          value: PictureMenuSelection.preset(preset.id),
          elementId: 'picture.${preset.id}',
        ),
      SubmenuItem(
        label: '调节…',
        value: const PictureMenuSelection.openPanel(),
        elementId: kPicturePanelElementId,
      ),
    ];

/// 「调节…」那一项的 elementId（播放面据此弹出滑杆面板）。
const String kPicturePanelElementId = 'picture.openPanel';
