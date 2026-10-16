/// 新拟态组件库（决策 A24/A29/A30/A40/A41/A42/A44）。
///
/// 规范：`docs/specs/2026-10-10-dsanima-neo-theme.md` §4/§7。
///
/// 这里只放**形状**，不放颜色语义：颜色一律从 [DsTokens] 取，
/// 阴影一律走 `DsTokens.shadows()` 的档位。业务代码禁止自己写 `BoxShadow` / `Border.all`。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/motion.dart';
import '../../theme/tokens.dart';
import 'ds_spinner.dart';

/// 焦点态描边宽度（规范 §5 唯一允许的「线」之一）。
const double kNeoFocusWidth = 2;

/// 凹槽最小高度，保证内阴影看起来像槽而不是一条缝。
const double _kInsetMinHeight = 22;

// ─────────────────────────────────────────────────────────────────────────────
// DsInset：凹槽（sunken 面 + 1px line 描边）
// ─────────────────────────────────────────────────────────────────────────────

/// 凹槽容器（规范 §3）：**`sunken` 面 + 1px `line` 描边**，装饰完全来自 [DsTokens.inset]。
///
/// 名字沿革：第二十九轮之前叫 `InsetSurface`，用「自上而下两道线性渐变」模拟内阴影
/// （还配一个柔光内边的 `CustomPainter`）。那层实现已删除、类名也换成 `DsInset` ——
/// 现在它只是「一档更暗的面 + 一条线」，与 token 层同一套语言。
class DsInset extends StatelessWidget {
  const DsInset({
    super.key,
    required this.child,
    this.radius,
    this.padding,
    this.color,
    this.border = true,
    this.constraints,
    this.width,
    this.height,
  });

  final Widget child;
  final double? radius;
  final EdgeInsetsGeometry? padding;

  /// 覆盖底色；默认 [DsTokens.sunken]。
  final Color? color;

  /// 是否描 1px [DsTokens.line] 边（进度条槽、滑块轨道这类"只要一层底色"的地方传 false）。
  final bool border;

  final BoxConstraints? constraints;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final double r = radius ?? t.radiusControl;
    final BoxDecoration decoration = border
        ? t.inset(radius: r, color: color)
        : BoxDecoration(
            color: color ?? t.sunken,
            borderRadius: BorderRadius.circular(r),
          );
    return ConstrainedBox(
      constraints: constraints ?? const BoxConstraints(minHeight: _kInsetMinHeight),
      child: SizedBox(
        width: width,
        height: height,
        child: Container(padding: padding, decoration: decoration, child: child),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// NeoActionChip：小号动作条（凹槽 + 一行字）
// ─────────────────────────────────────────────────────────────────────────────

/// 小号动作条：「换一批 ↻」「下次刷新 12:03 后」这类凹槽里的一行字。
///
/// 为什么要有这个组件（用户 2026-10-10：「有些地方按下反馈不佳，比如今日推荐的
/// 刷新，按下去无响应，但是有效果因为要获取要点时间」）：这些位置原来是一个裸
/// `GestureDetector` 套 [DsInset] —— 按下当帧画面**一点变化都没有**，
/// 而它触发的是一次秒级网络请求，用户只能判断成"没反应"，然后反复点。
///
/// 现在的反馈都在按下当帧出现，分两层：
/// 1. 按下（`onTapDown`）→ 槽底再压深一档，抬指/取消立刻还原；
/// 2. 动作在跑（[busy]，或 [onTap] 的 Future 未完成）→ 文案换成 [busyLabel]，
///    期间**不响应重复点击**（连点=连发请求，是这些控件最容易踩的坑）。
///
/// 刻意**不转圈**：这块区域同时挂着骨架与网格，无限动画会让组件测试的
/// `pumpAndSettle` 永远不 settle（主页骨架当初就是因此做成静态的，见 home_page）。
class NeoActionChip extends StatefulWidget {
  const NeoActionChip({
    super.key,
    required this.label,
    this.onTap,
    this.busy = false,
    this.busyLabel = '处理中…',
    this.labelWidget,
    this.tooltip,
    this.height = 22,
  });

  final String label;

  /// 富文本标签（需要用两级颜色时传它）；忙态仍用 [busyLabel] 顶掉。
  final Widget? labelWidget;

  /// 忙态文案：说清"在做什么"比转圈更安静，也更明确。
  final String busyLabel;

  /// 外部忙态（例如"数据在 provider 里拉"）；与 [onTap] 返回的 Future 叠加。
  final bool busy;

  /// 动作。返回的 Future 未完成前一直显示忙态；同步动作直接返回即可。
  final Future<void> Function()? onTap;

  final String? tooltip;
  final double height;

  @override
  State<NeoActionChip> createState() => _NeoActionChipState();
}

class _NeoActionChipState extends State<NeoActionChip> {
  bool _down = false;
  bool _running = false;

  Future<void> _run() async {
    final Future<void> Function()? action = widget.onTap;
    if (action == null || _running) return;
    setState(() => _running = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final bool busy = widget.busy || _running;
    final bool canTap = widget.onTap != null && !busy;

    Widget chip = DsInset(
      radius: t.radiusControl,
      height: widget.height,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      // 按下去/在跑：槽底再压深一档（凹槽的"再往里"，与凸起控件的"拍下去"同语言）。
      color: _down || busy ? dsPressedFace(t) : null,
      child: Center(
        child: busy
            ? Text(
                widget.busyLabel,
                style: TextStyle(
                  color: t.text2,
                  fontSize: DsTypeScale.caption,
                  fontWeight: FontWeight.w500,
                ),
              )
            : (widget.labelWidget ??
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: t.accent,
                      fontSize: DsTypeScale.caption,
                      fontWeight: FontWeight.w600,
                    ),
                  )),
      ),
    );

    if (canTap) {
      chip = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapUp: (_) => setState(() => _down = false),
          onTapCancel: () => setState(() => _down = false),
          onTap: () => unawaited(_run()),
          child: chip,
        ),
      );
    } else {
      // 在跑：保留凹槽形态（不要跳成另一种控件），只是不再吃点击。
      chip = MouseRegion(cursor: SystemMouseCursors.basic, child: chip);
    }

    if (widget.tooltip != null) {
      chip = Tooltip(message: widget.tooltip!, child: chip);
    }
    return chip;
  }
}

