/// DSAnima 扁平化主题 token。
///
/// 规范（绑定权威）：`docs/specs/2026-10-14-dsanima-flat-theme.md`。
///
/// 三层语义（沿用决策 A38：**内部分三层，对外仍是一个 `DsTokens`**，`context.ds` 读法不变）：
/// * **primitive** —— 面与描边：`base / raised / sunken / line`（`shadowLight / shadowDark`
///   现在只服务 §7 的悬浮层，见 [shadows]）；
/// * **semantic** —— 文字与语义色：`text / text2 / text3 / accent / onAccent / success / warning / danger`；
/// * **component** —— 成套取值：圆角 / 间距 / 控件高 / 字号阶梯 / 阴影档位。
///
/// **八套外观**（规范 §5）：白色系 `whiteOrange / whitePurple / whiteMint / whiteInk` +
/// 黑色系 `blackNeon / blackElectric / blackMono / blackRed`，由 [DsAppearance] 索引
/// （`code` 持久化、`label` 中文名、`family` 分组、`isDark` 明暗）。
/// 色表**逐字**抄自 §5.2 / §5.4，实施时不得自行调色。
///
/// **扁平**：除悬浮层（对话框 / 右键菜单 / Tooltip / 下拉浮层，§7）外**一律没有阴影**，
/// 层次只靠 `base / raised / sunken` 三级色差 + 1px `line` 描边（[cardDecoration] / [inset]）。
///
/// ⚠️ **过渡期遗留**（Task 9 删除，见 [DsBrightness]、[line]、`simpleMode`、
/// `statusBarHeight`、[raisedDecoration] / [sunkenDecoration]）：这些名字只为让既有
/// ~210 个调用点在迁移期继续编译，取值已经切到扁平外观
/// （`light` = [whiteInk]、`dark` = [blackMono]），**不要在新代码里用**。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 外观分组（规范 §5.1 / §5.6：选择器分两行「白色系」「黑色系」）。
enum DsAppearanceFamily {
  white('白色系'),
  black('黑色系');

  const DsAppearanceFamily(this.label);
  final String label;
}

/// 八套外观（规范 §5.1）。
///
/// [code] 是持久化用的字符串（`AppSettings.themeId`），[label] 是界面上的中文名，
/// [family] 决定选择器里排在哪一行，[isDark] 决定 Material 侧的 brightness。
/// 每套的三级面 / 文字 / 语义色见 [tokens]。
enum DsAppearance {
  wOrange('w_orange', '白橙', DsAppearanceFamily.white),
  wPurple('w_purple', '紫白', DsAppearanceFamily.white),
  wMint('w_mint', '薄荷绿白', DsAppearanceFamily.white),
  wInk('w_ink', '白黑', DsAppearanceFamily.white),
  bNeon('b_neon', '荧光绿黑', DsAppearanceFamily.black),
  bElectric('b_electric', '黑电光蓝', DsAppearanceFamily.black),
  bMono('b_mono', '黑白', DsAppearanceFamily.black),
  bRed('b_red', '黑红', DsAppearanceFamily.black);

  const DsAppearance(this.code, this.label, this.family);

  final String code;
  final String label;
  final DsAppearanceFamily family;

  /// 黑色系 = 深色（Material 的 [Brightness.dark]）。
  bool get isDark => family == DsAppearanceFamily.black;

  /// 本套外观的 token。
  DsTokens get tokens => switch (this) {
        DsAppearance.wOrange => DsTokens.whiteOrange,
        DsAppearance.wPurple => DsTokens.whitePurple,
        DsAppearance.wMint => DsTokens.whiteMint,
        DsAppearance.wInk => DsTokens.whiteInk,
        DsAppearance.bNeon => DsTokens.blackNeon,
        DsAppearance.bElectric => DsTokens.blackElectric,
        DsAppearance.bMono => DsTokens.blackMono,
        DsAppearance.bRed => DsTokens.blackRed,
      };

