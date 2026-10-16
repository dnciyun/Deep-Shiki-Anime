/// 首页轮播（决策 F14 / F31，规范 §9.2–§9.3）。
///
/// 形态 A：**居中主卡 + 两侧半露邻卡**（邻卡在主卡后面、向内压边 `28k`，透明度 0.72/0.45）。
/// 几何**全部**来自 [DsCarouselGeometry] —— 组件里不出现 460/300/220/236/28 这类数字。
///
/// 高度账（与 [DsCarouselGeometry.blockHeight] 严格对齐）：
/// `主卡 main.height` + `12k`（图文间距）+ `40`（文字块）+ `14`（底部留白，圆点在这里）
/// = `main.height + 12k + 54`。
///
/// 三条硬约束（规范 §9.2/§8.4）：
/// 1. 自动播放是**唯一**的常驻循环，且必须能关（主页从 `carouselAutoPlayProvider` 取，
///    测试里 override 成 false）；
/// 2. 四个暂停条件：鼠标悬停、窗口失焦、`TickerMode` 关闭、用户正在拖拽；
/// 3. 切换动画时长走 `DsMotion.carousel`（320ms）；系统「减少动画」时直接跳页。
///
/// ⚠️ 2026-10-15 第三十二轮（用户：「轮播的小圆点改到中间」「点击轮播后面的是切换到后面的
/// 而不是直接搜索」，追问「为什么切换是一整个切过去」后选定「点谁谁长大」）：
/// * **圆点居中**：原来贴右（`MainAxisAlignment.end`），现在对着主卡中点；
/// * **邻卡 = 切页热区**：点半露的邻卡切到那一张，不再执行它自己那套点击（主页 = 拿番名去搜索），
///   实现必须用 `AbsorbPointer` 吃掉内层指针（只在外层套 `GestureDetector` 会输掉手势竞技场）；
/// * **切换不再用 `PageView`**（F31）：原来**一页 = 整个三卡块**，换页 = 整条胶片平移**一个视口宽**，
///   落进中间的是"下一页的主卡"（从屏幕右外侧扫进来），同一个封面在 320ms 里出现两份
///   （逐帧实测：中途树上有 6 张卡、位移量每帧完全相同、总量 1564px）。
///   现在改成**自绘四格窗口**：每张卡按带符号格距 `d = 格号 − 当前位置` 取 [DsCarouselCardSpec]
///   （尺寸 / 水平位移 / 透明度一起插值）—— 被点的那张**原地长大**滑到中间、旧主卡缩小退成邻卡、
///   远端那张继续向外淡出。任何时刻最多 4 张卡，且**没有同一部出现两份**；
///   拖拽随之改成自己算（原来跟手滑动是 `PageView` 白送的），跟手比例 1:1：
///   手指移动一格的距离（= 邻卡位到主卡位）就翻一张。
///
/// ⚠️ 2026-10-15 第三十三轮（用户：「轮播切换时会闪烁」）—— 两处**每帧重建**都修掉了：
/// * **卡片按格号打 key**（`ValueKey<int>(slot)`）。绘制顺序是「|格距| 从远到近」，而
///   过半那一刻中间两张**互换位置**；Stack 没有 key 时按下标复用元素 ⇒ 换位置 = 重建这几张卡。
/// * **主卡与邻卡结构完全同构**，差别只有两个参数（`onTap` ↔ `absorbing`）。原来主卡少套一层
///   `MouseRegion`/`GestureDetector`/`AbsorbPointer`，于是"主卡换人"也等于重建。
///   邻卡不再带 `carousel-neighbour-left/right` 侧别 key —— 侧别随卡片轮换而变，
///   那本身就是一次重建；测试改成按位置点（`carouselSlotOffset`）。
///
/// 重建的代价是肉眼可见的一帧：`DsCover` 是新 state（`_file == null`）⇒ 先闪一帧「无封面」。
/// 逐帧探针见 `test/carousel_flicker_probe.dart`（改前一次切换整批重建 4 遍）。
///
/// 2026-10-15 第三十四轮（用户：「优化轮播，他都跑到侧边栏了才消失掉」）—— **两侧羽化**：
/// 卡片滑出时是**线性淡出**到 `|格距| = 2` 才归零，而两格 = `2 × 一格`（中档 748.8、大档 936
/// 像素），早就越过轮播块自己的宽度了；块里又只有一层「谁按格号排」的裸 `Stack`
/// （`clipBehavior: Clip.none`），真正把它切掉的是**外层滚动视口的 `Clip.hardEdge`** —— 而
/// 那个视口的边界**就是侧边栏右边那条线**。于是用户看到的就是"卡片一路滑到侧边栏，
/// 到那条线上被一刀切掉"。
///
/// 这一轮两道（都可测，见 `ds_carousel_test` 的「两侧羽化」三条）：
/// 1. [ClipRect]（[dsCarouselClipKey]）把卡片区**钉在轮播块自己的矩形里** —— 无论后面
///    放的是什么滚动视口，都不可能再画到侧边栏上；
/// 2. 块内两侧各留一条**羽化带**（[carouselEdgeMask]），让滑出去的卡片在**到达块边缘之前**
///    就淡到 0：不再是"到线上一刀切"，而是提前化掉。羽化带**从主卡外缘才开始**
///    （`bands.inner ≥ main.width / 2`），所以主卡在任何窗口宽度下都不会被啃到；
///    块窄到放不下主卡时干脆不羽化（[carouselEdgeMask] 返回 null），交给外层照旧处理。
///
/// ⚠️ 2026-10-15 第三十五轮补（用户：「轮播整个变透明了点」）—— 上一版**码错了渐变**：
/// 四条色（透明/白/白/透明）配的是 `stops: [0, s0, s1, 1]`，也就是把 `0 → s0` 当成第一段
/// 斜坡 —— 而 `s0` 是**主卡右缘附近**（1060 块 / 大档下 = 880 像素处）。于是整块的一大半
/// 都落在"透明 → 不透明"的斜坡上：主卡左缘的 alpha 只有 **0.21**，一路渐变到右侧才满。
/// 这就是用户看到的"整个变透明了点"（还带一层左暗右亮的渐变）。
///
/// 正确的四段是「外侧全透明 → 斜坡 → **主卡所在区段恒为 1** → 斜坡 → 外侧全透明」，
/// 所以现在 [carouselEdgeMask] 的四段 stop 与四条色**一一对应**，且由 [carouselEdgeBands]
/// 一处算出、[carouselEdgeAlpha] 用同一份数字做断言（蒙版与验收标准不会各说各话）。
///
/// 同一轮顺手补了第三个约束：斜坡**最多吃掉"主卡外那一条"的一半**（[kCarouselEdgeSolidShare]）。
/// 探针（`test/carousel_edge_probe.dart`）量出来：大档挤进 1060 的块时主卡外只剩 185px，
/// 而斜坡 152px —— 整块邻卡都在斜坡上（最内侧 alpha 也只有 0.19），"半露邻卡"等于没了。
/// 现在邻卡最靠内的一半保持实心，只有外侧那一段化掉。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/motion.dart';
import '../../theme/tokens.dart';