/// 按下/忙态的槽底：常态再暗一档（深色往黑压，浅色往 text3 压）。
///
/// 公开（不是 `_` 前缀）：`NeoDropdown`（`widgets/neo_dropdown.dart`）的触发器也是
/// 凹槽，按下必须与这里**同一档**，否则同一种控件会有两种手感。
Color dsPressedFace(DsTokens t) => Color.alphaBlend(
  t.isDark ? Colors.black.withValues(alpha: 0.22) : t.text3.withValues(alpha: 0.10),
  t.sunken,
);

// ─────────────────────────────────────────────────────────────────────────────
// 凸起容器
// ─────────────────────────────────────────────────────────────────────────────

/// 凸起容器（卡片 / 面板 / 悬浮块）—— 扁平版：`raised` 面 + 1px `line` 描边，**零阴影**。
///
/// * [onTap] 非空时整块可点，按下再沉一档（`dsPressedFace`，规范 §2 第 2 条）；
/// * [onSecondaryTapDown] 非空时右键整块生效（第二十五轮：已完成页的卡片右键菜单）。
///
/// ⚠️ 第二十九轮收口：`level` / `listSafe` / `hoverLevel` 三个新拟态时代的参数**已删除**
/// （扁平化后除悬浮层外零阴影，留着只会误导调用方）。
class NeoSurface extends StatefulWidget {
  const NeoSurface({
    super.key,
    required this.child,
    this.radius,
    this.padding,
    this.color,
    this.onTap,
    this.onSecondaryTapDown,
    this.width,
    this.height,
    this.tooltip,
  });

  final Widget child;
  final double? radius;
  final EdgeInsetsGeometry? padding;
  final Color? color;
  final VoidCallback? onTap;

  /// 右键按下（带指针位置，调用方拿它锚定浮层菜单）。
  final void Function(TapDownDetails)? onSecondaryTapDown;
  final double? width;
  final double? height;
  final String? tooltip;

  @override
  State<NeoSurface> createState() => _NeoSurfaceState();
}