  /// 旧值迁移（规范 §5.5）：`light` → 白黑、`dark` → 黑白、
  /// `A` / `C` / `B` / 空 / 乱码 / null → 白黑。不崩、不丢其它设置。
  static DsAppearance fromCode(String? code) {
    if (code == 'light') return DsAppearance.wInk;
    if (code == 'dark') return DsAppearance.bMono;
    for (final DsAppearance a in DsAppearance.values) {
      if (a.code == code) return a;
    }
    return DsAppearance.wInk;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 标识色相（第五十二轮：用户「整个项目太素」）
// ─────────────────────────────────────────────────────────────────────────────

/// **标识色相** —— 页面 / 来源 / 标签各自一色的固定色环。
///
/// 为什么需要它：扁平化之后全应用只有一个 `accent`（规范 §2 第 3 条「只有一个强调色」），
/// 信息密度高的页面（动漫库 30 多颗类型胶囊、搜索页 7 个源、队列/历史/已完成三张列表）
/// 全靠 `raised` 白面 + `text2` 灰字，用户 2026-10-17 的原话就是「整个项目太素」。
///
/// 这一层把「颜色」变成**信息编码**而不是装饰：
/// * 每个导航目的地一个色相（主页橙 / 动漫库紫 / 搜索青 / 追番粉 / 队列蓝 / 已完成绿 /
///   观看记录金 / 设置灰）；
/// * 每个种子源一个色相（mikan 橙 / dmhy 蓝 / nyaa 紫 / acgxn 玫红 …）；
/// * 标签按语义分色（奇幻紫 / 科幻青 / 恋爱粉 / 热血玫红 …）。
///
/// **两档取值**（[DsHueColors]）：[DsHueColors.ink] 给文字与图标（在 8 套外观的
/// base / raised / sunken / 12% 淡底上都 ≥4.5:1，由 `test/widget_test.dart` 守卫）；
/// [DsHueColors.fill] 给点 / 细条 / 进度条 / 渐变色块这类**不承载文字**的装饰。
/// 深色外观上两档同值（亮色在近黑底上既够亮也够对比）。
enum DsHue {
  orange,
  amber,
  gold,
  emerald,
  teal,
  cyan,
  blue,
  indigo,
  violet,
  pink,
  rose,
  slate,
}

/// 一个色相的两档取值（见 [DsHue]）。
@immutable
class DsHueColors {
  const DsHueColors({required this.ink, required this.fill});

  /// 文字 / 图标色：浅色外观上在 `base / raised / sunken` 与 12% 淡底上均 ≥4.5:1。
  final Color ink;

  /// 装饰填充色：点 / 细条 / 进度条 / 渐变。**不要**拿它当文字色（对比度不够）。
  final Color fill;
}

/// 浅色外观的 12 色（第五十二轮实测值，见 `build/round52/hue_contrast.py`）。
const Map<DsHue, DsHueColors> _hueLight = <DsHue, DsHueColors>{
  DsHue.orange: DsHueColors(ink: Color(0xFFB2430A), fill: Color(0xFFF97316)),
  DsHue.amber: DsHueColors(ink: Color(0xFF92400E), fill: Color(0xFFF59E0B)),
  DsHue.gold: DsHueColors(ink: Color(0xFF854D0E), fill: Color(0xFFEAB308)),
  DsHue.emerald: DsHueColors(ink: Color(0xFF047857), fill: Color(0xFF10B981)),
  DsHue.teal: DsHueColors(ink: Color(0xFF0F766E), fill: Color(0xFF14B8A6)),
  DsHue.cyan: DsHueColors(ink: Color(0xFF0E7490), fill: Color(0xFF06B6D4)),
  DsHue.blue: DsHueColors(ink: Color(0xFF1D4ED8), fill: Color(0xFF3B82F6)),
  DsHue.indigo: DsHueColors(ink: Color(0xFF4338CA), fill: Color(0xFF6366F1)),
  DsHue.violet: DsHueColors(ink: Color(0xFF6D28D9), fill: Color(0xFF8B5CF6)),
  DsHue.pink: DsHueColors(ink: Color(0xFFBE185D), fill: Color(0xFFEC4899)),
  DsHue.rose: DsHueColors(ink: Color(0xFFBE123C), fill: Color(0xFFF43F5E)),
  DsHue.slate: DsHueColors(ink: Color(0xFF475569), fill: Color(0xFF64748B)),
};

/// 深色外观的 12 色（在 `#07090C`–`#1C1618` 这一档底上均 ≥4.5:1）。
const Map<DsHue, DsHueColors> _hueDark = <DsHue, DsHueColors>{
  DsHue.orange: DsHueColors(ink: Color(0xFFFB923C), fill: Color(0xFFFB923C)),
  DsHue.amber: DsHueColors(ink: Color(0xFFFBBF24), fill: Color(0xFFFBBF24)),
  DsHue.gold: DsHueColors(ink: Color(0xFFFACC15), fill: Color(0xFFFACC15)),
  DsHue.emerald: DsHueColors(ink: Color(0xFF34D399), fill: Color(0xFF34D399)),
  DsHue.teal: DsHueColors(ink: Color(0xFF2DD4BF), fill: Color(0xFF2DD4BF)),
  DsHue.cyan: DsHueColors(ink: Color(0xFF22D3EE), fill: Color(0xFF22D3EE)),
  DsHue.blue: DsHueColors(ink: Color(0xFF60A5FA), fill: Color(0xFF60A5FA)),
  DsHue.indigo: DsHueColors(ink: Color(0xFFA5B4FC), fill: Color(0xFFA5B4FC)),
  DsHue.violet: DsHueColors(ink: Color(0xFFC4B5FD), fill: Color(0xFFC4B5FD)),
  DsHue.pink: DsHueColors(ink: Color(0xFFF472B6), fill: Color(0xFFF472B6)),
  DsHue.rose: DsHueColors(ink: Color(0xFFFB7185), fill: Color(0xFFFB7185)),
  DsHue.slate: DsHueColors(ink: Color(0xFF94A3B8), fill: Color(0xFF94A3B8)),
};

/// 阴影档位。业务代码只允许用档位，不直接写 `BoxShadow`。
///
/// 扁平化后**只有 [high] 还会产生阴影**（规范 §7：悬浮层是唯一的例外），
/// 其余三档保留枚举值只为让旧调用点继续编译（Task 9 收敛）。
/// 阴影档位（第二十九轮收口：**只剩悬浮层这一档**）。
///
/// 新拟态时代的 `none` / `soft` / `raised` 已删除 —— 它们在新实现里本来就返回空列表，
/// 留着只会让调用方以为"还能选一档"。扁平规范的唯一例外是悬浮层（规范 §7）。
enum NeoShadowLevel {
  /// 悬浮层：对话框、右键菜单、tooltip、下拉浮层。
  high,
}

/// 字号阶梯（决策 A35：**只允许这 5 档**，禁止新增字面量）。
///
/// ⚠️ **2026-10-11 第六轮整体上调一档**（用户原话：「标题栏控制栏全都调大些，**包括控件文字**」）：
/// 11/12/13/15/20 → 12/14/15/17/24。为什么整体抬而不是只改几处：
/// 字号在这套 UI 里是**相对关系**（caption < secondary < body < title < display），
/// 只放大标题栏会让它比页面标题还大；宿主与播放窗口又共用这套档位
/// （`player_bridge.toShikiiinTokens` 把 bodySize 传成播放器的 fontSize），
/// 所以"调大"必须一次性在阶梯上做，才不会出现"主窗口小、播放器大"。
///
/// 扁平化（第二十九轮）**不动字号**（规范 §4）：12/14/15/17/24 保持不变，
/// 「淡」改由 w300 细体 + 高对比三级色表达。
class DsTypeScale {
  const DsTypeScale._();

  static const double caption = 12; // 标签 / 表头 / 徽标
  static const double secondary = 14; // 次要正文
  static const double body = 15; // 正文（默认）
  static const double title = 17; // 区块标题
  static const double display = 24; // 页面大标题

  /// 允许出现的全部字号，测试用它守住「不新增字面量」。
  static const List<double> all = <double>[
    caption,
    secondary,
    body,
    title,
    display,
  ];
}

// ── 几何枚举（规范 §3.1 / §3.2 / §3.3）────────────────────────────────────────

/// 真海报宽高比中位数（规范 §3.1 / F22）：宽 ÷ 高 = 0.705。
///
/// 全应用共用：今日更新网格封面、推荐栏卡片、轮播邻卡。
/// 网格封面框 = 宽 208 时高 295（旧实现用 `aspectRatio: 1`，`BoxFit.cover`
/// 会把竖版海报裁掉约 30% 的高度）。
const double kPosterAspect = 0.705;

/// 设置里的「封面大小」（规范 §3.2 / F23）：只影响今日更新网格的宽度封顶。
enum DsCoverSize {
  s('s', '小', 172),
  m('m', '中', 208),
  l('l', '大', 250);

  const DsCoverSize(this.code, this.label, this.maxWidth);

  /// 持久化 code（`AppSettings.homeCoverSize`）。
  final String code;
  final String label;

  /// 网格封面的宽度封顶（逻辑像素）。
  final double maxWidth;

  /// 旧 JSON 无此键 / 值非法 → 中档（老用户升级后零变化）。
  static DsCoverSize fromCode(String? code) => DsCoverSize.values.firstWhere(
        (DsCoverSize v) => v.code == code,
        orElse: () => DsCoverSize.m,
      );
}

/// 设置里的「提前预热后几集」（第三十八轮）。
///
/// 用户原话：「添加逻辑默认关闭，可提前预热后几集」。所以这里是**四档**（关 / 1 / 2 / 3），
/// 默认那档是 `off` —— 值本身存在 `AppSettings.bandwidth.preheatAhead`（int），
/// 这一层只负责分段控件的中文名。
enum DsPreheatAhead {
  off(0, '关'),
  one(1, '1 集'),
  two(2, '2 集'),
  three(3, '3 集');

  const DsPreheatAhead(this.count, this.label);

  /// 真正写进设置的值（也是 core 策略里的档位）。
  final int count;
  final String label;

  /// 认不出的值（老配置/乱码）一律回退 [off]：默认关闭是本轮定的语义。
  static DsPreheatAhead fromCount(int count) => DsPreheatAhead.values.firstWhere(
        (DsPreheatAhead v) => v.count == count,
        orElse: () => DsPreheatAhead.off,
      );
}

/// 设置里的「轮播封面」（规范 §3.3 / F24）：横版 3:2（默认，= 现状）/ 竖版 0.705。
enum DsCarouselShape {
  landscape('landscape', '横版'),
  portrait('portrait', '竖版');

  const DsCarouselShape(this.code, this.label);

  final String code;
  final String label;

  /// 旧 JSON 无此键 / 值非法 → 横版（默认与现状完全一致）。
  static DsCarouselShape fromCode(String? code) =>
      DsCarouselShape.values.firstWhere(
        (DsCarouselShape v) => v.code == code,
        orElse: () => DsCarouselShape.landscape,
      );
}

/// 设置里的「轮播大小」（规范 §3.3 / F24 / F28）：小 0.85 / **中 1.2（默认）** / 大 1.5。
///
/// [k] 是档位系数：主卡、两侧邻卡、整块高度**一起**等比缩放；字号与圆点直径不缩放。
///
/// ⚠️ 2026-10-15 第三十二轮（用户：「把轮播的大改成中，新增更大的」）：**档位整体上移一档** ——
/// 原来的「大 1.2」改名「**中**」，并新增更大的「**大 1.5**」；原来的「中 1.0」没有名字可挂，
/// **退休**（`m` 这个 code 现在指 1.2，见 §17.1）。默认仍是 `m` ⇒ 默认观感 = 旧的「大」。
enum DsCarouselSize {
  s('s', '小', 0.85),
  m('m', '中', 1.2),
  l('l', '大', 1.5);

  const DsCarouselSize(this.code, this.label, this.k);

  final String code;
  final String label;
  final double k;

  /// 旧 JSON 无此键 / 值非法 → 中档（1.2；第三十二轮之前这个尺寸挂在「大」上）。
  static DsCarouselSize fromCode(String? code) => DsCarouselSize.values.firstWhere(
        (DsCarouselSize v) => v.code == code,
        orElse: () => DsCarouselSize.m,
      );
}

/// 轮播几何（规范 §3.3）：形状 × 大小 → 主卡 / 邻卡尺寸 + 整块高度。
///
/// 基准尺寸（`k = 1.0` 的账面值，实际档位不再取 1.0）：横版主卡 460×300、邻卡 220×236；
/// 竖版主卡 312×443、邻卡 222×315。缩放一律 `(base * k).roundToDouble()`，
/// 整块高度 = 主卡高 + `12k`（图文间距）+ 40（文字块）+ 14（底部留白）。
///
/// ⚠️ 最宽那档（大 1.5）的横版整块 = 1266，**超过** 1280 窗宽下的内容宽 1060：
/// 外层 `Center` 会把块约束回可用宽度（`SizedBox` 服从父约束），于是两侧邻卡自动被推到边上、
/// 被主卡盖住更多 —— 观感仍是「主卡居中 + 两侧半露」，不会 overflow（`PageView` 另有一层裁剪）。
/// 竖版「大」整块 = 1050，在 1280 窗下正好放得下。
@immutable
class DsCarouselGeometry {
  const DsCarouselGeometry({
    required this.main,
    required this.neighbour,
    required this.blockHeight,
    required this.k,
  });

  /// 主卡尺寸（默认横版·中 = 460×300，与现状完全一致）。
  final Size main;

  /// 两侧邻卡尺寸（在主卡后面、向内压边 `28k`）。
  final Size neighbour;

  /// 整块高度（主卡 + 图文间距 + 文字块 + 底部留白）。
  final double blockHeight;

  /// 档位系数（0.85 / 1.2 / 1.5）。
  final double k;

  /// 邻卡向主卡内侧压边的量（规范 §3.3：`28 * k`）—— cover-flow 观感靠它。
  double get overlap => 28 * k;

  static const Size _landscapeMain = Size(460, 300);
  static const Size _landscapeNeighbour = Size(220, 236);
  static const Size _portraitMain = Size(312, 443);
  static const Size _portraitNeighbour = Size(222, 315);

  static DsCarouselGeometry forShape(DsCarouselShape shape, DsCarouselSize size) {
    final bool portrait = shape == DsCarouselShape.portrait;
    final double k = size.k;
    Size scale(Size v) =>
        Size((v.width * k).roundToDouble(), (v.height * k).roundToDouble());
    final Size main = scale(portrait ? _portraitMain : _landscapeMain);
    return DsCarouselGeometry(
      main: main,
      neighbour: scale(portrait ? _portraitNeighbour : _landscapeNeighbour),
      blockHeight: (main.height + 12 * k + 54).roundToDouble(),
      k: k,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DsCarouselGeometry &&
      other.main == main &&
      other.neighbour == neighbour &&
      other.blockHeight == blockHeight &&
      other.k == k;

  @override
  int get hashCode => Object.hash(main, neighbour, blockHeight, k);
}

// ── token ────────────────────────────────────────────────────────────────────

/// 阴影色（规范 §5 没有给阴影立色表；扁平后阴影只服务 §7 的悬浮层，
/// 所以浅色系 / 黑色系各沿用一组旧拟态的取值即可）。
const Color _shadowLightOnWhite = Color(0xD9FFFFFF); // white 85%
const Color _shadowDarkOnWhite = Color(0x8CA6AEC0); // #A6AEC0 55%
const Color _shadowLightOnBlack = Color(0x14FFFFFF); // white 8%
const Color _shadowDarkOnBlack = Color(0x73000000); // black 45%

@immutable
class DsTokens extends ThemeExtension<DsTokens> {
  // ── primitive：面与描边 ────────────────────────────────────────────────────
  /// 窗口底、页面底色。
  final Color base;

  /// 凸起面（卡片、按钮、控制栏）。
  final Color raised;

  /// 凹陷面（输入框、开关槽、进度槽）。
  final Color sunken;

  /// 1px 描边色（卡片 / 凹槽 / 分隔线都用它，规范 §3）。
  final Color line;

  /// 悬浮层的亮影色（只被 [shadows] 的 `high` 档用到）。
  final Color shadowLight;

  /// 悬浮层的暗影色（只被 [shadows] 的 `high` 档用到）。
  final Color shadowDark;

  // ── semantic：文字与语义色 ────────────────────────────────────────────────
  final Color text;
  final Color text2;
  final Color text3;
  final Color accent;

  /// 强调色实底上的文字色（规范 §5.2 色表最后一列）。
  final Color onAccent;

  final Color success;
  final Color warning;
  final Color danger;

  // ── component：几何 ───────────────────────────────────────────────────────
  final double radiusCard;
  final double radiusControl;
  final double radiusPill;

  /// 小徽标圆角（规范 §3 新增）。
  final double radiusBadge;

  final double spacing;
  final double controlHeight;
  final double barHeight;

  /// 悬浮层（对话框 / 菜单 / Tooltip / 下拉浮层）的 Material elevation（规范 §7）。
  final double overlayElevation;

  /// 表面主色（= 凸起面）。
  Color get surface => raised;

  /// 次表面（= 凹陷面）。
  Color get surface2 => sunken;

  Color get textDim => text2;
  Color get accent2 => accent;
  Color get surfaceAlt => raised;

  /// 旧名 `bg` → 新名 [base]（页面底色）。
  Color get bg => base;

  /// 旧名 `radius` → 新名 [radiusCard]（卡片圆角）。
  double get radius => radiusCard;

  /// 旧名 `radiusSmall` → 新名 [radiusControl]（控件圆角）。
  double get radiusSmall => radiusControl;

  /// 旧名 `tableHeaderSize` / `bodySize` / `labelSize` → 5 档字号阶梯。
  double get tableHeaderSize => DsTypeScale.caption;
  double get labelSize => DsTypeScale.caption;
  double get bodySize => DsTypeScale.body;

  final bool isDark;

  const DsTokens({
    required this.base,
    required this.raised,
    required this.sunken,
    required this.line,
    required this.shadowLight,
    required this.shadowDark,
    required this.text,
    required this.text2,
    required this.text3,
    required this.accent,
    required this.onAccent,
    required this.success,
    required this.warning,
    required this.danger,
    this.isDark = false,
    // 扁平几何（规范 §3）：卡片 16 → 12、控件 12 → 8、胶囊 999 不变、徽标 6 新增；
    // 控件高 44 → 40、工具条 46 → 44；状态栏整条删除（字段留给 Task 9）。
    this.radiusCard = 12,
    this.radiusControl = 8,
    this.radiusPill = 999,
    this.radiusBadge = 6,
    this.spacing = 8,
    this.controlHeight = 40,
    this.barHeight = 44,
    this.overlayElevation = 10,
  });

  // ── 八套外观（色表逐字抄自规范 §5.2 / §5.4）────────────────────────────────

  /// **白橙（新装默认）** —— `w_orange`。
  static const DsTokens whiteOrange = DsTokens(
    base: Color(0xFFFBF8F5),
    raised: Color(0xFFFFFFFF),
    sunken: Color(0xFFF6F0EA),
    line: Color(0xFFEDE3DA),
    shadowLight: _shadowLightOnWhite,
    shadowDark: _shadowDarkOnWhite,
    text: Color(0xFF1C1917),
    text2: Color(0xFF57534E),
    text3: Color(0xFF736C63),
    accent: Color(0xFFC2410C),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF1F7A52),
    warning: Color(0xFF8F5E0E),
    danger: Color(0xFFB03A34),
  );

  /// **紫白** —— `w_purple`。
  static const DsTokens whitePurple = DsTokens(
    base: Color(0xFFF8F7FC),
    raised: Color(0xFFFFFFFF),
    sunken: Color(0xFFF2F0FA),
    line: Color(0xFFE6E3F2),
    shadowLight: _shadowLightOnWhite,
    shadowDark: _shadowDarkOnWhite,
    text: Color(0xFF1A1826),
    text2: Color(0xFF4B4761),
    text3: Color(0xFF6E6A84),
    accent: Color(0xFF6D28D9),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF1F7A52),
    warning: Color(0xFF8F5E0E),
    danger: Color(0xFFB03A34),
  );

  /// **薄荷绿白** —— `w_mint`（强调色是绿 → success 偏青，避免「选中」与「成功」同色）。
  static const DsTokens whiteMint = DsTokens(
    base: Color(0xFFF5FAF8),
    raised: Color(0xFFFFFFFF),
    sunken: Color(0xFFEDF6F2),
    line: Color(0xFFDCEDE5),
    shadowLight: _shadowLightOnWhite,
    shadowDark: _shadowDarkOnWhite,
    text: Color(0xFF12201B),
    text2: Color(0xFF41544C),
    text3: Color(0xFF60736B),
    accent: Color(0xFF047857),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF0E7490),
    warning: Color(0xFF8F5E0E),
    danger: Color(0xFFB03A34),
  );

  /// **白黑** —— `w_ink`（旧 `'light'` / `'A'` / `'C'` / `'B'` 的迁移落点）。
  static const DsTokens whiteInk = DsTokens(
    base: Color(0xFFF7F7F8),
    raised: Color(0xFFFFFFFF),
    sunken: Color(0xFFF0F0F2),
    line: Color(0xFFE2E2E5),
    shadowLight: _shadowLightOnWhite,
    shadowDark: _shadowDarkOnWhite,
    text: Color(0xFF111113),
    text2: Color(0xFF4A4A4F),
    text3: Color(0xFF6C6C71),
    accent: Color(0xFF17171A),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF1F7A52),
    warning: Color(0xFF8F5E0E),
    danger: Color(0xFFB03A34),
  );

