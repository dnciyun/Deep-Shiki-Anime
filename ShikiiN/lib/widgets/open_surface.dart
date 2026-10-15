import 'package:flutter/material.dart';
import '../models/theme_tokens.dart';

/// 空态覆盖层（契约 §5 第 1 条：必须不透明，避免外壳被卸载导致 libmpv EGL 失败）。
///
/// 极简形态（新拟态规范 §7 空态）：大留白 + 一个凸起图标圆盘（radiusPill）+ 13px 文案。
/// 无壁纸、无打开文件/拖拽入口（宿主只投递串流 URL）。
class OpenSurface extends StatelessWidget {
  final ThemeTokens tokens;

  /// 文案；默认说明播放器在等宿主投递播放请求。
  final String? message;

  const OpenSurface({super.key, required this.tokens, this.message});

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return ColoredBox(
      color: t.base,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 凸起图标圆盘：新拟态层次靠面色差，不用硬边框。
            Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                color: t.raised,
                borderRadius: BorderRadius.circular(t.radiusPill),
              ),
              alignment: Alignment.center,
              child: Image.asset(
                'packages/shikiin/assets/icon.png',
                height: 52,
                filterQuality: FilterQuality.medium,
                errorBuilder: (BuildContext ctx, Object e, StackTrace? st) =>
                    Icon(Icons.play_arrow_rounded, size: 44, color: t.accent),
              ),
            ),
            const SizedBox(height: 20),
            Text.rich(
              TextSpan(
                style: TextStyle(
                  color: t.text,
                  fontSize: t.fontSize + 7,
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                ),
                children: [
                  const TextSpan(text: 'Shikii'),
                  TextSpan(text: 'N', style: TextStyle(color: t.accent)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message ?? '等待播放请求',
              textAlign: TextAlign.center,
              style: TextStyle(color: t.text2, fontSize: t.fontSize, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }
}