class _NeoSurfaceState extends State<NeoSurface> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final double r = widget.radius ?? t.radiusCard;
    final bool interactive = widget.onTap != null;
    final DsMotion motion = DsMotion.of(context);
    // 状态语言（规范 §2 第 2 条 / 扁平化 F9 F10）：
    //   常态 = raised + 1px line；悬停 = 沉一档（sunken）；按下 = 再沉一档（dsPressedFace）。
    final Color face =
        widget.color ??
        (_down ? dsPressedFace(t) : (_hover ? t.sunken : t.raised));

    Widget box = AnimatedContainer(
      duration: _down ? motion.press : motion.hover,
      curve: DsMotion.hoverCurve,
      width: widget.width,
      height: widget.height,
      padding:
          widget.padding ??
          EdgeInsets.symmetric(horizontal: t.spacing * 1.5, vertical: t.spacing * 1.25),
      decoration: BoxDecoration(
        color: face,
        borderRadius: BorderRadius.circular(r),
        border: Border.all(color: t.line, width: 1),
      ),
      child: widget.child,
    );

    if (interactive || widget.onSecondaryTapDown != null) {
      box = MouseRegion(
        // 只有 `onTap` 才是"可点"：列表摆法的卡片没有左键动作（只有右键菜单），
        // 光标不能装成"点得动"的样子。
        cursor: interactive ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapUp: (_) => setState(() => _down = false),
          onTapCancel: () => setState(() => _down = false),
          onTap: widget.onTap,
          // 右键不参与"按下凹进去"（菜单弹出时卡片不该一直保持着按下的样子）。
          onSecondaryTapDown: widget.onSecondaryTapDown,
          child: box,
        ),
      );
    }

    final String? tip = widget.tooltip;
    if (tip != null) {
      box = Tooltip(message: tip, child: box);
    }
    return box;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 按钮
// ─────────────────────────────────────────────────────────────────────────────

/// 按钮层级（决策 A41）。
enum NeoButtonKind {
  /// 主按钮：凸起 + 强调色 1.5px 描边 + 强调色文字。
  primary,

  /// 次按钮：只凹凸，无边框。
  secondary,

  /// 危险动作：文字用 danger 色。
  danger,
}

/// 新拟态按钮。图标可选；[busy] 时显示转圈且不可点。
class NeoButton extends StatefulWidget {
  const NeoButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.kind = NeoButtonKind.secondary,
    this.busy = false,
    this.compact = false,
    this.expand = false,
    this.tooltip,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final NeoButtonKind kind;
  final bool busy;

  /// 小号（高度 = controlHeight - 8）。
  final bool compact;
  final bool expand;
  final String? tooltip;

  @override
  State<NeoButton> createState() => _NeoButtonState();
}

class _NeoButtonState extends State<NeoButton> {
  bool _hover = false;
  bool _down = false;

  /// 主按钮的底色：强调色实底，悬停往文字色靠 8%、按下 18%（**当帧可见**的沉一档）。
  Color _primaryFace(DsTokens t) {
    if (_down) return Color.alphaBlend(t.onAccent.withValues(alpha: 0.18), t.accent);
    if (_hover) return Color.alphaBlend(t.onAccent.withValues(alpha: 0.08), t.accent);
    return t.accent;
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final DsMotion motion = DsMotion.of(context);
    final bool enabled = widget.onPressed != null && !widget.busy;
    final bool primary = widget.kind == NeoButtonKind.primary;
    // 扁平化（规范 §6）：主按钮 = accent 实底 + onAccent 文字；次按钮 = raised 面 + 1px line
    // 描边 + text 文字；危险按钮 = text/danger 文字 + danger 描边。禁用 = sunken 面 + text3。
    final Color fg = !enabled
        ? t.text3
        : switch (widget.kind) {
            NeoButtonKind.primary => t.onAccent,
            NeoButtonKind.secondary => t.text,
            NeoButtonKind.danger => t.danger,
          };
    final Color face = !enabled
        ? t.sunken
        : primary
        ? _primaryFace(t)
        : (_down
              ? dsPressedFace(t)
              : (_hover ? t.sunken : t.raised));
    final double h = widget.compact ? t.controlHeight - 8 : t.controlHeight;

    Widget content = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        // 忙碌态也是 iOS 风格圆环（13px / 无底轨，见 DsSpinner 类文档）。
        if (widget.busy)
          DsSpinner.button(color: fg)
        else if (widget.icon != null)
          Icon(widget.icon, size: 15, color: fg),
        if (widget.busy || widget.icon != null) const SizedBox(width: 7),
        Flexible(
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: fg,
              fontSize: DsTypeScale.body,
              fontWeight: primary ? FontWeight.w600 : FontWeight.w500,
              height: 1.2,
            ),
          ),
        ),
      ],
    );

    content = AnimatedContainer(
      duration: _down ? motion.press : motion.hover,
      curve: DsMotion.hoverCurve,
      height: h,
      padding: EdgeInsets.symmetric(horizontal: widget.compact ? 10 : 14, vertical: 0),
      decoration: BoxDecoration(
        color: face,
        borderRadius: BorderRadius.circular(t.radiusControl),
        border: primary
            ? null
            : Border.all(
                color: widget.kind == NeoButtonKind.danger && enabled ? t.danger : t.line,
                width: 1,
              ),
      ),
      child: content,
    );

    if (enabled) {
      content = MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapUp: (_) => setState(() => _down = false),
          onTapCancel: () => setState(() => _down = false),
          onTap: widget.onPressed,
          child: content,
        ),
      );
    }

    if (widget.tooltip != null) {
      content = Tooltip(message: widget.tooltip!, child: content);
    }
    return widget.expand ? SizedBox(width: double.infinity, child: content) : content;
  }
}