  /// **荧光绿黑** —— `b_neon`。
  static const DsTokens blackNeon = DsTokens(
    base: Color(0xFF080A09),
    raised: Color(0xFF101413),
    sunken: Color(0xFF161C1A),
    line: Color(0xFF222A27),
    shadowLight: _shadowLightOnBlack,
    shadowDark: _shadowDarkOnBlack,
    text: Color(0xFFEDF5F1),
    text2: Color(0xFFA3B3AC),
    text3: Color(0xFF768881),
    accent: Color(0xFF3DFF9E),
    onAccent: Color(0xFF04120B),
    success: Color(0xFF22D3EE),
    warning: Color(0xFFFBBF24),
    danger: Color(0xFFFF6B6B),
    isDark: true,
  );

  /// **黑电光蓝** —— `b_electric`。
  static const DsTokens blackElectric = DsTokens(
    base: Color(0xFF07090C),
    raised: Color(0xFF0F1319),
    sunken: Color(0xFF161B23),
    line: Color(0xFF202834),
    shadowLight: _shadowLightOnBlack,
    shadowDark: _shadowDarkOnBlack,
    text: Color(0xFFEEF3FA),
    text2: Color(0xFFA2AEBF),
    text3: Color(0xFF798593),
    accent: Color(0xFF2F9BFF),
    onAccent: Color(0xFF04121F),
    success: Color(0xFF54C08A),
    warning: Color(0xFFE0A94A),
    danger: Color(0xFFE8807A),
    isDark: true,
  );

