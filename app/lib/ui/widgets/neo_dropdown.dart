/// 新拟态下拉（替代 `DropdownButton`）：凹槽触发器 + **锚在正下方**的浮层菜单。
///
/// 为什么重写（用户 2026-10-11：「选择星期几的展开有撕裂感，需要优化下」）：
/// `DropdownButton` 走的是 Material 的 `_DropdownRoute`，它做两件在深色/125% 缩放下
/// 很难看的事：
/// 1. **把选中项对齐到按钮位置**再整体做「淡入 + 尺寸」过渡 —— 展开瞬间菜单从按钮
///    中间撑开、纵向滑过并盖住上面的标题，看着就是界面被撕了一下；
/// 2. 菜单底色/圆角/描边/条目高度全是 Material 默认值（条目 48 起步、直角），与本项目
///    的凹槽触发器（26–32 px、`radiusControl` 圆角、line 描边）对不上，
///    展开后像另一个应用的东西摞上来。
///
/// 这里改用 `showMenu`：位置由触发器的 RenderBox 算出来（下方 4px、宽度对齐），
/// 圆角/描边/底色/条目高度全走 token，过渡只有轻量的淡入 + 缩放 —— 不跳位、不遮标题。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'neo.dart';

/// 一个菜单项：值 + 显示文本（[hint] 会作为第二行小字，可选）。
@immutable
class NeoDropdownItem<T> {
  const NeoDropdownItem(this.value, this.label, {this.hint});

  final T value;
  final String label;
  final String? hint;
}

/// 凹槽下拉触发器。
class NeoDropdown<T> extends StatefulWidget {
  const NeoDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onSelected,
    required this.label,
    this.width = 176,
    this.height = 26,
    this.fontSize = DsTypeScale.body,
    this.tooltip,
  });

  /// 当前值（用于在菜单里打勾 / 着色）。
  final T value;

  final List<NeoDropdownItem<T>> items;
  final ValueChanged<T> onSelected;

  /// 触发器上显示的文字（调用方给，因为展示文案常带动态后缀，如「周三（今天）· 8 部」）。
  final String label;

  final double width;
  final double height;
  final double fontSize;
  final String? tooltip;

  @override
  State<NeoDropdown<T>> createState() => _NeoDropdownState<T>();
}

class _NeoDropdownState<T> extends State<NeoDropdown<T>> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final bool canOpen = widget.items.isNotEmpty;

    Widget trigger = DsInset(
      radius: t.radiusControl,
      height: widget.height,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      // 按下压深一档：与 NeoActionChip 同一档手感（`dsPressedFace`）。
      color: _down ? dsPressedFace(t) : null,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: t.text,
                fontSize: widget.fontSize,
                fontFeatures: DsTokens.tabular,
              ),
            ),
          ),
          Icon(Icons.expand_more, size: 16, color: t.text3),
        ],
      ),
    );

    trigger = MouseRegion(
      cursor: canOpen ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: canOpen ? (_) => setState(() => _down = true) : null,
        onTapUp: canOpen ? (_) => setState(() => _down = false) : null,
        onTapCancel: canOpen ? () => setState(() => _down = false) : null,
        onTap: canOpen ? () => unawaited(_open(context)) : null,
        child: trigger,
      ),
    );

    if (widget.tooltip != null) {
      trigger = Tooltip(message: widget.tooltip!, child: trigger);
    }
    return SizedBox(width: widget.width, child: trigger);
  }

  Future<void> _open(BuildContext context) async {
    final DsTokens t = context.ds;
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    final OverlayState? overlay = Overlay.maybeOf(context);
    final RenderBox? overlayBox = overlay?.context.findRenderObject() as RenderBox?;
    if (box == null || overlayBox == null) return;

    final Offset topLeft = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final Size size = box.size;
    // 锚在触发器**正下方** 4px：不覆盖触发器、也不遮上方标题。
    final RelativeRect position = RelativeRect.fromLTRB(
      topLeft.dx,
      topLeft.dy + size.height + 4,
      overlayBox.size.width - topLeft.dx - size.width,
      0,
    );

    final T? picked = await showMenu<T>(
      context: context,
      position: position,
      color: t.raised,
      elevation: t.overlayElevation,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(t.radiusControl),
      ),
      constraints: BoxConstraints(minWidth: size.width, maxHeight: 320),
      items: <PopupMenuEntry<T>>[
        for (final NeoDropdownItem<T> item in widget.items)
          PopupMenuItem<T>(
            value: item.value,
            height: item.hint == null ? 34 : 46,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: _row(t, item),
          ),
      ],
    );
    if (!mounted) return;
    if (_down) setState(() => _down = false);
    if (picked != null) widget.onSelected(picked);
  }

  Widget _row(DsTokens t, NeoDropdownItem<T> item) {
    final bool selected = item.value == widget.value;
    final String? hint = item.hint;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? t.accent : t.text,
                  fontSize: widget.fontSize,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              if (hint != null)
                Text(
                  hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
                ),
            ],
          ),
        ),
        if (selected) Icon(Icons.check, size: 15, color: t.accent),
      ],
    );
  }
}
