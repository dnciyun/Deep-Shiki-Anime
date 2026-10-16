/// 外观选择器（规范 §5.6 / 决策 F6/F7）。
///
/// 两行：「白色系」4 格 + 「黑色系」4 格。每格 = 该外观的 `accent` 色点 + 名称；
/// 选中格 = `accent` 12% 底 + `accent` 文字 + **2px** `accent` 描边（扁平规范里
/// 2px 强调色描边是允许的「焦点/选中」例外，见规范 §7 的白名单）。
///
/// 为什么单独一个文件：`neo.dart` 是 1200+ 行的通用组件库，而本组件只服务
/// 「设置页 / 首启向导 / 预览页」三处，拆开更利于单独读与单独测。
library;

import 'package:flutter/material.dart';

import '../../theme/motion.dart';
import '../../theme/tokens.dart';

/// 点某一格时回调什么：选中的外观 + **这一格的全局中心**。
///
/// 为什么要带上位置（第三十三轮）：用户要求的 Circular Reveal 是"从点击处张开"，
/// 只有格子自己知道自己在屏幕上的哪儿。首启向导/预览页不需要演动画，忽略第二个参数即可。
typedef AppearancePicked = void Function(DsAppearance appearance, Offset globalCenter);

class NeoAppearancePicker extends StatelessWidget {
  const NeoAppearancePicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.keyPrefix = 'appearance',
  });

  /// 当前选中的外观。
  final DsAppearance value;

  final AppearancePicked onChanged;

  /// 每格的 key 前缀：`Key('$keyPrefix-${appearance.code}')`（测试与多实例页面用）。
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final DsAppearanceFamily family in DsAppearanceFamily.values) ...<Widget>[
          if (family != DsAppearanceFamily.values.first) const SizedBox(height: 14),
          Text(
            family.label,
            style: TextStyle(
              color: t.text3,
              fontSize: DsTypeScale.caption,
              fontWeight: FontWeight.w600,
              letterSpacing: DsTypeScale.caption * 0.08,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final DsAppearance a in DsAppearance.values)
                if (a.family == family)
                  _AppearanceCell(
                    appearance: a,
                    selected: a == value,
                    keyPrefix: keyPrefix,
                    onTap: (Offset center) => onChanged(a, center),
                  ),
            ],
          ),
        ],
      ],
    );
  }
}

class _AppearanceCell extends StatefulWidget {
  const _AppearanceCell({
    required this.appearance,
    required this.selected,
    required this.keyPrefix,
    required this.onTap,
  });

  final DsAppearance appearance;
  final bool selected;
  final String keyPrefix;

  /// 参数 = 这一格的全局中心（给 Circular Reveal 当圆心）。
  final ValueChanged<Offset> onTap;

  @override
  State<_AppearanceCell> createState() => _AppearanceCellState();
}

class _AppearanceCellState extends State<_AppearanceCell> {
  bool _hover = false;

  /// 键盘焦点在不在这一格上（第四十二轮 UX #40）。
  bool _focused = false;

  /// 这一格在**屏幕上的中心**（圆以它为中心张开）。
  Offset _globalCenter() {
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return Offset.zero;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final bool selected = widget.selected;
    // ⚠️ 选中格用的是**该外观自己的** accent，不是当前主题的 accent —— 因为设置是
    // 「草稿 + 保存生效」：点了紫白之后主题还没切，若跟着当前主题画，格子会一直亮着
    // 旧颜色，等于没有反馈。未选中的格子仍用当前主题的中性面色（不抢视线）。
    final DsTokens own = widget.appearance.tokens;
    // 状态语言（规范 §2 第 2 条）：选中 = accent 12% 底 + accent 文字 + 2px accent 描边；
    // 悬停 = 沉一档；未选中 = raised + 1px line。
    final Color background = selected
        ? own.accentSoft
        : (_hover ? t.sunken : t.raised);
    final Color foreground = selected ? own.accent : t.text;
    final DsMotion motion = DsMotion.of(context);

    return Tooltip(
      message: '${widget.appearance.label}（${widget.appearance.family.label}）',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        // 第四十二轮 UX #40：这一格以前是裸 `GestureDetector` —— Tab 整块跳过、
        // 没有焦点框、回车/空格都没反应（鼠标能做的事键盘一样都做不了）。
        // `InkWell` 自带焦点遍历与回车/空格激活；外面再补一层 Semantics
        // （"这是一颗按钮、当前选没选中"），读屏软件才念得对。
        child: Semantics(
          button: true,
          selected: selected,
          child: InkWell(
            onTap: () => widget.onTap(_globalCenter()),
            onFocusChange: (bool focused) => setState(() => _focused = focused),
            borderRadius: BorderRadius.circular(t.radiusControl),
            child: AnimatedContainer(
              key: Key('${widget.keyPrefix}-${widget.appearance.code}'),
              duration: motion.hover,
              curve: DsMotion.hoverCurve,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(t.radiusControl),
                // 选中格 = 该外观自己的 accent + 2px（规范 §5.6）；未选中 = 1px line。
                // 键盘焦点再盖一层 accent（不然"焦点在哪"完全看不出来）。
                border: Border.all(color: _focused ? t.accent : (selected ? own.accent : t.line), width: (_focused || selected) ? 2 : 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: widget.appearance.tokens.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    widget.appearance.label,
                    style: TextStyle(
                      color: foreground,
                      fontSize: DsTypeScale.caption,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