/// 新拟态图标按钮（凸起圆角方块；按下凹进去）。用于工具条/表格行操作。
class NeoIconButton extends StatefulWidget {
  const NeoIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.size = 30,
    this.color,
    this.selected = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;
  final Color? color;
  final bool selected;

  @override
  State<NeoIconButton> createState() => _NeoIconButtonState();
}

class _NeoIconButtonState extends State<NeoIconButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final DsMotion motion = DsMotion.of(context);
    final bool enabled = widget.onPressed != null;
    final Color fg = !enabled ? t.text3 : (widget.color ?? (widget.selected ? t.accent : t.text2));

    Widget box = AnimatedContainer(
      duration: _down ? motion.press : motion.hover,
      curve: DsMotion.hoverCurve,
      width: widget.size,
      height: widget.size,
      alignment: Alignment.center,
      // 扁平化：选中 = accent 12% 底 + accent 图标；悬停 = sunken；按下 = 再沉一档。
      decoration: BoxDecoration(
        color: widget.selected
            ? t.accentSoft
            : (_down
                  ? dsPressedFace(t)
                  : (_hover ? t.sunken : t.raised)),
        borderRadius: BorderRadius.circular(t.radiusControl * 0.75),
        border: Border.all(color: t.line, width: 1),
      ),
      child: Icon(widget.icon, size: widget.size * 0.52, color: fg),
    );

    if (enabled) {
      box = MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapUp: (_) => setState(() => _down = false),
          onTapCancel: () => setState(() => _down = false),
          onTap: widget.onPressed,
          child: box,
        ),
      );
    }
    if (widget.tooltip != null) {
      box = Tooltip(message: widget.tooltip!, child: box);
    }
    return box;
  }
}

/// 圆形图标按钮：**只有矢量图，没有文字**（凸起圆面；按下/忙态沉成凹槽色）。
///
/// 用户 2026-10-14 第二十八轮：主页的「刷新」与「换一批」原来是凹槽胶囊
/// （图标 + 一行字），要求「改为圆形按钮，仅保留矢量图，去除文字」。
///
/// 与 [NeoIconButton] 的区别只在形状（正圆 vs 圆角方块）与忙态语义：
/// * [busy] 由**外部**给（数据在 provider 里拉），不是自己数 Future；
/// * 忙态用**静态**表达 —— 面沉成凹槽色 + 图标降为三级色 + 不再吃点击。
///   刻意**不转圈**：这块区域同时挂着骨架与网格，无限动画会让组件测试的
///   `pumpAndSettle` 永远不 settle（同 [NeoActionChip] 的那条决策）。
/// * 文字信息改由 [tooltip] / [busyTooltip] 承载（按钮上不再有字）。
class NeoCircleButton extends StatefulWidget {
  const NeoCircleButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.busy = false,
    this.tooltip,
    this.busyTooltip,
    this.size = 28,
  });

  final IconData icon;

  /// 动作。为 null（或 [busy]）时不可点、图标降为三级色。
  final VoidCallback? onPressed;

  /// 外部忙态；与 [onPressed] 叠加，忙时不响应点击。
  final bool busy;

  final String? tooltip;

  /// 忙态时顶掉 [tooltip] 的那句话（按钮上没有字，忙态只能靠 tooltip 说清）。
  final String? busyTooltip;

  /// 圆面直径。
  final double size;

  @override
  State<NeoCircleButton> createState() => _NeoCircleButtonState();
}