  /// **黑白** —— `b_mono`（旧 `'dark'` 的迁移落点）。
  static const DsTokens blackMono = DsTokens(
    base: Color(0xFF0A0A0B),
    raised: Color(0xFF131315),
    sunken: Color(0xFF1A1A1D),
    line: Color(0xFF26262A),
    shadowLight: _shadowLightOnBlack,
    shadowDark: _shadowDarkOnBlack,
    text: Color(0xFFF2F2F4),
    text2: Color(0xFFA9A9B0),
    text3: Color(0xFF83838A),
    accent: Color(0xFFFFFFFF),
    onAccent: Color(0xFF0A0A0B),
    success: Color(0xFF54C08A),
    warning: Color(0xFFE0A94A),
    danger: Color(0xFFE8807A),
    isDark: true,
  );

  /// **黑红** —— `b_red`（强调色是红 → danger 偏橙，避免「选中」与「出错」同色）。
  static const DsTokens blackRed = DsTokens(
    base: Color(0xFF0B0809),
    raised: Color(0xFF141011),
    sunken: Color(0xFF1C1618),
    line: Color(0xFF2A2124),
    shadowLight: _shadowLightOnBlack,
    shadowDark: _shadowDarkOnBlack,
    text: Color(0xFFF7EEEF),
    text2: Color(0xFFB6A3A6),
    text3: Color(0xFF927C7E),
    accent: Color(0xFFFF5A5F),
    onAccent: Color(0xFF0A0A0B),
    success: Color(0xFF54C08A),
    warning: Color(0xFFFFD166),
    danger: Color(0xFFFF8A3D),
    isDark: true,
  );

