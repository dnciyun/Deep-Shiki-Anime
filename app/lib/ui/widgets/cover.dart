/// 封面控件（新拟态规范 §7）：凹槽底 + 圆角 16 + **无硬边框**；拿不到图就凹槽底「无封面」。
///
/// 走 [CoverCachePort]（真实实现落盘缓存，测试注入假实现）：
/// **widget 测试永远不会因为封面去联网**，也不会因为图挂了而红。
/// mikan 与 Bangumi 两处封面共用本控件（Bangumi 只需多带一个 `Referer`，
/// 并按自己的显示尺寸把图床 URL 抬到够用的档 —— 见 [DsCover] 的类注释）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/bangumi.dart' show bangumiImageAt;
import '../../domain/mikan_cover.dart' show mikanCoverAt;
import '../../domain/ports.dart';
import '../../state/infra.dart';
import '../../theme/tokens.dart';

/// 一张封面。父级负责尺寸（正方形用 `AspectRatio(1)`，缩略图给 `SizedBox`）。
///
/// **尺寸决定清晰度**（用户 2026-10-12 第二十轮「bangumi 的封面很糊」）：
/// Bangumi 的原始封面 URL 是带宽度前缀的（`/r/<宽>/pic/cover/…`），而 `images.grid`
/// 只有 100 像素宽。这里在 `LayoutBuilder` 里拿到**自己实际的显示宽度**，乘上屏幕缩放
/// 得到需要的设备像素，再让 [bangumiCoverAt] 抬到图床认的那几档（100/200/400/800）——
/// 所以同一个 URL 在不同卡片上会自动取到不同档，缩略图仍然只下 100px（省流量），
/// 各页面也不用手工调参，以后新加的卡片自动是对的。
///
/// 默认圆角 = `DsTokens.radiusCard` 的值。为什么写成一个本地常量而不是直接读 token：
/// `radius` 是 const 构造的默认参数，实例 getter 进不去；写常量 + 这条注释，
/// 改 token 时 `ds_appearance_test.dart` 会同时钉住两边。
const double kDefaultCoverRadius = 12;

/// **固定**按真海报比例（[kPosterAspect]，0.705）开的封面槽用它：图片**一个像素都不裁**。
///
/// 用户 2026-10-15：「今日更新的封面图还是显示不全」。除了 URL 被图床裁成正方形
/// （见 `domain/mikan_cover.dart` 的实测表）之外，还有第二层：真封面里有一小部分
/// 不是 0.705 的竖版（当天 24 张实测：中位 0.7067，但最大 0.926）—— 放到固定比例的
/// 槽里用默认的 `BoxFit.cover` 仍然会把多余的那一边裁掉。这些槽本来就开在
/// `t.inset(...)`（凹槽面 + 1px 线）上，`contain` 留下的那点边正好落在凹槽面上，
/// 看上去是一圈"卡纸"，不会被误认成加载失败。
///
/// 什么时候**不要**用它：槽的比例是**弹性**的（跟着文字块伸缩的「正在追」卡、
/// 形状可在横版/竖版之间切换的轮播卡），那时 `contain` 会让每张卡的留白都不一样；
/// 那种槽继续用默认的 `BoxFit.cover` 铺满。
const BoxFit kPosterFit = BoxFit.contain;

