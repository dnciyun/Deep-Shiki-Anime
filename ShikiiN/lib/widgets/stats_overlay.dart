import 'package:flutter/material.dart';
import '../models/theme_tokens.dart';
import '../models/video_stats.dart';

/// 视频数据浮层（角落、半透明，只读）。Tab 键切换。
class StatsOverlay extends StatelessWidget {
  final ThemeTokens tokens;
  final VideoStats stats;
  const StatsOverlay({super.key, required this.tokens, required this.stats});

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: t.base.withValues(alpha: 0.74),
        borderRadius: BorderRadius.circular(t.radiusControl),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (label, value) in stats.rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 72,
                    child: Text(
                      label,
                      style: TextStyle(color: t.text3, fontSize: t.fontSizeSmall, height: 1.3),
                    ),
                  ),
                  Text(
                    value,
                    style: TextStyle(
                      color: t.accent,
                      fontSize: t.fontSize,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
