import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// 阴影档位（与宿主 `theme/tokens.dart` 的 `NeoShadowLevel` 同名同义）。
enum NeoShadowLevel {
  /// 不使用阴影。
  none,

  /// 滚动列表内（模糊 ≤ 2px，性能红线）。
  soft,

  /// 常规凸起：按钮、控件。
  raised,

  /// 悬浮层：控制栏、菜单、对话框。
  high,
}

/// 新拟态 token 子集：播放器风格的**唯一入口**（契约 §4）。
///
/// 播放器不再有自己的主题系统：所有颜色/圆角/尺寸都从这里读，宿主在
/// `bootstrapPlayer(..., tokens: 它的 DsTokens 同源值)` 或
/// `shikiinOverrides(runtime)` 之后 override `tokensProvider` 注入。
///
/// 扁平字段（与宿主 `DsTokens` 的读法一致）：`tokens.text` / `tokens.accent` /
/// `tokens.radiusControl` / `tokens.controlHeight` / `tokens.spacing`。
///
/// **唯一允许出现颜色字面量的文件**：这里就是 token 源本身（等价于宿主的
/// `theme/tokens.dart`），其余任何播放器文件禁止 `Color(0x…)` 字面量
/// （`test/neo_guard_test.dart` 钉住这条）。
@immutable
class ThemeTokens {
  // ── primitive：三级面 + 分隔线 ─────────────────────────────────────────────
  /// 底色（窗口/播放页背景）。
  final Color base;

  /// 凸起面（卡片、控制栏、菜单）。
  final Color raised;

  /// 凹槽面（进度条轨道、输入框）。
  final Color sunken;

  /// 极淡分隔线（新拟态不用硬边框，只在需要时用这条 1px 微线）。
  final Color line;

  // ── semantic：三级字 + 语义色 ─────────────────────────────────────────────
  /// 主文字。
  final Color text;

  /// 次要文字。
  final Color text2;

  /// 三级文字（标签/表头）。
  final Color text3;

  /// 强调色（进度条填充、选中态、主按钮）。
  final Color accent;

  /// 副强调色（次要元素整体色调）。
  final Color accent2;

  final Color success;
  final Color warning;
  final Color danger;

  /// 图标色。
  final Color iconColor;

  // ── 阴影（新拟态的双阴影；与宿主 `DsTokens` 同源）─────────────────────────
  /// 凸起亮影色（光来自左上）。
  ///
  /// 有默认值：不传时是**透明**，即退化为「只靠面色差表达凹凸」——
  /// 这样不会影响任何已有调用点（契约 §4 的字段本就是追加式的）。
  final Color shadowLight;

  /// 凸起暗影色（右下）。默认透明，同上。
  final Color shadowDark;

  // ── component：几何 ──────────────────────────────────────────────────────
  /// 卡片/面板/对话框/视频画面圆角。
  final double radiusCard;

  /// 按钮/输入框/下拉/开关圆角。
  final double radiusControl;

  /// 胶囊圆角。
  final double radiusPill;

  /// 基础间距（阶梯 8/12/16/24）。
  final double spacing;

  /// 按钮/输入框/下拉高度。
  final double controlHeight;

  /// 顶栏/标题栏高度。
  final double barHeight;

  /// 控件默认字号（正文档）。
  ///
  /// 用户 2026-10-11 第六轮：「标题栏控制栏全都调大些，**包括控件文字**」。
  /// 为什么不直接把各处 `fontSize: 12` 改成 `13`：播放器里所有文字（时间、
  /// 超分胶囊、设置面板、右键菜单）都应该**跟着宿主一起变大**，散落的字面量
  /// 改一处漏一处。放进 token 后，宿主只调这一个值就能整体缩放。
  ///
  /// 有默认值 13：旧的调用点（只传了颜色/几何）不会因此编译不过。
  final double fontSize;

  const ThemeTokens({
    required this.base,
    required this.raised,
    required this.sunken,
    required this.line,
    required this.text,
    required this.text2,
    required this.text3,
    required this.accent,
    required this.accent2,
    required this.success,
    required this.warning,
    required this.danger,
    required this.iconColor,
    required this.radiusCard,
    required this.radiusControl,
    required this.radiusPill,
    required this.spacing,
    required this.controlHeight,
    required this.barHeight,
    this.fontSize = 13,
    this.shadowLight = const Color(0x00000000),
    this.shadowDark = const Color(0x00000000),
  });

  /// 小字档（标签 / 次要说明）：比 [fontSize] 小 2px，和宿主 `DsTypeScale` 的
  /// caption/secondary 关系一致（11/13）。
  double get fontSizeSmall => fontSize - 2;