/// 圆点直径（逻辑像素）。
const double kCarouselDotSize = 6;

/// 卡片区的裁剪盒（测试用它确认"卡片再也画不出轮播块"）。
const Key dsCarouselClipKey = Key('carousel-clip');

/// 两侧羽化带那一层（块太窄时不挂，见 [carouselEdgeMask]）。
const Key dsCarouselEdgeMaskKey = Key('carousel-edge-mask');

/// 羽化带的宽度 = `主卡宽 × 这个系数`。
///
/// 跟着主卡走而不是写死像素：小/中/大三档的主卡是 391/552/690，羽化带随之 86/121/152 —— 
/// 视觉上"化掉的那一段"始终占主卡宽的五分之一左右，档位之间不会一个很硬一个很软。
const double kCarouselEdgeFeather = 0.22;

/// 卡片必须在这条线**之内**就完全看不见：块边缘再往里收这么多像素。
///
/// 为什么不是 0（= 正好化到边缘）：留一段"已经完全透明"的空档，边缘才不会看着像被裁掉的
/// 一半 —— 用户要的正是"别跑到边上才消失"。
const double kCarouselEdgeMargin = 28;

/// 斜坡**最多**吃掉"主卡外那一条"的多大比例 —— 剩下的部分必须留给邻卡当**实心**段。
///
/// 没有这条夹子的话，窄块会出事：大档（主卡 690）挤进 1060 的块里时，主卡外只剩 185px，
/// 而斜坡本身有 152px 宽 —— 整个邻卡都落在斜坡上（最靠内那一点也只有 0.19），看起来就是
/// "邻卡没了"，与"主卡居中 + 两侧半露邻卡"的形态（规范 §9.2）不符。
const double kCarouselEdgeSolidShare = 0.5;