/// 封面**解码宽度**的量化（1.1.0 M1/T5「封面按显示尺寸解码」）。
///
/// 为什么要有这一层：盘上那张封面是按 URL 档下好的（Bangumi `/r/100|200|400|800/`、
/// mikan `?width=200|400|800` —— 见 `domain/bangumi.dart` / `domain/mikan_cover.dart`），
/// 但 `Image.file` 不带 `cacheWidth` 时是**按文件原始像素整张解进 ImageCache** 的：
/// 一张 208pt 的海报卡（本机 1.25 缩放 = 260 设备像素）会把 400×600 的图整张解成
/// 960 000 字节，其中大半是画不出来的。首页网格 + 动漫库 + 轮播一屏几十张，
/// 几十 MB 就这么躺在解码缓存里（用户 2026-10-17 定的 1.1.0 方向：数据性能「D 全都要」，
/// 其中 C = 启动与内存；任务见 `docs/specs/2026-10-17-dsanima-1.1.0-plan.md` 的 T5）。
///
/// ## 为什么是 64 的台阶（不是 128，也不是逐像素）
///
/// * **128 台阶太粗**：本机最常见的就是 208pt 卡 @ 125% 缩放 = 260 设备像素 ——
///   128 台阶把它抬到 384 档（多用 48% 像素，实测只省 7.8% 内存）；64 台阶抬到 320 档
///   （同一条链实测省约 36%）。用户的诉求是"轻便"，这 28 个百分点的差别不是细节。
/// * **逐像素太细**：ImageCache 按宽度分 key（`ResizeImageKey`），窗口拖动时每一像素
///   都会变成一条新的解码条目 —— 条目涨得比省下的字节还快。
/// * 64 是常见的位图/DPR 对齐粒度（Windows 缩放档 100/125/150/175/200% 落上去都不亏）。
const int kCoverDecodeStep = 64;

/// 下限：比它还小的槽按 128 解码（图标/缩略图档，再细没有意义）。
const int kCoverDecodeMinWidth = 128;

/// 上限：1536。
///
/// 为什么不封在 768 上（第一版就是 768，被自己抓出来了）：轮播主卡 552pt 在 200%
/// 缩放下显示宽 **1104 设备像素**，768 档会比旧行为**更糊**（旧行为按文件原尺寸解，
/// 源上最大 800 宽）。而把上限放到 1536 的内存代价**是零**：源上的封面文件最宽 800，
/// `ResizeImage` 又 `allowUpscaling = false`，档位再大也只是"不缩"。
const int kCoverDecodeMaxWidth = 1536;

/// 全部可能的解码档位（[kCoverDecodeStep] 的整数倍，含两端）。
///
/// 截图探针要按档位往 ImageCache 里注入解码结果（`ResizeImage` 的 key 是
/// `obtainKey()` 的结果，不是 provider 本身），所以这个表得是公开的。
final List<int> coverDecodeWidths = <int>[
  for (int width = kCoverDecodeMinWidth; width <= kCoverDecodeMaxWidth; width += kCoverDecodeStep)
    width,
];

/// 把「显示需要多少设备像素」抬到 [kCoverDecodeStep] 的整数倍（0 = 不缩放）。
///
/// 一律**向上**取整：解码宽必须 ≥ 显示物理宽，否则高 DPI 屏会把图放大变糊
/// （`ResizeImage` 的 `allowUpscaling` 只管"文件比档位小"这一侧）。
///
/// `devicePixels <= 0`（布局还没算出宽度 / 约束是无限宽）→ 返回 0：调用方不传
/// `cacheWidth`，行为与本轮之前**完全一样**，绝不乱猜一个尺寸把图缩坏。
///
/// 小图不用单独管：`Image.file` 的 `cacheWidth` 走 [ResizeImage]（`allowUpscaling = false`），
/// 文件本身比档位小时只按原尺寸解，**不会上采样** —— 100px 的图标不会被拉成 256 糊掉
/// （用户 2026-10-15 的「封面图还是显示不全」教过：宁可按原尺寸画，也别猜错尺寸）。
int snapCoverDecodeWidth(int devicePixels) {
  if (devicePixels <= 0) return 0;
  if (devicePixels <= kCoverDecodeMinWidth) return kCoverDecodeMinWidth;
  if (devicePixels >= kCoverDecodeMaxWidth) return kCoverDecodeMaxWidth;
  return ((devicePixels + kCoverDecodeStep - 1) ~/ kCoverDecodeStep) * kCoverDecodeStep;
}

class DsCover extends ConsumerStatefulWidget {
  const DsCover({
    super.key,
    required this.url,
    this.referer,
    this.radius = kDefaultCoverRadius,
    this.placeholderLabel = '无封面',
    this.fit = BoxFit.cover,
    this.tierDevicePixels,
  });

