import 'package:flutter/material.dart';
import '../models/theme_tokens.dart';
import 'context_menu.dart' show SubmenuItem;

/// 右键菜单的 flyout 子菜单（新拟态：raised 面 + radiusCard，无边框）。
/// 支持「子子组」：项带 children 时显示为一行，hover 再开一层 flyout。
class ContextSubmenu extends StatefulWidget {
  final ThemeTokens tokens;
  final List<SubmenuItem> items;
  final ValueChanged<SubmenuItem> onSelect;
  final bool onLeft;
  final bool openUp;

  const ContextSubmenu({
    super.key,
    required this.tokens,
    required this.items,
    required this.onSelect,
    this.onLeft = false,
    this.openUp = false,
  });

  @override
  State<ContextSubmenu> createState() => _ContextSubmenuState();
}

class _ContextSubmenuState extends State<ContextSubmenu> {
  final LayerLink _link = LayerLink();
  final OverlayPortalController _portal = OverlayPortalController();
  final GlobalKey _cardKey = GlobalKey();
  SubmenuItem? _openGroup;
  double _groupOffsetY = 0;

  void _openGroupFlyout(SubmenuItem g, double offsetY) {
    setState(() {
      _openGroup = g;
      _groupOffsetY = offsetY;
    });
    if (!_portal.isShowing) _portal.show();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tokens;

    final rows = <Widget>[
      for (final item in widget.items)
        if (item.isGroup)
          _GroupRow(
            label: item.label,
            count: item.children!.length,
            isOpen: _openGroup == item,
            tokens: t,
            cardKey: _cardKey,
            onHover: (offsetY) => _openGroupFlyout(item, offsetY),
          )
        else
          _SubmenuItemRow(
            item: item,
            tokens: t,
            onTap: () => widget.onSelect(item),
          ),
    ];

    final card = Material(
      color: Colors.transparent,
      child: IntrinsicWidth(
        key: _cardKey,
        child: Container(
          constraints: const BoxConstraints(minWidth: 88, maxWidth: 280, maxHeight: 380),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: t.raised,
            borderRadius: BorderRadius.circular(t.radiusCard),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rows,
            ),
          ),
        ),
      ),
    );

    final onLeft = widget.onLeft;
    final wrapped = CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (ctx) {
          final g = _openGroup;
          if (g == null) return const SizedBox.shrink();
          return CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            targetAnchor: onLeft ? Alignment.topLeft : Alignment.topRight,
            followerAnchor: onLeft ? Alignment.topRight : Alignment.topLeft,
            offset: Offset(onLeft ? -4 : 4, _groupOffsetY),
            child: ContextSubmenu(
              tokens: t,
              items: g.children!,
              onSelect: widget.onSelect,
              onLeft: onLeft,
            ),
          );
        },
        child: card,
      ),
    );

    // 抵消 CompositedTransformFollower 的全屏 tight 约束，并贴住与展开方向一致的角。
    return Align(
      alignment: Alignment(onLeft ? 1 : -1, widget.openUp ? 1 : -1),
      child: wrapped,
    );
  }
}

/// 三级分组行：hover 再开一层。
class _GroupRow extends StatefulWidget {
  final String label;
  final int count;
  final bool isOpen;
  final ThemeTokens tokens;
  final GlobalKey cardKey;
  final ValueChanged<double> onHover;
  const _GroupRow({
    required this.label,
    required this.count,
    required this.isOpen,
    required this.tokens,
    required this.cardKey,
    required this.onHover,
  });

  @override
  State<_GroupRow> createState() => _GroupRowState();
}

class _GroupRowState extends State<_GroupRow> {
  bool _hover = false;
  final _key = GlobalKey();

  void _handleEnter() {
    setState(() => _hover = true);
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    final card = widget.cardKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && card != null) {
      final rowTop = box.localToGlobal(Offset.zero).dy;
      final cardTop = card.localToGlobal(Offset.zero).dy;
      widget.onHover(rowTop - cardTop);
    } else {
      widget.onHover(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tokens;
    final active = _hover || widget.isOpen;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _handleEnter(),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: _handleEnter,
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
                Icon(Icons.format_list_bulleted_rounded, size: 14, color: t.iconColor.withValues(alpha: 0.7)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${widget.label} (${widget.count})',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.text, fontSize: t.fontSize, height: 1.0),
                  ),
                ),
                Icon(Icons.chevron_right_rounded, size: 15, color: t.text2),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SubmenuItemRow extends StatefulWidget {
  final SubmenuItem item;
  final ThemeTokens tokens;
  final VoidCallback onTap;
  const _SubmenuItemRow({required this.item, required this.tokens, required this.onTap});

  @override
  State<_SubmenuItemRow> createState() => _SubmenuItemRowState();
}

class _SubmenuItemRowState extends State<_SubmenuItemRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.tokens;
    final hint = widget.item.hint;
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
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 16,
                  child: widget.item.checked
                      ? Icon(Icons.check, size: 14, color: t.accent)
                      : null,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: TextStyle(color: t.text, fontSize: t.fontSize, height: 1.0),
                      ),
                      if (hint != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          hint,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          style: TextStyle(color: t.text3, fontSize: t.fontSizeSmall, height: 1.0),
                        ),
                      ],
                    ],
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