/// 两侧羽化带的边界（**以块中线为原点**的距离，像素）：`inner` 处开始往外淡，
/// `outer` 处已经全透明。`null`（[carouselEdgeBands] 返回空）= 这个块不羽化。
typedef DsCarouselEdgeBands = ({double inner, double outer});

/// 羽化带的宽度/位置；**块窄到放不下主卡时返回 null**（= 不羽化）。
///
/// 纯函数（`ds_carousel_test` 直接按数字钉），三个约束都是**以块中线为原点的距离**：
/// * `inner ≥ main.width / 2` —— **羽化带只盖住主卡以外的区域**。主卡在窄窗口下
///   本来就会顶到块边缘，如果羽化从块边缘无条件往内算，主卡的边会被一起啃掉
///   （那就从"邻卡被切"变成"主卡发虚"，更糟）；
/// * `outer = 块半宽 − [kCarouselEdgeMargin]` —— 淡出**在块边缘内侧就结束**；
/// * `inner ≥ 主卡半宽 + 主卡外那一条 × [kCarouselEdgeSolidShare]` —— 邻卡**最靠内的一半
///   保持实心**（否则窄块里整块邻卡都在斜坡上，"半露邻卡"就没了）。
///
/// 三个约束互相矛盾时（块太窄）返回 null —— 行为与第三十三轮完全一致，
/// 不拿主卡去换邻卡。
DsCarouselEdgeBands? carouselEdgeBands(double blockWidth, DsCarouselGeometry g) {
  if (!blockWidth.isFinite || blockWidth <= 0) return null;
  final double half = blockWidth / 2;
  final double mainHalf = g.main.width / 2;
  if (half <= mainHalf + kCarouselEdgeMargin) return null;
  final double outer = half - kCarouselEdgeMargin;
  final double inner = math.max(
    // ① 只盖主卡以外的区域 ② 按主卡宽算的斜坡宽度 ③ 邻卡留一半实心
    math.max(mainHalf, outer - g.main.width * kCarouselEdgeFeather),
    mainHalf + (half - mainHalf) * kCarouselEdgeSolidShare,
  );
  if (inner >= outer) return null;
  return (inner: inner, outer: outer);
}

/// 两侧羽化用的横向渐变（[carouselEdgeBands] 为 null 时就是 null）。
///
/// ⚠️ 四段 stop 与四条色是**一一对应**的（第三十五轮修的就是这里）：
/// `[透明, 白, 白, 透明]` ↔ `[边缘, 起点, 终点, 边缘]`，也就是
/// * 最外侧 [kCarouselEdgeMargin] px：alpha 0（`TileMode.clamp`，还没到第一个 stop 的
///   区域保持第一条色 = 全透明）；
/// * 斜坡：从透明淡到不透明（宽度 = 主卡宽 × [kCarouselEdgeFeather]）；
/// * **主卡所在的中间区段：alpha 1**（原来错在把这一段算成了斜坡）；
/// * 右侧对称。
LinearGradient? carouselEdgeMask(double blockWidth, DsCarouselGeometry g) {
  final DsCarouselEdgeBands? bands = carouselEdgeBands(blockWidth, g);
  if (bands == null) return null;
  final double half = blockWidth / 2;
  return LinearGradient(
    // `BlendMode.dstIn` 只看 alpha：两端全透明、中间不透明即可（颜色无所谓，取白的）。
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: const <Color>[
      Colors.transparent,
      Colors.white,
      Colors.white,
      Colors.transparent,
    ],
    stops: <double>[
      ((half - bands.outer) / blockWidth).clamp(0.0, 1.0),
      ((half - bands.inner) / blockWidth).clamp(0.0, 1.0),
      ((half + bands.inner) / blockWidth).clamp(0.0, 1.0),
      ((half + bands.outer) / blockWidth).clamp(0.0, 1.0),
    ],
  );
}