  // 短别名（= [DsAppearance] 的成员名）：规范 §12.1 的测试按枚举成员名读色表
  // （`DsTokens.bMono` / `DsTokens.bRed`），而任务 Interfaces 只列了长名。
  // 两套指向同一批 const，八套给全（只补两个会看起来像漏写）。
  static const DsTokens wOrange = whiteOrange;
  static const DsTokens wPurple = whitePurple;
  static const DsTokens wMint = whiteMint;
  static const DsTokens wInk = whiteInk;
  static const DsTokens bNeon = blackNeon;
  static const DsTokens bElectric = blackElectric;
  static const DsTokens bMono = blackMono;
  static const DsTokens bRed = blackRed;



  /// 外观 → token（新代码入口：`DsTokens.of(DsAppearance.wOrange)`）。
  ///
  /// 取一套外观的 token。
  ///
  /// 第二十九轮收口：`DsBrightness` 已删除，签名恢复编译期约束（曾经是 `of(Object)` 的
  /// 运行时分派，见账本 R16 的过渡记录）。
  static DsTokens of(DsAppearance a) => a.tokens;

  // ── 派生色 ────────────────────────────────────────────────────────────────

  /// 选中底：强调色 12%（规范 §2 / §5.1：强调色只以小面积出现）。
  Color get accentSoft => accent.withValues(alpha: 0.12);

