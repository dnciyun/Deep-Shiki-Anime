/// 主题与格式化工具的单元测试（外壳 UI 的测试见 `shell_widget_test.dart`）。
library;

import 'package:dsanima/domain/disk_space.dart';
import 'package:dsanima/domain/episodes.dart';
import 'package:dsanima/domain/format.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/site_links.dart';
import 'package:dsanima/domain/trackers.dart';
import 'package:dsanima/state/host_store.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('扁平 token：三级色差 + 扁平几何齐全（规范 §3 / §5）', () {
    for (final DsTokens t in <DsTokens>[
      DsTokens.whiteOrange,
      DsTokens.blackMono,
    ]) {
      // primitive
      expect(t.base, isNot(t.raised));
      expect(t.raised, isNot(t.sunken));
      // semantic
      expect(t.text, isNot(t.text2));
      expect(t.text2, isNot(t.text3));
      expect(t.onAccent, isNot(t.text));
      // component 几何（规范 §3）：卡片 16 → 12、控件 12 → 8、胶囊 999 不变、
      // 徽标 6 新增、控件高 44 → 40、工具条 46 → 44；间距 8 不变。
      // 第二十九轮扁平化：断言从旧几何（16 / 12 / 44 / 46）改成 §3 的新值，
      // 但**保留"八套外观几何一致"这层意思**（它是这个用例真正在守的东西）。
      expect(t.radiusCard, 12);
      expect(t.radiusControl, 8);
      expect(t.radiusPill, 999);
      expect(t.radiusBadge, 6);
      expect(t.spacing, 8);
      expect(t.controlHeight, 40);
      expect(t.barHeight, 44);
    }
    expect(DsTokens.blackMono.isDark, isTrue);
    expect(DsTokens.whiteInk.isDark, isFalse);
  });

  test('token 常量与短别名指向同一批 const；旧名（light/dark/a/hairline/statusBarHeight）已删除', () {
    // 短别名（= 枚举成员名）与枚举的 tokens 必须是同一批常量（规范 §12.1 用短名读色表）。
    expect(DsTokens.wInk, DsAppearance.wInk.tokens);
    expect(DsTokens.bMono, DsAppearance.bMono.tokens);
    expect(DsTokens.bRed, DsAppearance.bRed.tokens);
    expect(DsTokens.of(DsAppearance.bNeon), DsTokens.blackNeon);
    // 八套齐全（第二十九轮收口后只剩这八套 + 短别名，过渡名全删）。
    expect(DsAppearance.values, hasLength(8));
    for (final DsAppearance a in DsAppearance.values) {
      expect(DsTokens.of(a), a.tokens);
    }
  });

  test('外观迁移：light→白黑、dark→黑白、A/C/B/空/乱码→白黑，不崩', () {
    expect(DsAppearance.fromCode('dark'), DsAppearance.bMono);
    expect(DsAppearance.fromCode('light'), DsAppearance.wInk);
    // 旧的三套暗色主题 id 已被删除，必须安全回退（不崩、不丢其它设置）。
    for (final String? old in <String?>['A', 'C', 'B', '乱码', null]) {
      expect(DsAppearance.fromCode(old), DsAppearance.wInk);
    }
    // AppSettings 层的同一回退路径（黑色系四个 code 为真，旧值一律为假）。
    expect(const AppSettings().isDarkTheme, isFalse);
    expect(const AppSettings(themeId: 'A').isDarkTheme, isFalse);
    expect(const AppSettings(themeId: 'light').isDarkTheme, isFalse);
    for (final String code in <String>['b_neon', 'b_electric', 'b_mono', 'b_red']) {
      expect(AppSettings(themeId: code).isDarkTheme, isTrue, reason: code);
    }
  });

  test('无障碍：八套外观 × 三个承载面 × 四级文字 + onAccent + 语义色 ≥ 4.5:1（规范 §5.3）', () {
    final List<({String name, Color fg, Color bg})> pairs = dsContrastPairs();
    // 8 套 × 3 面 × {text, text2, text3, accent} + 8 个 onAccent + 8×3 语义色。
    // 第二十九轮扁平化：从「浅/深两套」扩到八套外观（规范 §5.3 / §12.1）。
    // 第五十三轮：色相收回主题色，改成 + 8 套 × 7 面「强调色文字档」（3 承载面 +
    // 3 个 12% 淡底 + 页面洗色顶）。
    expect(pairs, hasLength(8 * 3 * 4 + 8 + 8 * 3 + 8 * 7));
    for (final ({String name, Color fg, Color bg}) p in pairs) {
      final double ratio = dsContrastRatio(p.fg, p.bg);
      expect(
        ratio,
        greaterThanOrEqualTo(4.5),
        reason: '${p.name} 对比度只有 ${ratio.toStringAsFixed(2)}:1',
      );
    }
  });

  test('字号阶梯只有 5 档（决策 A35，禁止新增字面量）', () {
    // 2026-10-11 第六轮整体上调一档（11/12/13/15/20 → 12/14/15/17/24，用户要
    // 「标题栏控制栏全都调大些，包括控件文字」）。这个用例守的是**只有 5 档、
    // 且从小到大严格递增**这条规范；具体数值可以随轮次调整，但不能多出第 6 档。
    expect(DsTypeScale.all, <double>[12, 14, 15, 17, 24]);
    expect(DsTypeScale.all.length, 5, reason: '决策 A35：字号只允许 5 档');
    for (int i = 1; i < DsTypeScale.all.length; i++) {
      expect(
        DsTypeScale.all[i],
        greaterThan(DsTypeScale.all[i - 1]),
        reason: '阶梯必须严格递增：第 $i 档 ${DsTypeScale.all[i]} 不大于前一档',
      );
    }
    expect(DsTypeScale.all, contains(DsTypeScale.caption));
    expect(DsTypeScale.all, contains(DsTypeScale.secondary));
    expect(DsTypeScale.all, contains(DsTypeScale.body));
    expect(DsTypeScale.all, contains(DsTypeScale.title));
    expect(DsTypeScale.all, contains(DsTypeScale.display));
  });

  test('阴影：只有悬浮层一档（枚举里也没别的档位了），listSafe 模糊 ≤ 2px（规范 §7 / 决策 A31）', () {
    // 第二十九轮收口：`none` / `soft` / `raised` 三档**已从枚举里删除** ——
    // 扁平化后除悬浮层外一律零阴影，"选一档"这件事本身就不存在了。
    expect(NeoShadowLevel.values, <NeoShadowLevel>[NeoShadowLevel.high]);
    for (final DsTokens t in <DsTokens>[DsTokens.whiteInk, DsTokens.blackMono]) {
      final String who = t.isDark ? '黑色系' : '白色系';
      expect(t.shadows(NeoShadowLevel.high), isNotEmpty, reason: '$who 的悬浮层要有阴影');
      // 列表红线：无论如何都不许超过 2px。
      expect(
        t.shadows(NeoShadowLevel.high, listSafe: true).first.blurRadius,
        lessThanOrEqualTo(2),
      );
    }
  });

  test('主题组装：8 套外观都能从 Theme 取回 token；内容层零高度、悬浮层唯一的 overlayElevation（规范 §3/§6/§7）', () {
    for (final DsAppearance a in DsAppearance.values) {
      final DsTokens t = a.tokens;
      final ThemeData theme = buildDsanimaTheme(tokens: t);
      expect(theme.extension<DsTokens>(), t, reason: '${a.code} 的 token 要从 Theme 取回');
      expect(theme.scaffoldBackgroundColor, t.base);
      expect(theme.brightness, t.isDark ? Brightness.dark : Brightness.light);
      // 扁平：内容层（卡片）elevation 一律 0；只有悬浮层带 overlayElevation。
      expect(theme.cardTheme.elevation, 0);
      expect(theme.dialogTheme.elevation, t.overlayElevation);
      expect(theme.popupMenuTheme.elevation, t.overlayElevation);
      expect(theme.bottomSheetTheme.elevation, t.overlayElevation);
      // 面与描边：卡片 = raised；输入框 = sunken。
      expect(theme.cardTheme.color, t.raised);
      expect(theme.inputDecorationTheme.fillColor, t.sunken);
      // 主按钮 = accent 实底 + onAccent 文字（规范 §6）。
      expect(
        theme.filledButtonTheme.style!.backgroundColor!.resolve(<WidgetState>{}),
        t.accent,
      );
      expect(
        theme.filledButtonTheme.style!.foregroundColor!.resolve(<WidgetState>{}),
        t.onAccent,
      );
    }
  });

  test('表头样式 11px + letter-spacing .08em；数字用 tabular figures', () {
    final TextStyle header = dsTableHeaderStyle(DsTokens.whiteInk);
    expect(header.fontSize, DsTypeScale.caption);
    expect(header.letterSpacing, closeTo(DsTypeScale.caption * 0.08, 0.001));
    expect(dsNumStyle(DsTokens.whiteInk).fontFeatures, contains(const FontFeature.tabularFigures()));
  });

  test('formatBytes / formatSpeed / formatPercent / formatTtl', () {
    expect(formatBytes(0), '—');
    expect(formatBytes(null), '—');
    expect(formatBytes(734003200), '700.0 MiB');
    expect(formatSpeed(0), '—');
    expect(formatSpeed(1048576), '1.0 MiB/s');
    expect(formatPercent(0.4567), '45.7%');
    expect(formatPercent(1), '100%');
    expect(formatTtl(300), '5 分钟');
    expect(formatTtl(86400), '24 小时');
  });

  test('AppSettings JSON 往返（Hive 持久化用）', () {
    const AppSettings original = AppSettings(
      downloadDir: r'F:\Anime',
      proxyMode: ProxyMode.socks5,
      proxyPort: 1081,
      uploadLimitKbps: 512,
      bandwidth: BandwidthPolicy(
        preheatAhead: 3,
        maxConcurrent: 2,
        excludePatterns: <String>['合集'],
      ),
      autoPlayNext: false,
      firstRunCompleted: true,
    );
    final AppSettings restored = AppSettings.fromJson(original.toJson().cast<Object?, Object?>());
    expect(restored.downloadDir, r'F:\Anime');
    expect(restored.proxyMode, ProxyMode.socks5);
    expect(restored.uploadLimitKbps, 512);
    expect(restored.bandwidth.preheatAhead, 3);
    expect(restored.bandwidth.maxConcurrent, 2);
    expect(restored.bandwidth.excludePatterns, <String>['合集']);
    expect(restored.autoPlayNext, isFalse);
    expect(restored.firstRunCompleted, isTrue);
    expect(restored.trackerSourceUrls, kDefaultTrackerSourceUrls);
  });

  test('AppSettings：tracker 来源清单往返（删空后不会被默认值长回来）', () {
    final AppSettings custom = AppSettings(
      trackerSourceUrls: <String>[kTrackersAllUrl, kTrackersBestMirrorUrl],
    );
    final AppSettings restored = AppSettings.fromJson(custom.toJson().cast<Object?, Object?>());
    expect(restored.trackerSourceUrls, <String>[kTrackersAllUrl, kTrackersBestMirrorUrl]);

    // 显式清空 = 用户把来源全删了，必须保持空。
    final AppSettings emptied = AppSettings.fromJson(
      AppSettings(trackerSourceUrls: <String>[]).toJson().cast<Object?, Object?>(),
    );
    expect(emptied.trackerSourceUrls, isEmpty);

    // 老配置（没这个字段）→ 回落到默认 best 一条，一键更新照旧能用。
    expect(
      AppSettings.fromJson(<Object?, Object?>{'extraTrackers': 'x'}).trackerSourceUrls,
      kDefaultTrackerSourceUrls,
    );
    // 脏项（非字符串/空白/重复）清掉。
    expect(
      AppSettings.fromJson(<Object?, Object?>{
        'trackerSourceUrls': <Object?>[kTrackersListUrl, 42, '', ' $kTrackersListUrl '],
      }).trackerSourceUrls,
      <String>[kTrackersListUrl],
    );
  });

  test('AppSettings 缺字段/脏数据容错（不崩、回落默认值）', () {
    final AppSettings restored = AppSettings.fromJson(<Object?, Object?>{
      'proxyMode': '不存在的模式',
      'maxConcurrent': 'x',
    });
    expect(restored.proxyMode, ProxyMode.none);
    expect(restored.bandwidth.maxConcurrent, 1);
    expect(restored.firstRunCompleted, isFalse);
  });

  test('集数推导：只认同源同组且集数更大的后续集', () {
    SourceItemView item(String id, String group, List<String> hints) =>
        SourceItemView(id: id, sourceId: 'nyaa', group: group, episodeHints: hints);

    final SourceItemView ep1 = item('a', 'G', <String>['01']);
    final SourceItemView ep2 = item('b', 'G', <String>['02']);
    final SourceItemView ep10 = item('c', 'G', <String>['10']);
    final SourceItemView other = item('d', 'H', <String>['03']);
    final SourceItemView noHint = item('e', 'G', <String>[]);

    final List<SourceItemView> next = followingEpisodes(<SourceItemView>[
      ep2,
      other,
      ep10,
      noHint,
      ep1,
    ], ep1);
    expect(next.map((SourceItemView i) => i.id).toList(), <String>['b', 'c']);
    expect(followingEpisodes(<SourceItemView>[ep2], noHint), isEmpty);
  });

  test('链接识别：mikan 番剧页 → 番剧 RSS；单集页 → 说明后兜底最新', () {
    final SubscriptionDraft? bangumi = parseSubscriptionLink(
      'https://mikanani.me/Home/Bangumi/4094',
    );
    expect(bangumi, isNotNull);
    expect(bangumi!.sourceKind, 'mikan');
    expect(bangumi.feedUrl, 'https://mikanani.me/RSS/Bangumi?bangumiId=4094');
    expect(bangumi.note, contains('番剧页'));

    final SubscriptionDraft? episode = parseSubscriptionLink(
      'https://mikanani.me/Home/Episode/f5271d82a1b2c3',
    );
    expect(episode!.sourceKind, 'mikan');
    expect(episode.feedUrl, 'https://mikanani.me/RSS/Classic');
    expect(episode.note, contains('单集页'));

    final SubscriptionDraft? nyaa = parseSubscriptionLink('https://nyaa.si/view/2171209');
    expect(nyaa!.sourceKind, 'nyaa');
    expect(nyaa.feedUrl, contains('page=rss'));

    final SubscriptionDraft? rss = parseSubscriptionLink('https://example.com/feed.xml');
    expect(rss!.sourceKind, 'rss');
    expect(rss.feedUrl, 'https://example.com/feed.xml');

    expect(parseSubscriptionLink('这不是链接'), isNull);
    expect(parseSubscriptionLink(''), isNull);
  });

  test('tracker 列表：一键更新文本与解析去重', () {
    expect(builtinTrackers.length, greaterThanOrEqualTo(6));
    expect(trackerListText(builtinTrackers), contains('udp://'));
    expect(parseTrackerList('a,b  a\nc'), <String>['a', 'b', 'c']);
  });

  test('tracker 来源：多来源合并去重 + URL 校验 + 默认清单', () {
    // 用户 2026-10-11：「可以通过导入 URL 获取里面的所有 tracker，也可以使用多条获取」。
    expect(kDefaultTrackerSourceUrls, <String>[kTrackersListUrl]);
    expect(
      trackerSourcePresets.map((TrackerSourcePreset p) => p.url),
      containsAll(<String>[kTrackersListUrl, kTrackersAllUrl, kTrackersBestMirrorUrl]),
    );

    // 合并：按来源顺序、跨来源去重（best 与 all 里重复的那条只留一份）。
    expect(
      mergeTrackerLists(<List<String>>[
        <String>['udp://a:1/announce', 'udp://b:2/announce'],
        <String>['udp://b:2/announce', 'udp://c:3/announce'],
      ]),
      <String>['udp://a:1/announce', 'udp://b:2/announce', 'udp://c:3/announce'],
    );

    // URL 校验：只认 http(s) 且有主机；粘贴进来的杂七杂八先在这里拦掉。
    expect(isTrackerSourceUrl(kTrackersAllUrl), isTrue);
    expect(isTrackerSourceUrl('  https://example.com/list.txt '), isTrue);
    expect(isTrackerSourceUrl('ftp://example.com/x'), isFalse);
    expect(isTrackerSourceUrl('example.com/x'), isFalse);
    expect(isTrackerSourceUrl('udp://tracker.example:80/announce'), isFalse);
    expect(isTrackerSourceUrl(''), isFalse);

    // 规范化：空白项/无效项/重复项都清掉（保序）。
    expect(
      normalizeTrackerSourceUrls(<String>[
        kTrackersListUrl,
        ' $kTrackersAllUrl ',
        kTrackersListUrl,
        '不是链接',
        '',
      ]),
      <String>[kTrackersListUrl, kTrackersAllUrl],
    );
  });

  test('磁盘探测：盘符提取与输出解析（失败返回 null，不猜）', () {
    expect(driveLetterOf(r'F:\Anime'), 'F');
    expect(driveLetterOf(r'd:\x\y'), 'D');
    expect(driveLetterOf(r'\\server\share'), isNull);
    expect(driveLetterOf(''), isNull);
    expect(parseFreeBytes('1899661234567'), 1899661234567);
    expect(parseFreeBytes('  42 \r\n'), 42);
    expect(parseFreeBytes('取不到'), isNull);
  });

  test('继续观看记录：JSON 往返 + 脏数据丢弃', () {
    final RecentPlayed entry = RecentPlayed(
      title: '葬送的芙莉莲 第 03 话',
      engineId: 3,
      fileIndex: 0,
      at: DateTime(2026, 10, 8, 20),
      sourceItemId: 'nyaa:2171209',
    );
    final RecentPlayed? back = RecentPlayed.fromJson(entry.toJson());
    expect(back, isNotNull);
    expect(back!.title, entry.title);
    expect(back.engineId, 3);
    expect(back.at, entry.at);
    expect(RecentPlayed.fromJson(<String, Object?>{'title': 'x'}), isNull);
    expect(RecentPlayed.fromJson('不是 map'), isNull);
  });
}