/// 羽化蒙版在「距块中线 `dx` 像素」处的 alpha（0…1）——纯函数，测试拿它钉"看到的是什么"。
///
/// 不羽化（块太窄）时恒为 1；`|dx| ≤ bands.inner`（主卡所在区段）恒为 1；`|dx| ≥ bands.outer`
/// （最外侧那 [kCarouselEdgeMargin] px）恒为 0。**左右对称**。
double carouselEdgeAlpha(double blockWidth, DsCarouselGeometry g, double dx) {
  final DsCarouselEdgeBands? bands = carouselEdgeBands(blockWidth, g);
  if (bands == null) return 1;
  final double d = dx.abs();
  if (d <= bands.inner) return 1;
  if (d >= bands.outer) return 0;
  return (bands.outer - d) / (bands.outer - bands.inner);
}

/// 圆点间距。
const double kCarouselDotGap = 6;

/// 拖拽的**甩动阈值**（逻辑像素/秒）。
///
/// 松手时：低于它按「拖过半就翻一张、没过半就弹回」判；高于它按甩的方向翻一张
/// （往左甩 = 下一张、往右甩 = 上一张）。一格 = [carouselSlotOffset] 像素。
const double kCarouselFlingVelocity = 400;

/// 一格的**水平距离**：邻卡位中心 ↔ 主卡位中心。
///
/// 由几何推出（不写死数字）：主卡半宽 + 邻卡半宽 − 压边量。中档横版 = 374.4。
double carouselSlotOffset(DsCarouselGeometry g) =>
    g.main.width / 2 + g.neighbour.width / 2 - g.overlap;

double _lerp(double a, double b, double t) =>
    t <= 0 ? a : (t >= 1 ? b : a + (b - a) * t);

/// 一张卡在带符号格距 `d` 处的样子（`0` = 正中主卡位、`±1` = 两侧邻卡位）。
///
/// 纯函数 + 纯数据（[forOffset]），所以「点谁谁长大」这条动画可以**按数字测**，不用截图：
/// 静止时 `d = 0` 必须是 `main`、`d = ±1` 必须是 `neighbour` 与 0.72/0.45 —— `ds_carousel_test`
/// 逐格钉住这两端。
@immutable
class DsCarouselCardSpec {
  const DsCarouselCardSpec({
    required this.size,
    required this.dx,
    required this.opacity,
  });

  /// 卡片尺寸。
  final Size size;

  /// 相对**主卡位中心**的水平位移（负 = 在左边）。
  final double dx;

  /// 透明度。
  final double opacity;

  /// 超出这个格距就不画（那两张已经完全透明了）。
  static const double visibleRange = 2;

  /// 左侧邻卡透明度（规范 §9.3）。
  static const double leftOpacity = 0.72;

  /// 右侧邻卡透明度（规范 §9.3）。
  static const double rightOpacity = 0.45;

  /// 那一侧邻卡的透明度。
  static double sideOpacity(double d) => d < 0 ? leftOpacity : rightOpacity;

  /// 由几何 + 带符号格距算出这一张卡的样子。
  ///
  /// * `|d| ≤ 1`：主卡 ↔ 邻卡之间插值（尺寸、位移、透明度一起走）；
  /// * `1 < |d| < 2`：继续按同样的步长向外滑，并淡出到 0（尺寸再缩一点，卖深度）。
  ///
  /// 位移对 `|d|` 是**线性**的：一格就是 [carouselSlotOffset] 像素 —— 拖拽的跟手比例
  /// 与动画的落点都按它换算，两边不会各说各话。
  static DsCarouselCardSpec forOffset(DsCarouselGeometry g, double d) {
    final double u = d.abs();
    final double dx = (d < 0 ? -1 : 1) * carouselSlotOffset(g) * u;
    if (u <= 1) {
      final double t = u;
      return DsCarouselCardSpec(
        size: Size(
          _lerp(g.main.width, g.neighbour.width, t),
          _lerp(g.main.height, g.neighbour.height, t),
        ),
        dx: dx,
        opacity: _lerp(1, sideOpacity(d), t),
      );
    }
    final double t = u - 1;
    return DsCarouselCardSpec(
      size: Size(
        g.neighbour.width * (1 - 0.1 * t),
        g.neighbour.height * (1 - 0.1 * t),
      ),
      dx: dx,
      opacity: sideOpacity(d) * (1 - t),
    );
  }
}