  Color get successSoft => success.withValues(alpha: 0.12);
  Color get warningSoft => warning.withValues(alpha: 0.12);
  Color get dangerSoft => danger.withValues(alpha: 0.12);

  // ── 标识色相（第五十二轮，见 [DsHue]）──────────────────────────────────────

  /// 色相的文字 / 图标色（浅色外观是深一档的 `ink`，深色外观是亮色）。
  Color hueInk(DsHue hue) => (isDark ? _hueDark : _hueLight)[hue]!.ink;

  /// 色相的装饰填充色：点 / 细条 / 进度条 / 渐变。**不要**拿来写字。
  Color hueFill(DsHue hue) => (isDark ? _hueDark : _hueLight)[hue]!.fill;

  /// 色相淡底：`raised` 上叠 18%（深色 20%）色相填充。选中行 / 徽标底 / 图标底。
  ///
  /// 18% 是第五十二轮实测的上限：12 个色相的 `ink` 在 18% 淡底上仍全部 ≥4.5:1
  /// （见 `build/round52/ink_candidates.py`），再深就得给每个色相单独调 ink。
  Color hueSoft(DsHue hue) => hueSoftOn(hue, raised);

  /// 在任意面上叠色相淡底（页面底色上、`sunken` 上等）。
  Color hueSoftOn(DsHue hue, Color face) => Color.alphaBlend(
        hueFill(hue).withValues(alpha: isDark ? 0.20 : 0.18),
        face,
      );

  /// 色相**实底**上的前景色：只在「实色块里放图标」时用（实底 + 小图标）。
  ///
  /// 实底填色是 vivid 档，深浅两档前景各有一半色相达不到 4.5:1 —— 所以这里按
  /// 对比度挑高的那个（图标只需 3:1，见 WCAG 1.4.11）。**不要**拿它写正文。
  Color hueOnFill(DsHue hue) {
    final Color fill = hueFill(hue);
    final Color light = isDark ? base : Colors.white;
    final Color dark = isDark ? base : text;
    return dsContrastRatio(light, fill) >= dsContrastRatio(dark, fill) ? light : dark;
  }

  /// 色相 1px 描边（卡片悬停 / 选中的彩色边，规范只允许 1px）。[alpha] 由调用方细化。
  Color hueLine(DsHue hue, {double alpha = 1}) =>
      hueFill(hue).withValues(alpha: alpha * (isDark ? 0.55 : 0.45));

