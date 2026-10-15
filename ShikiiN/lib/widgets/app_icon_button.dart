import 'package:flutter/material.dart';

/// 图标全集（自有，不再依赖已删的 `theme/app_icon.dart` 主题覆盖系统）。
enum AppIconId {
  playPause,
  pause,
  prev,
  next,
  seekBack,
  seekForward,
  volume,
  mute,
  fullscreen,
  settings,
  playlist,
  minimize,
  maximize,
  close,
}

IconData defaultIconData(AppIconId id) {
  switch (id) {
    case AppIconId.playPause:
      return Icons.play_arrow_rounded;
    case AppIconId.pause:
      return Icons.pause_rounded;
    case AppIconId.prev:
      return Icons.skip_previous_rounded;
    case AppIconId.next:
      return Icons.skip_next_rounded;
    case AppIconId.seekBack:
      return Icons.replay_5_rounded;
    case AppIconId.seekForward:
      return Icons.forward_5_rounded;
    case AppIconId.volume:
      return Icons.volume_up_rounded;
    case AppIconId.mute:
      return Icons.volume_off_rounded;
    case AppIconId.fullscreen:
      return Icons.fullscreen_rounded;
    case AppIconId.settings:
      return Icons.settings_rounded;
    case AppIconId.playlist:
      return Icons.playlist_play_rounded;
    case AppIconId.minimize:
      return Icons.remove_rounded;
    case AppIconId.maximize:
      return Icons.crop_square_rounded;
    case AppIconId.close:
      return Icons.close_rounded;
  }
}

/// 内置默认矢量图标（自定义 SVG/图片图标导入已删）。
class AppIcon extends StatelessWidget {
  final AppIconId id;
  final double size;
  final Color color;
  const AppIcon({super.key, required this.id, required this.size, required this.color});

  @override
  Widget build(BuildContext context) => Icon(defaultIconData(id), size: size, color: color);
}

/// 统一图标按钮：hover 提亮一档 + 按下轻微缩放（150ms easeOut，无回弹）。
class AppIconButton extends StatefulWidget {
  final AppIconId id;
  final double size;
  final double iconSize;
  final Color color;
  final double radius;
  final String? tooltip;
  final VoidCallback onPressed;

  const AppIconButton({
    super.key,
    required this.id,
    required this.size,
    required this.iconSize,
    required this.color,
    this.radius = 12,
    this.tooltip,
    required this.onPressed,
  });

  @override
  State<AppIconButton> createState() => _AppIconButtonState();
}

class _AppIconButtonState extends State<AppIconButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final button = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) {
          setState(() => _down = false);
          widget.onPressed();
        },
        onTapCancel: () => setState(() => _down = false),
        child: AnimatedScale(
          scale: _down ? 0.94 : 1,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: _hover ? widget.color.withValues(alpha: 0.12) : Colors.transparent,
              borderRadius: BorderRadius.circular(widget.radius),
            ),
            child: Center(
              child: AppIcon(id: widget.id, size: widget.iconSize, color: widget.color),
            ),
          ),
        ),
      ),
    );
    final tip = widget.tooltip;
    if (tip == null) return button;
    return Tooltip(message: tip, waitDuration: const Duration(milliseconds: 500), child: button);
  }
}