  /// null / 空串 = 站点没给封面 → 直接灰框占位（不去联网试）。
  final String? url;

  /// Bangumi 图床需要 `Referer: https://bgm.tv/`；mikan 不需要。
  final String? referer;
  final double radius;
  final String placeholderLabel;
  final BoxFit fit;

  /// **取档用**的设备像素；不给就按自己实测的显示宽度算（默认行为）。
  ///
  /// 为什么需要它（第三十三轮「轮播切换时会闪烁」）：轮播里同一张卡的宽度在 320ms 里
  /// 从邻卡 264 连续变到主卡 552，按"自己当前多宽"取档会**中途跳档**（400 → 800）——
  /// 换档 = 换 URL = 重新查缓存 + 重新解码，中间空一帧，看上去就是闪一下。
  /// 轮播于是把**主卡宽**（这一段动画里唯一不变的那个尺寸）传进来当取档依据：
  /// 整段切换 URL 一个字节都不变，而静止时邻卡用的也是它自己迟早要用的那一档（不浪费）。
  final int? tierDevicePixels;

  @override
  ConsumerState<DsCover> createState() => _DsCoverState();
}

class _DsCoverState extends ConsumerState<DsCover> {
  /// 这次要显示的本地文件。**第一帧由 LayoutBuilder 里的 [_ensure] 建起来** ——
  /// 只有到布局那一刻才知道自己有多宽（也就才知道该取哪一档）。
  Future<File?>? _file;

  /// 当前这次真正去取的 URL（已按显示尺寸抬过档）—— 变了才重新解析。
  String? _requestedKey;

  /// 请求序号：晚到的旧请求不许覆盖 [_lastFile]。
  int _requestSeq = 0;

  /// 上一次**真的画出来**的那张图，以及它属于哪个原始 URL。
  ///
  /// 第三十三轮：等待新档位/新 URL 的那一两帧不再空着 —— 先顶着画上一张。
  /// 只在**原始 URL 没变**时复用（换了一部番就必须重新占位，不能拿上一部的图冒充）。
  File? _lastFile;
  String _lastFileRaw = '';

  /// **缓存同步命中**的那张（第三十七轮）：有它就完全不走 `FutureBuilder`。
  ///
  /// 用户 2026-10-16：「动漫库的封面图保存缓存，不然每次都要加载」——封面本来就在盘上
  /// （缓存是落盘的），但每次显示都要过一次 `await`，于是每张卡都先空一帧灰底。
  /// 现在先在内存索引里同步问一句，命中就当帧画出来。
  File? _ready;
  String _readyRaw = '';

  /// 上一次取档用的是哪个原始 URL / 多少设备像素（第三十七轮的兜底，见 [build]）。
  String? _ensuredRaw;
  int? _lastDevicePixels;

  /// 这一帧该按多宽**解码**（设备像素；0 = 不缩放，保持旧行为）。
  ///
  /// 与 URL 抬档同一个数（[snapCoverDecodeWidth]）：轮播传了 [DsCover.tierDevicePixels]
  /// 时两者一起钉在同一个值上，不会出现「URL 不跳档、解码宽度却跟着动画跳」的重新解码。
  int _decodeWidth = 0;