  /// 页面顶部「洗色」：色相 9%（深色 14%）淡底向下渐变回 `base`。
  ///
  /// 外壳把它铺在**内容区背后**，于是 8 个页面（含播放页以外的全部 tab）都带上
  /// 当前目的地的颜色身份 —— 这是「整个项目太素」最省改动的一层。
  LinearGradient hueWash(DsHue hue) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          Color.alphaBlend(
            hueFill(hue).withValues(alpha: isDark ? 0.14 : 0.09),
            base,
          ),
          base,
        ],
      );

  /// ⚠️ **过渡期遗留**（Task 9 删除）：过去它是「柔光内边」的高光色，
  /// 扁平后描边统一用 [line]，这个别名只是为了旧调用点不炸。
  Color get hairline => line;

  /// 极淡分隔（表格行、区块之间）。
  Color get divider => line.withValues(alpha: isDark ? 0.7 : 0.9);

  /// 显式的「没有阴影」取值（全透明）。
  ///
  /// 「简洁模式」下要把阴影色传给播放器，用这个常量而不是在业务代码里写
  /// `Color(0x00000000)` —— 后者会被 `test/neo_guard_test.dart` 的
  /// 「禁止颜色字面量」守卫抓住（上一轮就是它抓到的）。
  static const Color noShadow = Color(0x00000000);

  // ── 阴影（只此一处定义，业务代码用档位）────────────────────────────────────

  /// 返回给定档位的阴影列表（规范 §7）。
  ///
  /// **扁平化后只有 [NeoShadowLevel.high] 非空**（悬浮层是唯一的阴影例外）；
  /// `none` / `soft` / `raised` 一律返回空列表。
  ///
  /// [listSafe] 为真时把 `high` 降到「模糊 ≤ 2px」的列表安全档（决策 A31 性能红线）。
  /// 阴影只有悬浮层用（规范 §7：卡片/按钮/导航/表格/网格一律零阴影）。
  List<BoxShadow> shadows(NeoShadowLevel level, {bool listSafe = false}) {
    if (level != NeoShadowLevel.high) return const <BoxShadow>[];
    double d = 6; // 偏移
    double b = 14; // 模糊
    if (isDark) {
      d += 1;
      b += 2;
    }
    if (listSafe && b > 2) {
      d = 1;
      b = 2;
    }
    return <BoxShadow>[
      BoxShadow(
        color: shadowLight,
        offset: Offset(-d, -d),
        blurRadius: b,
        spreadRadius: 0,
      ),
      BoxShadow(
        color: shadowDark,
        offset: Offset(d, d),
        blurRadius: b,
        spreadRadius: 0,
      ),
    ];
  }

  /// 卡片装饰（规范 §3）：`raised` 面 + `line` 1px 描边，**无阴影**。
  ///
  /// 圆角默认 [radiusCard]；需要别的圆角（徽标 / 控件）由调用方给 [radius]。
  BoxDecoration cardDecoration({double? radius, Color? color}) => BoxDecoration(
        color: color ?? raised,
        borderRadius: BorderRadius.circular(radius ?? radiusCard),
        border: Border.all(color: line, width: 1),
      );

  /// 凹槽装饰（规范 §3 / §6）：`sunken` 面 + `line` 1px 描边，**无渐变、无阴影**。
  ///
  /// 取代旧的 `InsetSurface`（双线性渐变模拟内阴影，第二十九轮已删除），圆角默认 [radiusControl]。
  BoxDecoration inset({double? radius, Color? color}) => BoxDecoration(
        color: color ?? sunken,
        borderRadius: BorderRadius.circular(radius ?? radiusControl),
        border: Border.all(color: line, width: 1),
      );


  /// ⚠️ **过渡期遗留**（Task 9 删除）：旧的凹陷装饰，新版用 [inset]（多了 `line` 描边）。
  BoxDecoration sunkenDecoration({double? radius, Color? color}) =>
      BoxDecoration(
        color: color ?? sunken,
        borderRadius: BorderRadius.circular(radius ?? radiusControl),
      );

  /// 数字/时间统一用 tabular figures。
  static const List<FontFeature> tabular = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  @override
  DsTokens copyWith({
    Color? base,
    Color? raised,
    Color? sunken,
    Color? line,
    Color? shadowLight,
    Color? shadowDark,
    Color? text,
    Color? text2,
    Color? text3,
    Color? accent,
    Color? onAccent,
    Color? success,
    Color? warning,
    Color? danger,
    bool? isDark,
    double? radiusCard,
    double? radiusControl,
    double? radiusPill,
    double? radiusBadge,
    double? spacing,
    double? controlHeight,
    double? barHeight,
    double? overlayElevation,
  }) =>
      DsTokens(
        base: base ?? this.base,
        raised: raised ?? this.raised,
        sunken: sunken ?? this.sunken,
        line: line ?? this.line,
        shadowLight: shadowLight ?? this.shadowLight,
        shadowDark: shadowDark ?? this.shadowDark,
        text: text ?? this.text,
        text2: text2 ?? this.text2,
        text3: text3 ?? this.text3,
        accent: accent ?? this.accent,
        onAccent: onAccent ?? this.onAccent,
        success: success ?? this.success,
        warning: warning ?? this.warning,
        danger: danger ?? this.danger,
        isDark: isDark ?? this.isDark,
        radiusCard: radiusCard ?? this.radiusCard,
        radiusControl: radiusControl ?? this.radiusControl,
        radiusPill: radiusPill ?? this.radiusPill,
        radiusBadge: radiusBadge ?? this.radiusBadge,
        spacing: spacing ?? this.spacing,
        controlHeight: controlHeight ?? this.controlHeight,
        barHeight: barHeight ?? this.barHeight,
        overlayElevation: overlayElevation ?? this.overlayElevation,
      );

  @override
  DsTokens lerp(covariant ThemeExtension<DsTokens>? other, double t) {
    if (other is! DsTokens) return this;
    double l(double x, double y) => x + (y - x) * t;
    return DsTokens(
      base: Color.lerp(base, other.base, t)!,
      raised: Color.lerp(raised, other.raised, t)!,
      sunken: Color.lerp(sunken, other.sunken, t)!,
      line: Color.lerp(line, other.line, t)!,
      shadowLight: Color.lerp(shadowLight, other.shadowLight, t)!,
      shadowDark: Color.lerp(shadowDark, other.shadowDark, t)!,
      text: Color.lerp(text, other.text, t)!,
      text2: Color.lerp(text2, other.text2, t)!,
      text3: Color.lerp(text3, other.text3, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      isDark: t < 0.5 ? isDark : other.isDark,
      radiusCard: l(radiusCard, other.radiusCard),
      radiusControl: l(radiusControl, other.radiusControl),
      radiusPill: l(radiusPill, other.radiusPill),
      radiusBadge: l(radiusBadge, other.radiusBadge),
      spacing: l(spacing, other.spacing),
      controlHeight: l(controlHeight, other.controlHeight),
      barHeight: l(barHeight, other.barHeight),
      overlayElevation: l(overlayElevation, other.overlayElevation),
    );
  }
}