class DsCarousel extends StatefulWidget {
  const DsCarousel({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.geometry,
    this.captionBuilder,
    this.autoPlay = true,
    this.interval = const Duration(seconds: 6),
    this.onIndexChanged,
  });

  final int itemCount;

  /// 每一张卡（主卡与邻卡共用）；尺寸由组件按 [DsCarouselCardSpec] 给。
  final Widget Function(BuildContext context, int index) itemBuilder;

  /// 主卡下方的文字块（可空）；组件把它约束在主卡宽度 × 40 高。
  final Widget Function(BuildContext context, int index)? captionBuilder;

  final DsCarouselGeometry geometry;

  final bool autoPlay;

  /// 自动播放间隔（默认 6 秒，规范 §9.2）。
  final Duration interval;

  final ValueChanged<int>? onIndexChanged;

  @override
  State<DsCarousel> createState() => _DsCarouselState();
}

class _DsCarouselState extends State<DsCarousel>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: DsMotion.carouselBase,
  );

  /// 动画起点 / 终点（都是"位置"，可为分数、可越界；渲染按 itemCount 取模）。
  double _from = 0;
  double _to = 0;

  /// 当前位置：整数 = 某一格就位；分数 = 正在切换或拖拽中。
  double _page = 0;

  /// 当前项（圆点 / 文字块 / `onIndexChanged` 用）。
  int _index = 0;

  Timer? _timer;
  bool _hovering = false;
  bool _dragging = false;
  bool _appActive = true;
  bool _tickersEnabled = true;

  /// 这次拖拽是从哪一格开始的（松手时的甩动判据，见 [_onDragEnd]）。
  double _dragStartPage = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _anim.addListener(_onTick);
    _anim.addStatusListener(_onStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickersEnabled = TickerMode.valuesOf(context).enabled;
    _syncTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool active = state == AppLifecycleState.resumed;
    if (active == _appActive) return;
    _appActive = active;
    _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _anim.removeListener(_onTick);
    _anim.removeStatusListener(_onStatus);
    _anim.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // ── 位置 ───────────────────────────────────────────────────────────────────

  int _wrap(int index) {
    final int count = widget.itemCount;
    if (count <= 0) return 0;
    return ((index % count) + count) % count;
  }

  /// 把当前位置写进去（顺手报 `onIndexChanged`）。
  void _applyPage(double page) {
    _page = page;
    final int next = _wrap(page.round());
    if (next != _index) {
      _index = next;
      widget.onIndexChanged?.call(next);
    }
  }

  /// 离当前位置**最近**的那个"第 index 项就位"的位置（自动处理绕回，走最短方向）。
  double _nearestPageFor(int index) {
    final int count = widget.itemCount;
    if (count <= 0) return _page;
    final double k = ((_page - index) / count).roundToDouble();
    return index + k * count;
  }

  void _animateTo(double target) {
    if (!mounted) return;
    final Duration d = DsMotion.of(context).carousel;
    if (d == Duration.zero || target == _page) {
      setState(() => _applyPage(target));
      _settle();
      return;
    }
    _from = _page;
    _to = target;
    _anim.duration = d;
    // 从当前位置重新起跑：切换中途再点一下（或拖到一半松手）不会跳。
    unawaited(_anim.forward(from: 0));
  }

  void _onTick() {
    final double t = DsMotion.carouselCurve.transform(_anim.value);
    setState(() => _applyPage(_from + (_to - _from) * t));
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _settle();
  }

  /// 落定：恢复自动播放的计时。
  ///
  /// ⚠️ 第三十三轮**去掉了这里的"折回 `[0, itemCount)`"**（原来是 `_page % count`）。
  /// 折回是**数值等价**的（渲染本来就按项数取模），但它会把窗口里的**格号整体挪一段**
  /// （例如 4/5/6/7 → -1/0/1/2）—— 卡片是按格号打 key 的，格号一变，四张卡全部重建，
  /// 于是切换动画**刚结束就再闪一下**。位置本身是 `double`，放着不管不会溢出
  /// （一次一格，一年也就 500 万），换来的是 key 永远稳定。
  void _settle() => _syncTimer();

  void _goTo(int index) => _animateTo(_nearestPageFor(index));

  // ── 自动播放 ───────────────────────────────────────────────────────────────

  bool get _canAutoPlay =>
      widget.autoPlay &&
      widget.itemCount > 1 &&
      _appActive &&
      !_hovering &&
      !_dragging &&
      _tickersEnabled;

  void _syncTimer() {
    if (_canAutoPlay) {
      _timer ??= Timer.periodic(widget.interval, (_) => _advance());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _advance() {
    if (!mounted || widget.itemCount == 0) return;
    _animateTo(_nearestPageFor(_wrap(_page.round() + 1)));
  }

  // ── 拖拽（自己算：跟手 1:1，一格 = carouselSlotOffset 像素）──────────────────

  void _onDragStart(DragStartDetails details) {
    _dragging = true;
    _dragStartPage = _page.roundToDouble();
    _anim.stop();
    _syncTimer();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final double step = carouselSlotOffset(widget.geometry);
    if (step <= 0) return;
    setState(() => _applyPage(_page - details.delta.dx / step));
  }

  /// 松手落点。规矩（`ds_carousel_test` 三条拖拽用例钉住）：
  ///
  /// 1. 先取**最近的稳定位置** `round(_page)`（＝过半就翻一张）；
  /// 2. 甩动只负责**补上这一格**，绝不额外多翻一张：往前甩且本来就该停在这一格（或更后）
  ///    才推到下一格，往后甩同理。
  ///
  /// 第 2 条是老 `PageScrollPhysics` 那套 `base ± 1` 的坑：拖满一格时 `_page` 正好是 1.0，
  /// 再按速度加一格就成了 2 —— 用户拖一屏翻两张。这里按"起点格"判，就不会。
  void _onDragEnd(DragEndDetails details) {
    _dragging = false;
    _syncTimer();
    if (widget.itemCount == 0) return;
    final double velocity = details.velocity.pixelsPerSecond.dx;
    final bool flingForward = velocity < -kCarouselFlingVelocity; // 往左甩 = 下一张
    final bool flingBack = velocity > kCarouselFlingVelocity; // 往右甩 = 上一张
    double target = _page.roundToDouble();
    if (flingForward && target <= _dragStartPage) target = _dragStartPage + 1;
    if (flingBack && target >= _dragStartPage) target = _dragStartPage - 1;
    _animateTo(target);
  }

  // ── 渲染 ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final DsMotion motion = DsMotion.of(context);
    final DsCarouselGeometry g = widget.geometry;
    final int count = widget.itemCount;
    if (count == 0) return const SizedBox.shrink();

    final double gap = 12 * g.k;
    const double captionH = 40;
    final double bottomH = g.blockHeight - g.main.height - gap - captionH;

    // ⚠️ 第三十四轮（用户：「他都跑到侧边栏了才消失掉」）：羽化带要多宽取决于**块本身有多宽**，
    // 而块宽只有布局期知道 —— 所以最外面多这一层 `LayoutBuilder`。
    // 它不影响高度：里面那个 `SizedBox(height: blockHeight)` 仍然说了算
    // （测试 `tester.getRect(DsCarousel).height == 428` 照旧）。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double blockWidth = constraints.maxWidth;
        final LinearGradient? mask = carouselEdgeMask(blockWidth, g);
        return MouseRegion(
          onEnter: (_) {
            _hovering = true;
            _syncTimer();
          },
          onExit: (_) {
            _hovering = false;
            _syncTimer();
          },
          child: SizedBox(
            height: g.blockHeight,
            child: CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                    _animateTo(_nearestPageFor(_wrap(_page.round() + 1))),
                const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                    _animateTo(_nearestPageFor(_wrap(_page.round() - 1))),
              },
              child: Focus(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: _onDragStart,
                  onHorizontalDragUpdate: _onDragUpdate,
                  onHorizontalDragEnd: _onDragEnd,
                  onHorizontalDragCancel: () {
                    final DragEndDetails details = DragEndDetails(
                      velocity: Velocity.zero,
                    );
                    _onDragEnd(details);
                  },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      SizedBox(
                        height: g.main.height,
                        child: Semantics(
                          label: '第 ${_index + 1}/共 $count 部',
                          child: _cardArea(context, mask),
                        ),
                      ),
                      SizedBox(height: gap),
                      SizedBox(
                        height: captionH,
                        child: SizedBox(
                          width: g.main.width,
                          child: AnimatedSwitcher(
                            // 文字块**跟着卡片一起**过渡（第三十二轮）：卡片还在滑、文字已经"啪"地
                            // 换掉，是旧实现最扎眼的第二处（逐帧实测 t≈160ms 就换了）。
                            // 时长走 `DsMotion.page`（180ms）而不是 320ms：`_index` 是**过半**才翻的，
                            // 从那一刻起 180ms 正好在卡片落定（320ms）前后收干净。
                            // 拖拽中不做过渡 —— 手指刷过好几张时会留下一串残影。
                            duration: _dragging ? Duration.zero : motion.page,
                            child: KeyedSubtree(
                              key: ValueKey<int>(_index),
                              child:
                                  widget.captionBuilder?.call(context, _index) ??
                                  const SizedBox.shrink(),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        height: bottomH,
                        child: Row(
                          key: const Key('carousel-dots'),
                          // 圆点**居中**（用户 2026-10-15 第三十二轮：「轮播的小圆点改到中间」）：
                          // 主卡在整块里居中 ⇒ 圆点这一行的中点就是主卡的中点。原来是 `end`（贴右）。
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            for (int i = 0; i < count; i++)
                              GestureDetector(
                                key: Key('carousel-dot-$i'),
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _goTo(i),
                                child: Padding(
                                  padding: const EdgeInsets.only(left: kCarouselDotGap),
                                  child: SizedBox(
                                    width: kCarouselDotSize + 6,
                                    height: bottomH,
                                    child: Center(
                                      child: AnimatedContainer(
                                        duration: motion.hover,
                                        curve: DsMotion.hoverCurve,
                                        width: kCarouselDotSize,
                                        height: kCarouselDotSize,
                                        decoration: BoxDecoration(
                                          color: i == _index ? t.accent : t.line,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 卡片区：**先裁到块自己的矩形里，再在两侧做羽化**（第三十四轮）。
  ///
  /// 顺序不能反：羽化层是 `ShaderMask`（一次 `saveLayer`），它在外面的话仍有像素落在块外，
  /// 而那层 `ClipRect` 才是"绝不可能画到侧边栏上"的硬保证。
  Widget _cardArea(BuildContext context, LinearGradient? mask) {
    final Widget stack = SizedBox(
      width: double.infinity,
      child: Stack(
        // 卡片自己仍然是**不裁**的（裁了就没有"半露邻卡"）；越界的那部分由外面两层接管。
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: _cards(context),
      ),
    );
    return ClipRect(
      key: dsCarouselClipKey,
      child: mask == null
          ? stack
          : ShaderMask(
              key: dsCarouselEdgeMaskKey,
              // `dstIn` = 用渐变的 alpha 当蒙版乘上去：两端乘 0（透明）、中间乘 1（原样）。
              blendMode: BlendMode.dstIn,
              shaderCallback: (Rect bounds) => mask.createShader(bounds),
              child: stack,
            ),
    );
  }

  /// 当前该画的那几张卡（最多 4 张：主卡 + 两侧邻卡 + 正在进出的一张）。
  ///
  /// 窗口按**格号**取（`floor(_page) - 1 … +2`）而不是按项号：项号 = 格号对 itemCount 取模，
  /// 所以 `itemCount` 很小时同一项会合理地出现在两个格子上（旧实现的两个邻卡也是这么来的）。
  List<Widget> _cards(BuildContext context) {
    final int base = _page.floor();
    final List<({int k, double d, int item, DsCarouselCardSpec spec})> slots =
        <({int k, double d, int item, DsCarouselCardSpec spec})>[];
    for (int k = base - 1; k <= base + 2; k++) {
      final double d = k - _page;
      if (d.abs() >= DsCarouselCardSpec.visibleRange) continue;
      final DsCarouselCardSpec spec = DsCarouselCardSpec.forOffset(
        widget.geometry,
        d,
      );
      // 已经完全看不出来的那张不画（也是不挡点击：`Opacity` 本身不吃命中，得在这里剔掉）。
      if (spec.opacity < 0.02) continue;
      slots.add((k: k, d: d, item: _wrap(k), spec: spec));
    }
    // 远的先画（在下层）：主卡位那一张压在最上面。同格距时左边的先画（确定性顺序，
    // 一半进度处两张卡正好一样大）。
    slots.sort((a, b) {
      final int byDistance = b.d.abs().compareTo(a.d.abs());
      return byDistance != 0 ? byDistance : a.d.compareTo(b.d);
    });
    final double nearestD = slots.last.d;
    return <Widget>[
      for (final slot in slots)
        _card(
          context,
          slot: slot.k,
          item: slot.item,
          spec: slot.spec,
          // 只有"最中间那一张"吃内容自己的点击（主页 = 打开这一部）；
          // 其余都是"切到这一张"的热区（F29）。
          interactive: slot.d == nearestD,
        ),
    ];
  }

  Widget _card(
    BuildContext context, {
    required int slot,
    required int item,
    required DsCarouselCardSpec spec,
    required bool interactive,
  }) {
    // ⚠️ 2026-10-15 第三十三轮（用户：「轮播切换时会闪烁」）：这一条链上**任何一层都不许
    // 因为"谁是主卡"而改变形状或 key**。
    //
    // 逐帧探针（`test/carousel_flicker_probe.dart`）改前实测：一次 320ms 切换里，树上的
    // 卡片被**整批重建 4 次**（实例序号 3 → 7 → 10 → 13 → 15）。两处成因：
    // * `_cards` 的绘制顺序是「|格距| 从远到近」，**过半那一刻中间两张互换位置**，
    //   而 Stack 没有 key 时按下标复用元素 ⇒ 换位置 = 把这几张卡重建一遍；
    // * 卡片结构原来随"是否是主卡"变化（主卡少一层 `MouseRegion`/`GestureDetector`/
    //   `AbsorbPointer`），主卡位换人那一刻同样重建。
    //
    // 重建的代价是**肉眼可见的一帧闪**：`DsCover` 是 `ConsumerStatefulWidget`，新 state 的
    // `_file` 是 null ⇒ 先画一帧「无封面」占位，再重新解析、重新解码。
    //
    // 所以：外层按**格号**（`ValueKey(slot)`）打 key —— 格号在一整段动画里不变
    // （同一格上的项号 = `_wrap(k)` 也是常量），换位置时元素跟着走；结构则做成
    // **主卡与邻卡完全同构**，差别只在两个参数上（onTap / absorbing）。
    // 邻卡不再带 `carousel-neighbour-left/right` 这种"侧别 key"：侧别会随着卡片轮换而变，
    // 那等于自己给自己埋一次重建；测试改成按**看得见的位置**点（`carouselSlotOffset`）。
    return Transform.translate(
      key: ValueKey<int>(slot),
      offset: Offset(spec.dx, 0),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: interactive ? null : () => _animateTo(_nearestPageFor(item)),
          child: AbsorbPointer(
            // 吃掉内层指针：主卡那层内容是**更深**的 `GestureDetector`，不吸收的话
            // 它会先赢下手势竞技场（F29 的老坑，见 §9.3）。
            absorbing: !interactive,
            child: Opacity(
              opacity: spec.opacity,
              child: SizedBox(
                width: spec.size.width,
                height: spec.size.height,
                child: widget.itemBuilder(context, item),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
