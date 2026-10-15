import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../models/theme_tokens.dart';
import 'app_icon_button.dart';

/// 无边框窗口的自绘标题栏：品牌 + 正在播放文件名（可拖动 / 双击最大化），
/// 右侧 最小化 / 最大化 / 关闭。无主题 resolver、无硬边框（层次靠面色与 1px 极淡分隔线）。
class TitleBar extends StatelessWidget {
  final ThemeTokens tokens;
  final String? nowPlaying;
  final bool fullscreen;

  /// 指针落到标题栏时通知播放面「把 chrome 唤醒」（自动淡隐的计时器重新计时）。
  ///
  /// 可选：不传时只是没有这个唤醒副作用，拖拽/双击照样可用。
  final VoidCallback? onPoke;

  /// 最大化键 / 双击标题栏的**替身动作**（不传 = 原生最大化/还原）。
  ///
  /// 为什么需要它：DSAnima 的播放器是**无边框弹出窗口**，一旦被原生最大化就铺满整屏、
  /// 把主窗口 100% 盖住 —— 用户 2026-10-11 的「开启播放器后整个程序都不能用了，
  /// 什么都点不了整个 DSAnime」就是这么来的。那种宿主（`PlayerSurface`)把这一键改成
  /// **切全屏**：全屏是用户显式动作，随时能按 Esc / 双击画面退出来。
  final VoidCallback? onMaximize;

  const TitleBar({
    super.key,
    required this.tokens,
    this.nowPlaying,
    this.fullscreen = false,
    this.onPoke,
    this.onMaximize,
  });

  /// 最大化键与双击标题栏都走这里（有替身动作就用替身）。
  void _maximizeAction() {
    final VoidCallback? override = onMaximize;
    if (override != null) {
      override();
      return;
    }
    unawaited(_toggleMaximize());
  }

  Future<void> _toggleMaximize() async {
    // 全屏时按最大化键 / 双击标题栏：单步退出全屏，setFullScreen(false) 还原进全屏前的窗口状态。
    if (await windowManager.isFullScreen()) {
      await windowManager.setFullScreen(false);
      return;
    }
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    // 高度用 token（`ThemeTokens.titleBarHeight`，2026-10-11 第六轮 28 → 40）。
    // 为什么不再把字号写死：用户这一轮要求「标题栏控制栏全都调大些，**包括控件文字**」，
    // 宿主只改 token 就能整体缩放播放窗口的文字；这里读 `t.fontSize`。
    final h = ThemeTokens.titleBarHeight;
    final title = nowPlaying;
    final double titleSize = t.fontSize;
    final double brandSize = t.fontSize + 1;
    return SizedBox(
      height: h,
      child: Column(
        children: [
          Expanded(
            child: ColoredBox(
              color: t.base,
              child: Row(
                // 纵向拉伸：拖拽区与窗口按钮都填满整条高度。
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    // ⚠️ 拖拽区必须**一直可点**：以前它被播放面用
                    // `IgnorePointer(ignoring: !chromeVisible)` 包着，鼠标在视频区停 3 秒、
                    // 控件自动淡隐之后就"看得见但按不动"（用户 2026-10-10 报「标题栏按住
                    // 无法拖动」）。淡隐只该影响透明度，不该影响命中测试。
                    child: Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: (_) => onPoke?.call(),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.move,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (_) => windowManager.startDragging(),
                          onDoubleTap: _maximizeAction,
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: t.spacing),
                            child: Row(
                              children: [
                                // 带包前缀：宿主内嵌时同样能取到资源；缺失只是不显示，绝不打断播放页。
                                Image.asset(
                                  'packages/shikiin/assets/icon.png',
                                  height: 18,
                                  filterQuality: FilterQuality.medium,
                                  errorBuilder:
                                      (BuildContext ctx, Object e, StackTrace? st) =>
                                          const SizedBox.shrink(),
                                ),
                                const SizedBox(width: 7),
                                Text.rich(
                                  TextSpan(
                                    style: TextStyle(
                                      color: t.text,
                                      fontSize: brandSize,
                                      fontWeight: FontWeight.w600,
                                      height: 1.0,
                                    ),
                                    children: [
                                      const TextSpan(text: 'Shikii'),
                                      TextSpan(
                                          text: 'N',
                                          style: TextStyle(color: t.accent)),
                                    ],
                                  ),
                                ),
                                if (title != null && title.isNotEmpty) ...[
                                  const SizedBox(width: 8),
                                  Container(width: 1, height: 14, color: t.line),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: t.text2,
                                          fontSize: titleSize,
                                          height: 1.0),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  _WinButton(
                    iconId: AppIconId.minimize,
                    tokens: t,
                    onPressed: () async {
                      // 真·全屏下 Win32 窗口样式会挡住最小化；先退出全屏再最小化。
                      if (await windowManager.isFullScreen()) {
                        await windowManager.setFullScreen(false);
                      }
                      await windowManager.minimize();
                    },
                  ),
                  _WinButton(
                    iconId: AppIconId.maximize,
                    tokens: t,
                    tooltip: fullscreen ? '退出全屏' : '最大化',
                    onPressed: _maximizeAction,
                  ),
                  _WinButton(
                    iconId: AppIconId.close,
                    tokens: t,
                    tooltip: '关闭',
                    danger: true,
                    onPressed: () => windowManager.close(),
                  ),
                ],
              ),
            ),
          ),
          // 与画面区的极淡分隔（1px 线，不是硬边框）。
          Container(height: 1, color: t.line.withValues(alpha: 0.5)),
        ],
      ),
    );
  }
}

class _WinButton extends StatefulWidget {
  final AppIconId iconId;
  final ThemeTokens tokens;
  final bool danger;
  final String? tooltip;
  final VoidCallback onPressed;
  const _WinButton({
    required this.iconId,
    required this.tokens,
    this.danger = false,
    this.tooltip,
    required this.onPressed,
  });

  @override
  State<_WinButton> createState() => _WinButtonState();
}

class _WinButtonState extends State<_WinButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.tokens;
    final Color bg;
    final Color fg;
    if (_hover) {
      bg = widget.danger ? t.danger : t.sunken;
      fg = widget.danger ? t.base : t.text;
    } else {
      bg = Colors.transparent;
      fg = t.iconColor;
    }
    final button = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          // 34 → 44：40px 高的标题栏里，三颗按钮各 44 宽仍是"贴着右上角的一小块"，
          // 但命中区从 34×28 涨到 44×40（用户 2026-10-11 第六轮要求"全调大些"）。
          width: 44,
          color: bg,
          child: Center(child: AppIcon(id: widget.iconId, size: 16, color: fg)),
        ),
      ),
    );
    final tip = widget.tooltip;
    if (tip == null || tip.isEmpty) return button;
    return Tooltip(message: tip, waitDuration: const Duration(milliseconds: 600), child: button);
  }
}