class _NeoCircleButtonState extends State<NeoCircleButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final DsMotion motion = DsMotion.of(context);
    final bool enabled = widget.onPressed != null && !widget.busy;
    final Color fg = enabled ? t.accent : t.text3;
    final bool pressed = widget.busy || _down;

    Widget box = AnimatedContainer(
      duration: pressed ? motion.press : motion.hover,
      curve: DsMotion.hoverCurve,
      width: widget.size,
      height: widget.size,
      alignment: Alignment.center,
      // 扁平化：常态 = raised 圆面 + 1px line；悬停 = sunken；按下/忙 = 再沉一档。
      decoration: BoxDecoration(
        color: pressed
            ? dsPressedFace(t)
            : (_hover ? t.sunken : t.raised),
        shape: BoxShape.circle,
        border: Border.all(color: t.line, width: 1),
      ),
      child: Icon(widget.icon, size: widget.size * 0.5, color: fg),
    );

    if (enabled) {
      box = MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapUp: (_) => setState(() => _down = false),
          onTapCancel: () => setState(() => _down = false),
          onTap: widget.onPressed,
          child: box,
        ),
      );
    } else {
      // 忙态/不可点：保留同一个圆面形态（不跳成另一种控件），只是不吃点击。
      box = MouseRegion(cursor: SystemMouseCursors.basic, child: box);
    }

    final String? tip = widget.busy ? (widget.busyTooltip ?? widget.tooltip) : widget.tooltip;
    if (tip != null) box = Tooltip(message: tip, child: box);
    return box;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 开关 / 分段控件 / 滑块
// ─────────────────────────────────────────────────────────────────────────────

/// 开关：**扁平的轨道 + 圆钮**，不用 Material 的 Switch。
///
/// * 关 = `sunken` 轨道 + 1px `line` 描边；开 = `accent` 实底轨道；
/// * 圆钮 = `raised` 面 + 1px `line` 描边（不加描边的话白底上看不见圆钮）；
/// * 时间走 `DsMotion.hover`；轨道里那层「顶部压暗渐变」在扁平化时删掉了。
class NeoSwitch extends StatelessWidget {
  const NeoSwitch({super.key, required this.value, required this.onChanged, this.tooltip});

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? tooltip;

  static const double _w = 44;
  static const double _h = 24;
  static const double _knob = 18;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final DsMotion motion = DsMotion.of(context);
    final bool enabled = onChanged != null;
    final Color track = value && enabled ? t.accent : t.sunken;

    Widget sw = AnimatedContainer(
      duration: motion.hover,
      curve: DsMotion.hoverCurve,
      width: _w,
      height: _h,
      decoration: BoxDecoration(
        color: track,
        borderRadius: BorderRadius.circular(_h / 2),
        border: Border.all(color: t.line, width: 1),
      ),
      child: AnimatedAlign(
        duration: motion.hover,
        curve: DsMotion.hoverCurve,
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Container(
            width: _knob,
            height: _knob,
            decoration: BoxDecoration(
              color: enabled ? t.raised : t.sunken,
              shape: BoxShape.circle,
              border: Border.all(color: t.line, width: 1),
            ),
          ),
        ),
      ),
    );

    if (enabled) {
      sw = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onChanged!(!value),
          child: sw,
        ),
      );
    }
    if (tooltip != null) sw = Tooltip(message: tooltip!, child: sw);
    return sw;
  }
}

/// 分段控件的默认文案：带中文名的枚举（外观 / 封面大小 / 轮播两档）用自己的 label，
/// 其余退回 `toString()`；调用方仍可用 `labelOf` 覆盖。
String _defaultSegmentLabel(Object? o) => switch (o) {
  final DsAppearance a => a.label,
  final DsCoverSize s => s.label,
  final DsCarouselShape s => s.label,
  final DsCarouselSize s => s.label,
  final DsPreheatAhead p => p.label,
  _ => o.toString(),
};