  /// 双阴影档位：`soft`（列表内，模糊 ≤2px）/ `raised`（常规凸起）/
  /// `high`（悬浮层：控制栏、菜单、对话框）。
  ///
  /// 与宿主 `DsTokens.shadows()` 同一套参数，保证播放窗口和宿主看起来是一套东西。
  /// 两个阴影色都为透明时返回空列表（调用方就只靠面色差表达层次）。
  ///
  /// ⚠️ **2026-10-15 第三十轮（扁平化第二步）**：与宿主同一口径 ——
  /// **只有悬浮层 `high` 允许阴影**，`soft` / `raised` 一律返回空表。
  /// 旧的新拟态凹凸档位（soft 2/4、raised 3/6 的双向近距阴影）在扁平语言里
  /// 已经没有位置：列表行、按钮、卡片的层次靠 `raised`/`sunken` 面色差 + `line` 1px 表达。
  /// `listSafe` 参数保留（调用点还传着），但在扁平口径下不再改变结果。
  List<BoxShadow> shadows(NeoShadowLevel level, {bool listSafe = false}) {
    if (level != NeoShadowLevel.high) return const <BoxShadow>[];
    if (shadowLight.a == 0 && shadowDark.a == 0) {
      return const <BoxShadow>[];
    }
    const double d = 6;
    const double b = 14;
    return <BoxShadow>[
      BoxShadow(color: shadowLight, offset: const Offset(-d, -d), blurRadius: b),
      BoxShadow(color: shadowDark, offset: const Offset(d, d), blurRadius: b),
    ];
  }

  /// 宿主未注入时的兜底：深色新拟态中性面（播放器场景默认深色）。
  static const ThemeTokens fallback = ThemeTokens(
    base: Color(0xFF17181B),
    raised: Color(0xFF1E2024),
    sunken: Color(0xFF121316),
    line: Color(0xFF2A2D33),
    text: Color(0xFFF2F3F5),
    text2: Color(0xFFB4B8C0),
    text3: Color(0xFF7C8189),
    accent: Color(0xFF5B8CFF),
    accent2: Color(0xFF8E7BFF),
    success: Color(0xFF3FBF7F),
    warning: Color(0xFFE0A33E),
    danger: Color(0xFFE05A5A),
    iconColor: Color(0xFFF2F3F5),
    radiusCard: 16,
    radiusControl: 12,
    radiusPill: 999,
    spacing: 8,
    controlHeight: 36,
    barHeight: 46,
    fontSize: 13,
  );

  ThemeTokens copyWith({
    Color? base,
    Color? raised,
    Color? sunken,
    Color? line,
    Color? text,
    Color? text2,
    Color? text3,
    Color? accent,
    Color? accent2,
    Color? success,
    Color? warning,
    Color? danger,
    Color? iconColor,
    double? radiusCard,
    double? radiusControl,
    double? radiusPill,
    double? spacing,
    double? controlHeight,
    double? barHeight,
    double? fontSize,
    Color? shadowLight,
    Color? shadowDark,
  }) =>
      ThemeTokens(
        base: base ?? this.base,
        raised: raised ?? this.raised,
        sunken: sunken ?? this.sunken,
        line: line ?? this.line,
        text: text ?? this.text,
        text2: text2 ?? this.text2,
        text3: text3 ?? this.text3,
        accent: accent ?? this.accent,
        accent2: accent2 ?? this.accent2,
        success: success ?? this.success,
        warning: warning ?? this.warning,
        danger: danger ?? this.danger,
        iconColor: iconColor ?? this.iconColor,
        radiusCard: radiusCard ?? this.radiusCard,
        radiusControl: radiusControl ?? this.radiusControl,
        radiusPill: radiusPill ?? this.radiusPill,
        spacing: spacing ?? this.spacing,
        controlHeight: controlHeight ?? this.controlHeight,
        barHeight: barHeight ?? this.barHeight,
        fontSize: fontSize ?? this.fontSize,
        shadowLight: shadowLight ?? this.shadowLight,
        shadowDark: shadowDark ?? this.shadowDark,
      );

  @override
  bool operator ==(Object other) =>
      other is ThemeTokens &&
      other.base == base &&
      other.raised == raised &&
      other.sunken == sunken &&
      other.line == line &&
      other.text == text &&
      other.text2 == text2 &&
      other.text3 == text3 &&
      other.accent == accent &&
      other.accent2 == accent2 &&
      other.success == success &&
      other.warning == warning &&
      other.danger == danger &&
      other.iconColor == iconColor &&
      other.radiusCard == radiusCard &&
      other.radiusControl == radiusControl &&
      other.radiusPill == radiusPill &&
      other.spacing == spacing &&
      other.controlHeight == controlHeight &&
      other.barHeight == barHeight &&
      other.fontSize == fontSize &&
      other.shadowLight == shadowLight &&
      other.shadowDark == shadowDark;

