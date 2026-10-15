/// 宿主外壳与内置播放器的**唯一桥接点**。
///
/// 两边刻意解耦：
/// * `app/lib/theme/tokens.dart` —— 宿主的 `DsTokens`（新拟态，浅/深两套）；
/// * `ShikiiN/lib/models/theme_tokens.dart` —— 播放器的 `ThemeTokens`（新拟态子集）。
///
/// 这里做两件事，别处不要再 import `package:shikiin`：
/// 1. `DsTokens` → `ThemeTokens`（播放器跟随宿主的浅/深切换，决策 A6/B22）；
/// 2. 宿主领域层的 `EpisodeGrouping` → 播放器的 `EpisodeGroup`
///    （决策 B31：同剧集的上一集/下一集）。
library;

import 'package:shikiin/shikiin.dart' as shikiin;

import '../domain/episode_group.dart';
import '../theme/tokens.dart';

/// 宿主 token → 播放器 token。
shikiin.ThemeTokens toShikiinTokens(DsTokens t) => shikiin.ThemeTokens(
      base: t.base,
      raised: t.raised,
      sunken: t.sunken,
      // 播放器用 `line` 画极淡分隔；宿主这边对应 `divider`。
      line: t.divider,
      text: t.text,
      text2: t.text2,
      text3: t.text3,
      accent: t.accent,
      accent2: t.accent2,
      success: t.success,
      warning: t.warning,
      danger: t.danger,
      iconColor: t.text2,
      radiusCard: t.radiusCard,
      radiusControl: t.radiusControl,
      radiusPill: t.radiusPill,
      spacing: t.spacing,
      controlHeight: t.controlHeight,
      barHeight: t.barHeight,
      // 播放器窗口的字号跟着宿主的正文档走（用户 2026-10-11 第六轮：「控件文字」也要大）：
      // 以前播放器内部写死 11/12，主窗口调大之后它就成了"窗口里的蚂蚁字"。
      fontSize: t.bodySize,
      // 双阴影色：让播放窗口的控制栏/菜单和宿主是同一套凹凸语言。
      // 宿主「简洁模式」下这两个色本身不参与（宿主那边 shadows() 直接返回空），
      // 这里也跟着传「透明」以免播放器还画阴影。
      // 扁平化后主窗口的卡片不再有阴影，传给播放窗口的阴影色一律是"无阴影"。
      shadowLight: DsTokens.noShadow,
      shadowDark: DsTokens.noShadow,
    );

/// 宿主归组结果 → 播放器的 `EpisodeGroup`。
///
/// 返回 null 表示「没有上一集/下一集」（单集、或还没拿到 torrent 文件清单）——
/// 播放器据此**隐藏**两个按钮（契约 §9：隐藏而不是禁用）。
shikiin.EpisodeGroup? toShikiinEpisodeGroup(EpisodeGrouping? grouping) {
  if (grouping == null || grouping.entries.length <= 1) return null;
  return shikiin.EpisodeGroup(
    items: <shikiin.MediaItem>[
      for (final EpisodeEntry e in grouping.entries)
        shikiin.MediaItem(
          // 本地路径场景用 path；网流场景 path 存 URL 文本、streamUrl 存完整 URL。
          path: e.path,
          title: e.title,
          streamUrl: e.streamUri,
        ),
    ],
    currentIndex: grouping.currentIndex,
  );
}