/// 分段控件（决策 A26）：外 `sunken` 槽 + 1px `line` 描边，**选中项 = accent 12% 底 +
/// accent 文字**（扁平化后不再是"凸起选中"）。设置页的「封面大小 / 轮播封面 / 轮播大小」
/// 与「已完成」页的摆法开关都用它。
///
/// [fontSize] 默认 [DsTypeScale.caption] —— 与 [NeoDropdown] / [NeoPill] / [NeoActionChip]
/// 同一个口径：**小凹槽控件里的字就是这一档**。设置页整页比全局小一档，那里显式传
/// `kSettingsBodySize`（第四十六轮：用户「优化一些框里字太大的问题」）。
class NeoSegmented<T> extends StatelessWidget {
  const NeoSegmented({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.keyOverride,
    this.labelOf,
    this.fontSize = DsTypeScale.caption,
  });

  final List<T> options;
  final T value;
  final ValueChanged<T> onChanged;

  /// 选项文字的字号（只允许 [DsTypeScale] 里的档位）。
  final double fontSize;

  /// 覆盖某个选项的 widget key（外观切换用它挂 `GlobalKey`，
  /// 好在点击时拿到按钮中心作为扩散动画的圆心，决策 A25）。
  final Key? Function(T option)? keyOverride;

  /// 选项文字。默认 `'$option'`（枚举会打出 `EnumName.value`）——
  /// 需要中文/自定义文案时传它（第二十四轮「已完成」页的摆法开关）。
  final String Function(T option)? labelOf;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final List<Widget> items = <Widget>[];
    for (final T o in options) {
      final bool selected = o == value;
      items.add(
        _SegmentedItem(
          key: keyOverride?.call(o),
          // 默认文案交给 [_defaultSegmentLabel]（带中文名的枚举直接用它自己的 label）。
          label: labelOf?.call(o) ?? _defaultSegmentLabel(o),
          selected: selected,
          fontSize: fontSize,
          onTap: () => onChanged(o),
        ),
      );
    }
    return DsInset(
      radius: t.radiusControl,
      padding: const EdgeInsets.all(3),
      child: Row(mainAxisSize: MainAxisSize.min, children: items),
    );
  }
}