  @override
  void didUpdateWidget(covariant DsCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.referer != widget.referer) {
      _requestedKey = null; // 下一帧按新 URL 重新解析
    }
  }

  /// 按「显示宽度 × 屏幕缩放」算出该取的 URL 并（只在其变化时）发起缓存查询。
  ///
  /// 宽高比是竖版海报，所以按**宽度**定档就够了（高度同比例跟着变）。
  ///
  /// 取档依据：默认 = 自己此刻的显示宽度；调用方给了 [DsCover.tierDevicePixels]
  /// 就用它（轮播传主卡宽：整段切换动画里尺寸唯一不变的那个数，见该字段的注释）。
  ///
  /// ⚠️ 这里是**所有封面 URL 的唯一取档入口**，两个图床的规则各跑一遍：
  /// Bangumi 抬 `/r/<档>/`（[bangumiImageAt]：条目封面 `/pic/cover/` 与角色头像
  /// `/pic/crt/` 是同一套档位），mikan 删掉会把自己裁成正方形的 `height` 参数
  /// （[mikanCoverAt]）。顺序无关（各家的 URL 形状不重叠），但都得跑。
  void _ensure(String? url, int devicePixels) {
    final String raw = url?.trim() ?? '';
    final int pixels = widget.tierDevicePixels ?? devicePixels;
    _ensuredRaw = raw;
    _lastDevicePixels = pixels;
    // ⚠️ 解码宽度要**在 key 判重之前**刷新：URL 档位可能没变（比如 208→250 都还在 400 档），
    // 但解码档位变了（256→384），这时也得按新的宽度解 —— 否则大卡会一直用着偏小的解码图发糊。
    _decodeWidth = snapCoverDecodeWidth(pixels);
    final String target =
        mikanCoverAt(bangumiImageAt(raw, pixels), pixels) ?? '';
    final String key = '$target|${widget.referer ?? ''}';
    if (key == _requestedKey) return;
    _requestedKey = key;

    // ⭐ 第三十七轮：先问**内存索引**（同步、零 IO）。命中就这一帧直接画，
    // 连 `Image.file` 的解码都能命中 Flutter 自己的 ImageCache —— 于是"每次进来
    // 都要加载一下"的那一帧灰底没有了。
    if (target.isNotEmpty) {
      final File? ready = ref.read(coverCacheProvider).cachedNow(target);
      if (ready != null) {
        _ready = ready;
        _readyRaw = raw;
        _lastFile = ready;
        _lastFileRaw = raw;
        _file = null;
        _requestSeq++; // 在途的旧请求就此作废（晚到的结果不许覆盖这张）
        return;
      }
    }
    _ready = null;
    _file = _load(target, raw, ++_requestSeq);
  }

  /// 先按抬档后的 URL 取，**取不到就退回原始 URL**。
  ///
  /// 为什么必须有这层兜底（第二十一轮）：上一版把 `/r/<宽>/` 无条件插进 URL，
  /// 而旧搜索接口给的老式 URL（`/pic/cover/g/…`）**不接受**这种前缀（HTTP 400）——
  /// 于是「已完成」页的封面全部加载不出来。凡是"改写 URL 换取清晰度/完整度"的地方都得有
  /// 这一步：改对了更清楚，改错了至少照旧能显示，绝不比以前更差。
  /// （第三十一轮的 mikan 去 `height` 同理：真取不到时退回带 `height` 的原 URL，
  /// 至少是那张被裁过的方图，而不是一片空白。）
  Future<File?> _load(String target, String raw, int seq) async {
    final CoverCachePort cache = ref.read(coverCacheProvider);
    File? file;
    if (target.isNotEmpty) {
      file = await cache.fileFor(target, referer: widget.referer);
    }
    if (file == null && raw.isNotEmpty && raw != target) {
      file = await cache.fileFor(raw, referer: widget.referer);
    }
    // 只认"最新那次请求"的结果：晚到的旧请求不许把 [_lastFile] 改回旧图。
    if (file != null && seq == _requestSeq) {
      _lastFile = file;
      _lastFileRaw = raw;
    }
    return file;
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    // ⚠️ 第三十七轮补的一道兜底：取档本来只在 `LayoutBuilder` 的 builder 里做，而它**只在
    // 约束变化时**重跑 —— 「换成另一部番、但卡片尺寸一模一样」（列表里上下换条目、详情页
    // 换 subject）时它可能不重跑，于是新 URL 永远等不到取档（表现为那一格一直空着）。
    // 用"记住的上一帧宽度"在这里补一次即可：尺寸真变了的话 LayoutBuilder 自己还会再算一次，
    // 算出来的 key 相同就直接返回，不会重复请求。
    final String rawNow = (widget.url ?? '').trim();
    final int? lastPixels = _lastDevicePixels;
    if (lastPixels != null && _ensuredRaw != rawNow) {
      _ensure(widget.url, lastPixels);
    }
    return Container(
      clipBehavior: Clip.antiAlias,
      // 封面槽是凹槽面：与 `DsInset` 同一套（面色 + 1px `line`）—— 第三十轮补上这条线，
      // 否则它是全项目唯一一个没有描边的凹槽面（审计 `build/sdd-flat-step2/audit.md`）。
      decoration: t.inset(radius: widget.radius),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // ⚠️ 这里在 build 里改字段（不是 setState）：算出来的值只依赖约束与缩放，
          // 同一帧内紧接着就用，重建时 key 相同直接返回 —— 不会来回抖动。
          final double logical = constraints.maxWidth.isFinite ? constraints.maxWidth : 0;
          final double dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
          _ensure(widget.url, logical <= 0 ? 0 : (logical * dpr).ceil());
          return _content(t);
        },
      ),
    );
  }

  Widget _content(DsTokens t) {
    // ① 内存索引命中（第三十七轮）：当帧就有 File，不经过 `FutureBuilder`。
    final File? ready = _ready;
    if (ready != null && _readyRaw == (widget.url ?? '').trim()) {
      return _image(ready);
    }
    final Future<File?>? future = _file;
    if (future == null) return _placeholder(t);
    // 上一次画出来的那张（同一原始 URL 才算数）：新档位还在路上时先顶着，
    // 免得空一帧 —— 这正是第三十三轮用户看到的"闪一下"。
    final File? previous =
        _lastFileRaw == (widget.url ?? '').trim() ? _lastFile : null;
    return FutureBuilder<File?>(
      future: future,
      builder: (BuildContext context, AsyncSnapshot<File?> snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          // 加载中只留灰底（不转圈：一屏几十张缩略图同时转圈反而更吵）。
          return previous == null ? const SizedBox.expand() : _image(previous);
        }
        final File? file = snapshot.data;
        if (file == null) return previous == null ? _placeholder(t) : _image(previous);
        return _image(file);
      },
    );
  }

  Widget _image(File file) => Image.file(
        file,
        fit: widget.fit,
        width: double.infinity,
        height: double.infinity,
        // 1.1.0 M1/T5：按这一帧**实际显示**的设备像素解码，别把整张图解进 ImageCache
        // （档位换算见 [snapCoverDecodeWidth]；0 = 尺寸还没算出来 → 不传，照旧整张解）。
        // `cacheWidth` 的内部就是 [ResizeImage] + `allowUpscaling: false`：
        // 文件比档位小时只按原尺寸解，小图不会被上采样放大。`filterQuality` /
        // `gaplessPlayback` 一个都不动 —— 这一轮只换解码尺寸。
        cacheWidth: _decodeWidth > 0 ? _decodeWidth : null,
        gaplessPlayback: true,
        // 文件坏了（半截下载/不是图片）也降级，不让一屏卡片变红。
        errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
            _placeholder(context.ds),
      );

  /// 「无封面 / 加载中」占位块的色相（第五十二轮——用户「整个项目太素」）。
  ///
  /// 取 URL（没有 URL 就用占位文案）的稳定哈希落进 12 色：同一张卡每次渲染同色，
  /// 相邻卡片大概率不同色。这样封面还没到 / 站点没给封面时，网格里不是一排灰砖，
  /// 而是一组淡彩占位块（真正的封面到了就盖上去）。
  DsHue _placeholderHue() {
    final String raw = (widget.url ?? '').trim();
    final String seed = raw.isEmpty ? widget.placeholderLabel : raw;
    int code = 17;
    for (final int unit in seed.codeUnits) {
      code = (code * 31 + unit) & 0x7fffffff;
    }
    return DsHue.values[code % DsHue.values.length];
  }

  Widget _placeholder(DsTokens t) {
    final DsHue hue = _placeholderHue();
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[t.hueSoftOn(hue, t.sunken), t.sunken],
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Text(
            widget.placeholderLabel,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: t.hueInk(hue), fontSize: DsTypeScale.caption),
          ),
        ),
      ),
    );
  }
}