extension DsContextX on BuildContext {
  /// 取当前 token（未挂载时回落到 [DsTokens.whiteInk]，避免空崩）。
  DsTokens get ds => Theme.of(this).extension<DsTokens>() ?? DsTokens.whiteInk;

  TextTheme get texts => Theme.of(this).textTheme;
}

/// 系统字体（**不打包字体文件**，决策 A15）。
const String dsFontFamily = 'Microsoft YaHei UI';
const List<String> dsFontFallback = <String>[
  'Segoe UI',
  'Microsoft YaHei',
  'Noto Sans CJK SC',
];

// ── 文本样式（5 档，行高固定）───────────────────────────────────────────────

/// 表头样式：caption 档 + 字距 0.08em。
TextStyle dsTableHeaderStyle(DsTokens t) => TextStyle(
      color: t.text3,
      fontSize: DsTypeScale.caption,
      letterSpacing: DsTypeScale.caption * 0.08,
      fontWeight: FontWeight.w600,
      height: 1.3,
    );

/// 标签样式：caption 档。
TextStyle dsLabelStyle(DsTokens t, {Color? color}) => TextStyle(
      color: color ?? t.text2,
      fontSize: DsTypeScale.caption,
      height: 1.3,
      fontFeatures: DsTokens.tabular,
    );

/// 数字样式：tabular figures。
TextStyle dsNumStyle(
  DsTokens t, {
  Color? color,
  double? size,
  FontWeight? weight,
}) =>
    TextStyle(
      color: color ?? t.text,
      fontSize: size ?? DsTypeScale.body,
      fontWeight: weight,
      height: 1.45,
      fontFeatures: DsTokens.tabular,
    );

// ── 无障碍（决策 A45 / 规范 §5.3：文本对比 ≥ 4.5:1，写成纯函数测试）──────────

/// WCAG 相对亮度。
double dsRelativeLuminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// WCAG 对比度（1.0–21.0）。测试用：断言 ≥ 4.5。
double dsContrastRatio(Color fg, Color bg) {
  final double a = dsRelativeLuminance(fg);
  final double b = dsRelativeLuminance(bg);
  final double hi = math.max(a, b);
  final double lo = math.min(a, b);
  return (hi + 0.05) / (lo + 0.05);
}

/// 全部需要达标的「文字 × 面」组合（规范 §5.3 / §12.1）。
///
/// 8 套外观 × 3 个承载面（`base` / `raised` / `sunken`）× {text, text2, text3, accent}
/// + 每套的 `onAccent` on `accent` + 语义色（success / warning / danger）on `raised`
/// = **128** 条；第五十二轮再加 **8×12×2 = 192 条标识色相**（每个色相的 `ink` 在
/// `raised` 与自己的淡底上都要 ≥4.5:1）。名字形如 `'w_orange/text3-on-sunken'`、
/// `'w_orange/hue-violet-on-soft'`。
List<({String name, Color fg, Color bg})> dsContrastPairs() {
  final List<({String name, Color fg, Color bg})> out =
      <({String name, Color fg, Color bg})>[];
  for (final DsAppearance a in DsAppearance.values) {
    final DsTokens t = a.tokens;
    for (final (String faceName, Color face) in <(String, Color)>[
      ('base', t.base),
      ('raised', t.raised),
      ('sunken', t.sunken),
    ]) {
      for (final (String fgName, Color fg) in <(String, Color)>[
        ('text', t.text),
        ('text2', t.text2),
        ('text3', t.text3),
        ('accent', t.accent),
      ]) {
        out.add((name: '${a.code}/$fgName-on-$faceName', fg: fg, bg: face));
      }
    }
    // 强调色实底上的文字（主按钮 / 选中徽标）。
    out.add((name: '${a.code}/onAccent-on-accent', fg: t.onAccent, bg: t.accent));
    // 语义色也要能在凸起面上读清（做种数/大小/状态标签会用到）。
    for (final (String fgName, Color fg) in <(String, Color)>[
      ('success', t.success),
      ('warning', t.warning),
      ('danger', t.danger),
    ]) {
      out.add((name: '${a.code}/$fgName-on-raised', fg: fg, bg: t.raised));
    }
    // 标识色相（第五十二轮）：文字/图标色 × 凸起面 + 自己的淡底。
    for (final DsHue hue in DsHue.values) {
      out.add((
        name: '${a.code}/hue-${hue.name}-on-raised',
        fg: t.hueInk(hue),
        bg: t.raised,
      ));
      out.add((
        name: '${a.code}/hue-${hue.name}-on-soft',
        fg: t.hueInk(hue),
        bg: t.hueSoft(hue),
      ));
    }
  }
  return out;
}