class _SegmentedItem extends StatefulWidget {
  const _SegmentedItem({
    super.key,
    required this.label,
    required this.selected,
    required this.fontSize,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final double fontSize;
  final VoidCallback onTap;

  @override
  State<_SegmentedItem> createState() => _SegmentedItemState();
}

class _SegmentedItemState extends State<_SegmentedItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final DsMotion motion = DsMotion.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: motion.hover,
          curve: DsMotion.hoverCurve,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          // 扁平化（规范 §6）：选中项 = accent 12% 底 + accent 文字（不再是"凸起"）。
          decoration: BoxDecoration(
            color: widget.selected
                ? t.accentSoft
                : (_hover ? t.sunken : Colors.transparent),
            borderRadius: BorderRadius.circular(t.radiusControl - 3),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: widget.selected ? t.accent : t.text2,
              fontSize: widget.fontSize,
              fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

/// 新拟态滑块：凹槽轨道 + 凸起圆钮。
class NeoSlider extends StatelessWidget {
  const NeoSlider({
    super.key,
    required this.value,
    this.onChanged,
    this.min = 0,
    this.max = 100,
    this.accent,
    this.trackColor,
  });

  final double value;

  /// null = 只读展示（不给交互）。
  final ValueChanged<double>? onChanged;
  final double min;
  final double max;
  final Color? accent;

  /// 覆盖已填充部分的颜色（如按档位变色）。
  final Color? trackColor;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final double frac = ((value - min) / (max - min)).clamp(0.0, 1.0);
    final Color fill = trackColor ?? accent ?? t.accent;
    final ValueChanged<double>? cb = onChanged;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double w = c.maxWidth.isFinite ? c.maxWidth : 160;
        void apply(Offset local) {
          if (cb == null) return;
          final double f = (local.dx / w).clamp(0.0, 1.0);
          cb(min + f * (max - min));
        }

        final Widget track = SizedBox(
          height: t.controlHeight * 0.6,
          child: Stack(
            alignment: Alignment.centerLeft,
            children: <Widget>[
              DsInset(
                height: 8,
                radius: 4,
                border: false,
                child: Align(
                  child: FractionallySizedBox(
                    widthFactor: frac,
                    child: Container(
                      height: 8,
                      margin: const EdgeInsets.all(1),
                      decoration: BoxDecoration(
                        color: fill,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: (frac * w - 9).clamp(0.0, (w - 18).clamp(0.0, w)),
                child: Container(
                  width: 18,
                  height: 18,
                  // 扁平化（规范 §6）：圆钮 = accent 实心 + 1px line 描边（不再有凸起阴影）。
                  decoration: BoxDecoration(
                    color: fill,
                    shape: BoxShape.circle,
                    border: Border.all(color: t.line, width: 1),
                  ),
                ),
              ),
            ],
          ),
        );

        if (cb == null) return track;
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (TapDownDetails d) => apply(d.localPosition),
            onHorizontalDragStart: (DragStartDetails d) => apply(d.localPosition),
            onHorizontalDragUpdate: (DragUpdateDetails d) => apply(d.localPosition),
            child: track,
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 小组件：胶囊 / 徽标 / 语义点 / 进度条 / 区块头
// ─────────────────────────────────────────────────────────────────────────────

/// 胶囊标签（档位、状态、来源）。语义色只以小面积出现（决策 A18）。
///
/// ⚠️ **2026-10-15 第三十轮修**：`tone` 与 `color` 分工写清楚了 ——
/// * `tone` 给了 ⇒ **语义胶囊**：`tone` 12% 底 + `tone` 文字（规范 §6，决策 A18）；
/// * `selected: true` ⇒ 选中态：`color` 12% 底 + `color` 文字 + 加粗；
/// * 都没有 ⇒ 中性胶囊：`sunken` 面 + 1px `line` 描边 + `text2` 文字。
///
/// 修之前只有 `selected` 会染色，而 `DsChip` 传的是 `color` —— 于是队列概览
/// 「失败/取消」的 danger、「已完成」的 success **全部落空**，五颗 chip 长得一模一样
/// （审计 `build/sdd-flat-step2/audit.md` 头两条 [BUG]）。
///
/// ⚠️ **第四十四轮**：`onTap` 不为空时，这一颗是**真按钮**，必须键盘可达 ——
/// 裸 `GestureDetector` 会被 Tab 整块跳过、没有焦点框、回车/空格都没反应
/// （第四十二轮 UX #40 在外观选择器上定下的同一条口径；那儿也是 `InkWell` +
/// `Semantics` + 2px accent 焦点边）。动漫库右栏一次摆 30 多颗类型胶囊，
/// 鼠标专用的写法在那儿说不通。外观主题全局 `NoSplash`，所以 `InkWell` 不会带来水波纹。
class NeoPill extends StatefulWidget {
  const NeoPill({
    super.key,
    required this.label,
    this.color,
    this.tone,
    this.icon,
    this.onTap,
    this.selected = false,
    this.tooltip,
  });

  final String label;
  final Color? color;

  /// 语义色（状态标签用）：给了就是「12% 底 + 该色文字」。
  final Color? tone;

  final IconData? icon;
  final VoidCallback? onTap;
  final bool selected;
  final String? tooltip;

  @override
  State<NeoPill> createState() => _NeoPillState();
}

class _NeoPillState extends State<NeoPill> {
  /// 键盘焦点在不在这一颗上（第四十四轮：可点的胶囊也要键盘可达，见类文档）。
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final Color c = widget.color ?? widget.tone ?? t.text2;
    final bool tinted = widget.selected || widget.tone != null;
    Widget pill = AnimatedContainer(
      duration: DsMotion.of(context).hover,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      // 扁平化（规范 §6）：`sunken` 面 + 1px line 描边；语义色胶囊 = 语义色 12% 底 + 语义色文字。
      decoration: BoxDecoration(
        color: tinted ? c.withValues(alpha: 0.12) : t.sunken,
        borderRadius: BorderRadius.circular(t.radiusPill),
        // 键盘焦点 = 2px accent（规范 §7 白名单里唯一允许的强调色描边）；其余照旧。
        border: _focused
            ? Border.all(color: t.accent, width: 2)
            : Border.all(color: tinted ? Colors.transparent : t.line, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (widget.icon != null) ...<Widget>[
            Icon(widget.icon, size: 12, color: c),
            const SizedBox(width: 5),
          ],
          Text(
            widget.label,
            style: TextStyle(
              color: tinted ? c : t.text2,
              fontSize: DsTypeScale.caption,
              fontWeight: tinted ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
    if (widget.onTap != null) {
      pill = MouseRegion(
        cursor: SystemMouseCursors.click,
        // `InkWell`（不是 GestureDetector）：Tab 能遍历到、回车/空格能激活、能收焦点。
        // 主题里 `splashFactory: NoSplash`，所以不会多出一层水波纹。
        child: Semantics(
          button: true,
          selected: widget.selected,
          child: InkWell(
            onTap: widget.onTap,
            onFocusChange: (bool focused) => setState(() => _focused = focused),
            borderRadius: BorderRadius.circular(t.radiusPill),
            child: pill,
          ),
        ),
      );
    }
    if (widget.tooltip != null) pill = Tooltip(message: widget.tooltip!, child: pill);
    return pill;
  }
}

/// 语义状态点（引擎已连接 / 连接中 / 未连接必须一眼可分，决策 A18）。
///
/// ⚠️ 2026-10-11 第六轮：例子不再是「做种数 0 与 3」—— 用户要求把做种数从界面上去掉，
/// 状态列现在只表达「这条有没有源 + 引擎通不通」（见 `search_sections.dart`）。
/// 圆点本身的语义不变：**颜色是小面积的唯一语义载体**，别再往徽标里塞数字。
class NeoDot extends StatelessWidget {
  const NeoDot({super.key, required this.color, this.size = 7, this.tooltip});

  final Color color;
  final double size;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    Widget dot = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: t.line, width: 1),
      ),
    );
    if (tooltip != null) dot = Tooltip(message: tooltip!, child: dot);
    return dot;
  }
}

/// 细进度条：凹槽轨道 + 强调色（或语义色）填充。
class NeoProgress extends StatelessWidget {
  const NeoProgress({super.key, required this.value, this.color, this.height = 6, this.label});

  /// 0.0–1.0。
  final double value;
  final Color? color;
  final double height;

  /// 右侧数值标签（可选，tabular figures 自动生效）。
  final String? label;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final double f = value.clamp(0.0, 1.0);
    final Color c = color ?? t.accent;
    final Widget bar = DsInset(
      height: height,
      radius: height / 2,
      border: false,
      // ⚠️ `alignment` 必须显式给 start：`Align` 默认是 `Alignment.center`，
      // 那样填充块会**以轨道中线为轴往两边长**（看起来就是从中间开始，用户
      // 2026-10-12 第八轮报的就是这个）。改成 start 才是从左到右。
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: FractionallySizedBox(
          widthFactor: f,
          alignment: AlignmentDirectional.centerStart,
          child: Container(
            height: height,
            margin: const EdgeInsets.all(1),
            decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(height / 2)),
          ),
        ),
      ),
    );
    if (label == null) return bar;
    return Row(
      children: <Widget>[
        Expanded(child: bar),
        const SizedBox(width: 8),
        Text(
          label!,
          style: TextStyle(
            color: t.text2,
            fontSize: DsTypeScale.caption,
            fontFeatures: DsTokens.tabular,
          ),
        ),
      ],
    );
  }
}

/// 区块头：表头样式的标题 + 可选副标题与右侧尾随控件。
class NeoSectionHeader extends StatelessWidget {
  const NeoSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(2, 0, 2, 8),
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Row(
              children: <Widget>[
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: dsTableHeaderStyle(t),
                  ),
                ),
                if (subtitle != null) const SizedBox(width: 8),
                if (subtitle != null)
                  Flexible(
                    child: Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
                    ),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 状态横幅（成功/警告/失败/信息）：**语义色 12% 底 + 左侧 2px 语义色条**（不描边，
/// 免得跟卡片混淆 —— 规范 §6）。
class NeoBanner extends StatelessWidget {
  const NeoBanner({super.key, required this.text, this.kind = NeoBannerKind.info, this.action});

  final String text;
  final NeoBannerKind kind;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final (Color c, IconData icon) = switch (kind) {
      NeoBannerKind.info => (t.accent, Icons.info_outline),
      NeoBannerKind.success => (t.success, Icons.check_circle_outline),
      NeoBannerKind.warning => (t.warning, Icons.warning_amber_rounded),
      NeoBannerKind.error => (t.danger, Icons.error_outline),
    };
    return Container(
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(t.radiusControl),
      ),
      padding: const EdgeInsets.fromLTRB(0, 10, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 2,
            height: 18,
            margin: const EdgeInsets.only(left: 8, right: 10),
            decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2)),
          ),
          Icon(icon, size: 15, color: c),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: t.text, fontSize: DsTypeScale.secondary, height: 1.45),
            ),
          ),
          if (action != null) const SizedBox(width: 10),
          ?action,
        ],
      ),
    );
  }
}

enum NeoBannerKind { info, success, warning, error }