  @override
  int get hashCode => Object.hashAll([
        base,
        raised,
        sunken,
        line,
        text,
        text2,
        text3,
        accent,
        accent2,
        success,
        warning,
        danger,
        iconColor,
        radiusCard,
        radiusControl,
        radiusPill,
        spacing,
        controlHeight,
        barHeight,
        fontSize,
        shadowLight,
        shadowDark,
      ]);

  /// 播放器**自绘标题栏**的高度：用户 2026-10-10「播放器的标题栏有点粗，砍掉一半」
  /// ⇒ 56 的一半 = **28**。
  ///
  /// 为什么不直接改 [barHeight]：那个 token 父子共用，宿主外壳的工具条也用它，
  /// 改 token 会把主窗口的顶栏一起改窄。所以只压播放器这一条，并且图标 20→14、
  /// 按钮宽 46→34，保证 28px 里塞得下、不挤。
  ///
  /// ⚠️ **2026-10-11 第六轮改回 40**：用户原话「标题栏控制栏全都调大些，包括控件文字」——
  /// 28px 那一版是真机 462×260 小窗里的取舍（当时窗口根本长不大）；第五轮把尺寸上限
  /// 撤掉之后窗口能拖大了，28px 反而变成"看得见点不着"的一条细缝（按钮命中区只有
  /// 34×28，字只有 11-12px）。40px = 14px 图标 + 13-14px 文字 + 44×40 命中区，
  /// 与宿主工具条（56→46）同一档观感。
  static const double titleBarHeight = 40;

  /// 画面区（letterbox / pillarbox）的底色：**恒为纯黑，不跟随主题**。
  ///
  /// 用户 2026-10-10：「视频的边边改为全黑色，不要和标题栏控制栏同色，会显得这两个变粗了」。
  ///
  /// 以前画面区铺的是 `tokens.base`，而那正好是**标题栏的底色**（控制栏是 `raised`，
  /// 深色主题下与 `base` 只差一点）。于是画面上下留黑边时，标题栏/控制栏和黑边糊成一片，
  /// 看不出这条栏只有 28px / 36px 高 —— 视觉上"变粗"。改成纯黑之后，
  /// 黑边与栏之间有一条明确的界线，栏看起来就是它真实的高度。
  ///
  /// 浅色主题下同样是纯黑：这是播放器的通用语言（mpv / VLC / YouTube 都这样），
  /// 亮底黑边反而会让画面显得更小、更晃眼。
  static const Color videoLetterbox = Color(0xFF000000);

  /// 两个 token 之间插值（宿主浅/深切换时把播放窗口的颜色平滑地跟过去）。
  ///
  /// 用户 2026-10-10 报「切换深色生硬会闪烁」：主窗口是 `MaterialApp` 的整棵树
  /// color lerp，播放窗口也得跟着渐变，否则它是一刀切。几何量按 [t] 线性插值。
  static ThemeTokens lerp(ThemeTokens a, ThemeTokens b, double t) {
    Color c(Color x, Color y) => Color.lerp(x, y, t) ?? y;
    double d(double x, double y) => x + (y - x) * t;
    return ThemeTokens(
      base: c(a.base, b.base),
      raised: c(a.raised, b.raised),
      sunken: c(a.sunken, b.sunken),
      line: c(a.line, b.line),
      text: c(a.text, b.text),
      text2: c(a.text2, b.text2),
      text3: c(a.text3, b.text3),
      accent: c(a.accent, b.accent),
      accent2: c(a.accent2, b.accent2),
      success: c(a.success, b.success),
      warning: c(a.warning, b.warning),
      danger: c(a.danger, b.danger),
      iconColor: c(a.iconColor, b.iconColor),
      shadowLight: c(a.shadowLight, b.shadowLight),
      shadowDark: c(a.shadowDark, b.shadowDark),
      radiusCard: d(a.radiusCard, b.radiusCard),
      radiusControl: d(a.radiusControl, b.radiusControl),
      radiusPill: d(a.radiusPill, b.radiusPill),
      spacing: d(a.spacing, b.spacing),
      controlHeight: d(a.controlHeight, b.controlHeight),
      barHeight: d(a.barHeight, b.barHeight),
      fontSize: d(a.fontSize, b.fontSize),
    );
  }
}
