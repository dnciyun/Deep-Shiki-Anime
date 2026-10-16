/// 独立播放窗口（用户 2026-10-10 的硬要求：**只有弹出窗口播放**，主窗口任何地方都不播）。
///
/// 为什么不是「主窗口里放播放面」：Flutter 官方的 Desktop Windowing API 能做到共享
/// isolate，但它在本机 stable（3.44.2）上被特性开关锁死（`windowingFeature` 只声明了
/// `master: available: true`，`flutter config --enable-windowing` 会"成功"但无效，
/// 运行时构造窗口控制器直接抛 `UnsupportedError`）—— 已实测，见
/// `build/mw_probe/REPORT.md`。
///
/// 所以走 `desktop_multi_window`：**子窗口是独立 Flutter 引擎/独立 isolate**。
/// 探针（`build/mw_probe_v2/`）实测过三件事：
/// 1. 子窗口里 media_kit **能硬解渲染**（`Using H/W rendering` / texture 非空 / position 递增）；
/// 2. 同进程两个 Player 可以并存互不干扰；
/// 3. 子窗口能读宿主的 assets。
///
/// 代价（已接受）：mpv 实例**不共享**，播放器在子窗口里自持；父子之间只能传值 ——
/// 外观（token）与剧集分组由主窗口**推**过去（见 [PlayerWindowService.pushArgs]），
/// 播放请求走 [kMethodOpen]。
library;

import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color, Rect;
import 'package:flutter/services.dart' show MethodCall;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/episode_group.dart';
import '../domain/window_placement.dart' show PlayerWindowPlan;
import '../theme/tokens.dart';

/// 主窗口侧的播放窗口管理器（开窗/复用/推环境/关闭）。
///
/// 装配根在创建 `ProviderContainer` **之前**就造好实例，然后
/// `playerWindowServiceProvider.overrideWithValue(...)` 注入 —— 因为
/// `PlayerWindowPort`（播放投递）与开关/标题 provider 都要用它。
///
/// 没注入时给一个 [PlayerWindowService.unconfigured] 占位：组件测试里状态栏仍要能
/// 读「窗口开着没有」（答案是"没开"），**不能**因为没注入就整棵树报错。
final Provider<PlayerWindowService> playerWindowServiceProvider = Provider<PlayerWindowService>(
  (Ref ref) => PlayerWindowService.unconfigured(),
);

/// 把宿主 token 压成可 JSON 传输的 map（子窗口是独立 isolate，只能靠传值）。
Map<String, Object?> encodeTokens(DsTokens t) => <String, Object?>{
  'isDark': t.isDark,
  'base': t.base.toARGB32(),
  'raised': t.raised.toARGB32(),
  'sunken': t.sunken.toARGB32(),
  'line': t.line.toARGB32(),
  'text': t.text.toARGB32(),
  'text2': t.text2.toARGB32(),
  'text3': t.text3.toARGB32(),
  'accent': t.accent.toARGB32(),
  'success': t.success.toARGB32(),
  'warning': t.warning.toARGB32(),
  'danger': t.danger.toARGB32(),
  'shadowLight': t.shadowLight.toARGB32(),
  'shadowDark': t.shadowDark.toARGB32(),
};

/// 还原 token；字段缺失/类型不对就退回 [DsTokens.whiteInk]（子窗口不该因为
/// 一个字段坏了而白屏）。
DsTokens decodeTokens(Map<Object?, Object?>? map) {
  if (map == null) return DsTokens.whiteInk;
  Color c(String key, Color fallback) {
    final Object? v = map[key];
    return v is int ? Color(v) : fallback;
  }

  final DsTokens base = DsTokens.whiteInk;
  return base.copyWith(
    isDark: map['isDark'] as bool? ?? false,
    base: c('base', base.base),
    raised: c('raised', base.raised),
    sunken: c('sunken', base.sunken),
    line: c('line', base.line),
    text: c('text', base.text),
    text2: c('text2', base.text2),
    text3: c('text3', base.text3),
    accent: c('accent', base.accent),
    success: c('success', base.success),
    warning: c('warning', base.warning),
    danger: c('danger', base.danger),
    shadowLight: c('shadowLight', base.shadowLight),
    shadowDark: c('shadowDark', base.shadowDark),
  );
}

/// 子窗口参数类型（放在子窗口 arguments 里，便于子窗口判断"我是播放窗口"）。
const String kPlayerWindowType = 'player';

/// 主窗口 → 子窗口的方法名。
const String kMethodOpen = 'open';
const String kMethodStop = 'stop';
const String kMethodPlayOrPause = 'playOrPause';
const String kMethodSeek = 'seek';

/// 主窗口 → 子窗口：外观/剧集分组变了（浅深切换、简洁模式、换集后的分组）。
///
/// 子窗口是独立 isolate，读不到主窗口的 provider 容器，所以这类"环境"只能推。
const String kMethodArgs = 'args';

/// 主窗口 → 子窗口：「你自己关掉这一扇窗」。
///
/// 为什么不是插件的 `window_close`：`desktop_multi_window` 0.3.1 的 Windows
/// `FlutterWindowWrapper::HandleWindowMethod` **只**实现了 `window_show` /
/// `window_hide`，`window_close` 一定回 `unknown method: window_close`
/// （主窗口那颗「关闭播放窗口」按钮在老代码里就是因此静默失效的）。
/// 所以关闭动作只能由子窗口自己的 Dart 侧执行 —— 见子窗口里的
/// `windowManager.close()`：它只给**这一扇窗**发 `SC_CLOSE`，不碰进程。
///
/// ⚠️ 这是**彻底关闭**（拆掉子窗口 + 它的引擎），不再是默认的「关闭播放器」。
/// 默认关闭走 [kMethodHideSelf]。
const String kMethodCloseSelf = 'closeSelf';

/// 主窗口 → 子窗口：**把自己收起来** —— 停播 + `ShowWindow(SW_HIDE)`，不拆引擎。
///
/// 用户 2026-10-11：「关掉播放器后不会全关掉，但是主窗口会卡死」。真机复盘：
/// 「关窗 → DestroyWindow」会让子窗口引擎**同步拆除**
/// （`FlutterWindow::OnDestroy` → `flutter_controller_ = nullptr`），而这一步发生在
/// **主线程的消息泵里**、还要 join 子窗口的 UI 线程 —— 同一个拆除过程
/// 既可能 fast-fail（0xC0000409，用户 10-10 报的「全关了」），
/// 也可能把主窗口拖住到不响应（用户 10-11 报的「主窗口卡死」）。
/// 收起来不碰拆除，所以这两类现象在正常关闭路径上都不再存在。
const String kMethodHideSelf = 'hideSelf';

/// 子窗口 → 主窗口：「我已经把自己收起来了」（窗口还在，只是隐藏 + 已停播）。
///
/// 方向说明：每个窗口都用自己的 id 注册一条通道
/// `mixin.one/window_controller/<自己的 windowId>`，而这条通道在插件里是
/// **unidirectional**（`window_channel_plugin.cc` 的 `RegisterUnidirectional`：
/// 只能有一个引擎注册处理器，但**任何引擎都能调它**）。所以子窗口只要有主窗口的
/// windowId（`WindowController.getAll()` 里除了自己那一条）就能反过来通知主窗口。
/// 这是插件里唯一可用的「子 → 父」方向。
const String kMethodChildHidden = 'childHidden';

/// 子窗口 → 主窗口：「我现在在这个位置/这个大小」（逻辑像素）。
///
/// 用途：用户把播放窗口拖到哪儿，下次开窗就还放哪儿 —— 见
/// `PlayerWindowService.onGeometryReported`。参数：`{left, top, width, height}`。
const String kMethodGeometry = 'geometry';

/// 子窗口 → 主窗口：「用户点了播放列表里的这一条」（参数 = 条目 id）。
///
/// 为什么必须交回主窗口（用户 2026-10-11：「我要的播放列表为什么没有，按照我播放的
/// 同名同压制组」）：按「同名同压制组」组出来的列表里，其它集是**别的种子**、
/// 还没进引擎，子窗口根本没有它们的串流地址。只有主窗口能补详情页磁力、加种、
/// 拿到 `streamUrl`，再走唯一那条开播链路把请求发回来。
const String kMethodEpisodeSelect = 'episodeSelect';

/// 子窗口 → 主窗口：「播到第几秒了 / 这一集多长」（第二十七轮，观看记录要它）。
///
/// 为什么必须新开一条上报：`PlayerWindowPort.signals` 是**空流**（播放面在子窗口里，
/// 主窗口这一侧没有任何信号源，见 `player_adapter.dart`），所以观看进度只可能是
/// 子窗口主动报上来的。参数：`{positionMs, durationMs}`；主窗口拿它配 `nowPlaying`
/// 上的那一条元数据（番名/集数/字幕组）算出记录键，见 `PlaybackController.onWatchProgress`。
///
/// 上报节流在子窗口（每 5 秒一条 + 停播/换集/关窗各一条），所以主窗口这里不需要去抖。
const String kMethodWatchProgress = 'watchProgress';

/// 主窗口 → 子窗口：「你刚才点的那一集**没切过去**，原因是这个」（第三十八轮）。
///
/// 用户原话：「优化反馈，点击下一集或上一集都没实质性反馈」。跨种子切集要等
/// 「补磁力 → `addMagnet` 等元数据」，失败时原因原本只出现在**主窗口**的横幅上 ——
/// 用户人还在播放窗口里，那条横幅被盖住，等于没有提示。参数：
/// `{title, message, hint?}`（`hint` = 「怎么办」）。
///
/// 反向的那一半（点下去就亮「正在切到…」）在子窗口本地做，不需要新通道：
/// `PlayerSurface._beginEpisodeSwitch`。
const String kMethodSwitchFailed = 'switchFailed';

/// 观看进度上报的最小间隔（毫秒）：每前进这么多就报一条（第二十七轮）。
///
/// 5 秒是"够用且不吵"的档：再密就是每帧一条跨窗口消息，再疏则关掉播放器那一下
/// 会丢掉半分钟进度。主窗口写盘另有自己的节流（同一条记录只在进度真的变化时写）。
const int kWatchProgressReportMs = 5000;

/// 传给子窗口的启动参数（JSON）。
///
/// [tokens] / [episodeGroup] / [wakeChromeAtCenter] 都是**可推送**的环境：开窗时带上，
/// 之后主窗口变化时用 [kMethodArgs] 再推一次（`null` = 保持子窗口当前值，
/// 不要用"没带"覆盖成默认）。
@immutable
class PlayerWindowArgs {
  const PlayerWindowArgs({
    required this.streamUrl,
    required this.title,
    this.startAtMs,
    this.subtitlePath,
    this.tokens,
    this.episodeGroup,
    this.windowBounds,
    this.wakeChromeAtCenter,
  });

  final String streamUrl;
  final String title;
  final int? startAtMs;
  final String? subtitlePath;

  /// 宿主当前外观（子窗口是独立 isolate，只能靠传值拿到）。
  final Map<String, Object?>? tokens;

  /// 当前集所在的那一组（决策 B31）：`<String, Object?>{items: [...], currentIndex: n}`。
  /// 每项的 `streamUrl` 由宿主填好 —— 网流的 per-file 地址只有主窗口拿得到。
  final Map<String, Object?>? episodeGroup;

  /// 开窗时的落点与尺寸（**逻辑像素**：`left/top/width/height`）。
  ///
  /// 用户 2026-10-11：「只要启动了播放器，主窗口就没办法使用了」——
  /// 旧的 `center: true` 让播放窗口（1280×720）把主窗口（1100×680）整个盖住。
  /// 这个值由 `domain/window_placement.dart` 算出来，只在**建窗那一次**生效：
  /// 之后用户自己拖过/缩过，就不再动它（不然每次播放都跳回原位）。
  final Map<String, Object?>? windowBounds;

  /// 鼠标移到画面正中是否也唤起两条栏（宿主「设置 → 播放器」，第二十七轮）。
  ///
  /// 子窗口是独立 isolate，读不到主窗口的 `settingsProvider`，只能像 token 一样推过去。
  /// `null` = 没说（保持子窗口当前值）。
  final bool? wakeChromeAtCenter;

  Map<String, Object?> toJson() => <String, Object?>{
    'type': kPlayerWindowType,
    'streamUrl': streamUrl,
    'title': title,
    if (startAtMs != null) 'startAtMs': startAtMs,
    if (subtitlePath != null) 'subtitlePath': subtitlePath,
    // ignore: use_null_aware_elements
    // （`?tokens` 这种 map 里的空感知元素在本机 SDK 上还编不过，用 if。）
    if (tokens != null) 'tokens': tokens,
    if (episodeGroup != null) 'episodeGroup': episodeGroup,
    if (windowBounds != null) 'windowBounds': windowBounds,
    // ignore: use_null_aware_elements
    if (wakeChromeAtCenter != null) 'wakeChromeAtCenter': wakeChromeAtCenter,
  };

  /// 带上落点（新建窗口用）。
  PlayerWindowArgs withWindowBounds(Map<String, Object?>? bounds) => PlayerWindowArgs(
    streamUrl: streamUrl,
    title: title,
    startAtMs: startAtMs,
    subtitlePath: subtitlePath,
    tokens: tokens,
    episodeGroup: episodeGroup,
    windowBounds: bounds,
    wakeChromeAtCenter: wakeChromeAtCenter,
  );

  String encode() => jsonEncode(toJson());

  /// 只带环境的推送体（换集时不必重发 token，反之亦然）。
  static Map<String, Object?> envJson({
    Map<String, Object?>? tokens,
    Map<String, Object?>? episodeGroup,
    bool? wakeChromeAtCenter,
  }) => <String, Object?>{
    'type': kPlayerWindowType,
    // ignore: use_null_aware_elements
    if (tokens != null) 'tokens': tokens,
    // ignore: use_null_aware_elements
    if (episodeGroup != null) 'episodeGroup': episodeGroup,
    // ignore: use_null_aware_elements
    if (wakeChromeAtCenter != null) 'wakeChromeAtCenter': wakeChromeAtCenter,
  };

  /// 解析子窗口拿到的 arguments；不是播放窗口（或解析失败）→ null。
  static PlayerWindowArgs? decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final Map<Object?, Object?> map = decoded;
      if (map['type'] != kPlayerWindowType) return null;
      final Object? url = map['streamUrl'];
      final Object? tk = map['tokens'];
      final Object? eg = map['episodeGroup'];
      final Object? wb = map['windowBounds'];
      return PlayerWindowArgs(
        // 环境推送体没有 streamUrl：这时只更新 token/分组，不要当成新播放请求。
        streamUrl: url is String ? url : '',
        title: (map['title'] as String?) ?? '',
        startAtMs: (map['startAtMs'] as num?)?.toInt(),
        subtitlePath: map['subtitlePath'] as String?,
        tokens: tk is Map ? tk.cast<String, Object?>() : null,
        episodeGroup: eg is Map ? eg.cast<String, Object?>() : null,
        windowBounds: wb is Map ? wb.cast<String, Object?>() : null,
        wakeChromeAtCenter: map['wakeChromeAtCenter'] as bool?,
      );
    } catch (_) {
      return null; // 参数坏了不该炸掉子窗口，交给空态
    }
  }
}

/// 串行闸门：把并发调用排成一条链，一次只跑一个（第四十二轮 UX #51）。
///
/// 为什么单独一个类：`PlayerWindowService.open()` 里"建窗"这一步走平台通道
/// （`WindowController.create`），组件测试里造不出真窗口；而"**两路同时进来必须串行**"
/// 恰恰就是要钉住的那个行为。抽成不依赖任何插件的小闸门，就能直接单测它。
///
/// 语义：
/// * 后来的调用**等**前一个真的做完（含它内部的 await）才开始；
/// * 前一个**失败**不阻塞后面的（错误照样回给**它自己**的调用方，链继续往下走）。
class SerialGate {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final Completer<T> out = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        out.complete(await action());
      } catch (error, stackTrace) {
        out.completeError(error, stackTrace);
      }
    });
    return out.future;
  }
}

/// 主窗口侧的播放窗口管理器。
///
/// 职责只有四件：**开窗/复用**、**下发播放请求**、**推送环境（token/剧集分组）**、
/// **跟随开关状态**。不镜像播放进度：进度落盘由子窗口自己的
/// `SettingsController.resume` 负责（父子共享同一个支持目录与 Hive box），
/// 主窗口不需要知道"播到第几秒"。
class PlayerWindowService {
  PlayerWindowService({
    this.logger,
    this.placeWindow,
    this.saveGeometry,
  }) : isConfigured = true;

  /// 没被装配根注入的占位实例：UI 读状态是安全的（永远是"没开窗口"），
  /// 但 [open] 会明确抛错 —— 免得"没接上"被伪装成"播放成功"。
  PlayerWindowService.unconfigured()
    : isConfigured = false,
      logger = null,
      placeWindow = null,
      saveGeometry = null;

  /// 排障落点（装配根注入 shikiin 的 `diag`，写进同一份日志）。
  ///
  /// 为什么需要：用户 2026-10-11 报「关掉播放器后主窗口卡死」，而主窗口这一侧
  /// 到底走到哪一步只有日志能回答（窗口列表事件收到没有 / 子窗口回话没有）。
  /// 组件测试里没注入就退回 `debugPrint`。
  final void Function(String message)? logger;

  /// 「这次开窗该把播放窗口放哪儿」（**逻辑像素**）。
  ///
  /// 装配根注入（`main.dart`）：先看用户上次把它放哪儿了，没有就按工作区**居中**
  /// 算一个落点（见 `domain/window_placement.dart`）。
  /// null / 未注入 = 用插件的默认（居中）—— 组件测试走这条。
  final Future<PlayerWindowPlan?> Function()? placeWindow;

  /// 记住用户自己拖出来的位置/大小（每次子窗口报告几何时调用）。
  final Future<void> Function(Rect bounds)? saveGeometry;

  /// 子窗口点了播放列表里的某一集（参数 = 条目 id）。
  ///
  /// 装配根在**容器建好之后**接上（`main.dart`：`playbackProvider.notifier
  /// .playPlaylistEntry`），所以这里是可写字段而不是构造参数。
  Future<void> Function(String itemId)? onEpisodeSelected;

  /// 子窗口报上来的播放进度（参数 = `{positionMs, durationMs}`）。
  ///
  /// 与 [onEpisodeSelected] 同一套接法：装配根在容器建好后接上
  /// （`main.dart` → `playbackProvider.notifier.onWatchProgress`）。
  Future<void> Function(Object? raw)? onWatchProgress;

  void _log(String message) {
    final void Function(String)? sink = logger;
    if (sink != null) {
      sink(message);
      return;
    }
    debugPrint('[player-window] $message');
  }

  /// 是不是装配根真正注入的那个（false = 占位）。
  bool isConfigured = true;

  WindowController? _controller;

  /// 最近一次下发的标题（主窗口 UI 显示用）。
  final ValueNotifier<String?> currentTitle = ValueNotifier<String?>(null);

  /// 当子窗口被用户关掉时触发（主窗口据此更新 UI）。
  final ValueNotifier<bool> isOpen = ValueNotifier<bool>(false);

  /// 子窗口**还活着但被收起来了**（停播 + 隐藏，见 [kMethodHideSelf]）。
  ///
  /// 与 [isOpen] 是两个维度：`isOpen` = 这扇窗还在不在，`isHidden` = 它是不是被收着。
  /// 状态栏据 `isOpen && !isHidden` 判断「正在播放」，否则那颗按钮是「唤回播放器」。
  final ValueNotifier<bool> isHidden = ValueNotifier<bool>(false);

  /// 子窗口报告"起播了另一集"时更新（上一集/下一集在子窗口里点的）。
  final ValueNotifier<String?> reportedTitle = ValueNotifier<String?>(null);

  /// 最近一次推送过的 token / 分组（避免同值重复推）。
  Map<String, Object?>? _lastTokens;
  Map<String, Object?>? _lastGroup;

  /// 最近一次推送过的「画面正中也唤起」（null = 还没推过）。
  bool? _lastWakeChromeAtCenter;

  /// 环境推送的退避重试次数（成功即清零；见 [pushArgs]）。
  int _envRetries = 0;

  StreamSubscription<void>? _windowsSub;

  /// 主窗口自己的 controller（用来接收子窗口反过来的通知）。
  WindowController? _self;

  bool get hasWindow => _controller != null;

  /// 注册「本窗口自己」的窗口通道处理器：子窗口要把「我收起来了」告诉主窗口。
  ///
  /// 必须在**创建播放窗口之前**绑定：子窗口收起时会立刻回发 [kMethodChildHidden]，
  /// 那时通道必须已经注册好（通道是进程级的，晚注册就会撞 `CHANNEL_UNREGISTERED`）。
  Future<void> bindSelf() async {
    if (_self != null) return;
    try {
      final WindowController self = await WindowController.fromCurrentEngine();
      await self.setWindowMethodHandler((MethodCall call) async {
        switch (call.method) {
          case kMethodChildHidden:
            _markHidden();
          case kMethodGeometry:
            await _noteGeometry(call.arguments);
          case kMethodEpisodeSelect:
            await _onEpisodeSelect(call.arguments);
          case kMethodWatchProgress:
            await _onWatchProgress(call.arguments);
        }
        return null;
      });
      _self = self;
      _log('主窗口通道已注册：${self.windowId}');
    } catch (e) {
      // 注册不上只影响「子窗口主动收起」的状态同步（列表变化那条路照旧）；
      // 不能因此不让用户播放。
      _log('主窗口通道注册失败（状态同步会退化为窗口列表）：$e');
    }
  }

  /// 打开（或复用）播放窗口并投递一条播放请求。
  ///
  /// 首次调用创建窗口并把请求放在启动参数里（避免子窗口启动后再补发的竞态）；
  /// 之后复用同一个窗口，用 [kMethodOpen] 下发新请求（换集时不会闪一个新窗口）。
  ///
  /// ⚠️ **必须串行**（第四十二轮 UX #51）：`_open()` 中间有一个 `await`（算落点），
  /// 两路起播同时进来（搜索页点播 + 通知点击、或手快点两下）会**双双**看到
  /// `_controller == null`，于是各建一扇窗 —— 两个 mpv、两份声音。
  /// 排成一条链之后，后来那次等前一次做完，那时 `_controller` 已经就位，走的是复用。
  Future<void> open(PlayerWindowArgs args) => _gate.run(() => _open(args));

  /// 建窗/复用那条链的闸门。
  final SerialGate _gate = SerialGate();

  Future<void> _open(PlayerWindowArgs args) async {
    if (!isConfigured) {
      throw StateError('播放窗口服务没接上：装配根必须注入 PlayerWindowService');
    }
    _lastTokens = args.tokens ?? _lastTokens;
    _lastGroup = args.episodeGroup ?? _lastGroup;
    _lastWakeChromeAtCenter = args.wakeChromeAtCenter ?? _lastWakeChromeAtCenter;
    // 无论复用还是新建都先算一次落点：算出来的值只在**建窗那一次**用
    // （复用那次不能把用户拖过的窗口拽回去），但日志要留下"这一轮主窗口在哪、
    // 播放窗口该在哪"，排障时才有证据。
    final Map<String, Object?>? bounds = await _nextBounds();
    final WindowController? existing = _controller;
    if (existing != null) {
      try {
        await existing.invokeMethod<void>(kMethodOpen, args.toJson());
        currentTitle.value = args.title;
        // 子窗口收到 kMethodOpen 会把自己 show() 出来（它可能正被收着）。
        isHidden.value = false;
        reportedTitle.value = null;
        return;
      } catch (e) {
        // 窗口可能已被用户关掉：清掉引用，走下面的新建路径。
        _log('复用失败，改新建：$e');
        _controller = null;
      }
    }

    final WindowController controller = await WindowController.create(
      WindowConfiguration(
        // 不隐藏启动：子窗口一出现就渲染播放面的空态/画面，
        // 避免「隐藏 → 再 show」与 window_manager 抢同一个 HWND（探针 R7 未验证项）。
        hiddenAtLaunch: false,
        // 落点只在**建窗那一次**带上：之后再开只 show 出来，不会把用户拖过的窗口
        // 拽回原位（用户 2026-10-11：「只要启动了播放器，主窗口就没办法使用了」——
        // 旧行为是居中，把主窗口整个盖住）。
        arguments: args.withWindowBounds(bounds).encode(),
      ),
    );
    _controller = controller;
    isOpen.value = true;
    isHidden.value = false;
    currentTitle.value = args.title;
    reportedTitle.value = null;
    _watchWindowsChanged();
    // 开窗那一刻主窗口可能在"还没解析出剧集分组"的状态：窗口就绪后无条件补推一次
    // 已存环境，避免播放器少了上一集/下一集按钮（值一样时子窗口自己会忽略）。
    unawaited(replayEnv());
  }

  /// 建窗那一次该用的落点（逻辑像素）；null = 不指定，交给插件默认（居中）。
  ///
  /// 装配根没注入 [placeWindow]（组件测试）时返回 null，测试里就不会有落点参数。
  ///
  /// ⚠️ 这里**只带落点，不带任何尺寸上限**：用户 2026-10-11 第五次报
  /// 「播放器全屏不了 / 右边拉不大」的真因就是原来那对 `maxWidth/maxHeight`
  /// （子窗口侧 `setMaximumSize` → 原生 `ptMaxTrackSize`，它连 `SetWindowPos`
  /// 一起夹，而"真全屏"就是 `SetWindowPos` 到显示器尺寸）。详见
  /// `domain/window_placement.dart` 里删掉 `playerWindowMaxSize` 的那段注释。
  Future<Map<String, Object?>?> _nextBounds() async {
    final Future<PlayerWindowPlan?> Function()? place = placeWindow;
    if (place == null) return null;
    try {
      final PlayerWindowPlan? plan = await place();
      if (plan == null) return null;
      final Rect rect = plan.bounds;
      return <String, Object?>{
        'left': rect.left,
        'top': rect.top,
        'width': rect.width,
        'height': rect.height,
      };
    } catch (e) {
      // 算不出来不是致命错误：退回插件默认（居中），不阻塞播放。
      _log('播放窗口落点计算失败（退回默认居中）：$e');
      return null;
    }
  }

  /// 子窗口报告了几何：记住它（下次开窗就放回用户自己选的位置）。
  Future<void> _noteGeometry(Object? raw) async {
    final Rect? rect = decodeGeometry(raw);
    if (rect == null) return;
    if (rect.width < 1 || rect.height < 1) return;
    _log('子窗口几何：${rect.left.toStringAsFixed(0)},${rect.top.toStringAsFixed(0)} '
        '${rect.width.toStringAsFixed(0)}x${rect.height.toStringAsFixed(0)}');
    final Future<void> Function(Rect)? save = saveGeometry;
    if (save == null) return;
    try {
      await save(rect);
    } catch (e) {
      _log('记住窗口几何失败：$e');
    }
  }

  /// 子窗口点了播放列表里的某一集：交给宿主（补磁力 → 加种 → 投递播放请求）。
  Future<void> _onEpisodeSelect(Object? raw) async {
    if (raw is! String || raw.trim().isEmpty) {
      _log('播放列表选择请求没有条目 id（收到 $raw）');
      return;
    }
    final Future<void> Function(String)? handler = onEpisodeSelected;
    if (handler == null) {
      _log('播放列表选择没人接（装配根没接 onEpisodeSelected）：$raw');
      return;
    }
    _log('播放列表选择：$raw');
    try {
      await handler(raw);
    } catch (e) {
      _log('播放列表选择失败：$e');
    }
  }

  /// 子窗口报上来的播放进度：交给宿主记账（观看记录 + 自动打勾）。
  ///
  /// 解析放在宿主这一侧（与 `decodeGeometry` 同一口径：坏参数只是丢一条，
  /// 绝不能因为一条解析失败影响播放）。
  Future<void> _onWatchProgress(Object? raw) async {
    final ({int positionMs, int durationMs, String? path})? progress =
        decodeWatchProgress(raw);
    if (progress == null) return;
    final Future<void> Function(Object?)? handler = onWatchProgress;
    if (handler == null) return;
    try {
      await handler(<String, Object?>{
        'positionMs': progress.positionMs,
        'durationMs': progress.durationMs,
        if (progress.path != null) 'path': progress.path,
      });
    } catch (e) {
      _log('观看进度记账失败：$e');
    }
  }

  /// 推送环境（外观 / 剧集分组 / 播放器设置）。同值不重复推。
  ///
  /// ⚠️ **成功之后才记账**（第二十七轮复核指出的丢更新模式）：以前先把
  /// `_lastXxx` 改成新值、再 `invokeMethod`，一旦那次发送失败（典型场景：播放窗口刚建、
  /// 子窗口还没跑完 `setWindowMethodHandler` ⇒ `CHANNEL_UNREGISTERED`），
  /// 之后再推同一个值就会因"同值"**早退**，子窗口永远停在旧值上 ——
  /// 用户看到的就是"我改了设置，播放器没变"。现在失败不记账 + 退避重试（最多 3 次）。
  Future<void> pushArgs({
    Map<String, Object?>? tokens,
    Map<String, Object?>? episodeGroup,
    bool? wakeChromeAtCenter,
  }) async {
    final bool tokensSame = tokens == null || _mapEquals(tokens, _lastTokens);
    final bool groupSame = episodeGroup == null || _mapEquals(episodeGroup, _lastGroup);
    final bool wakeSame =
        wakeChromeAtCenter == null || wakeChromeAtCenter == _lastWakeChromeAtCenter;
    if (tokensSame && groupSame && wakeSame) return;
    final WindowController? c = _controller;
    if (c == null) {
      // 还没有窗口：记账即可（下次开窗由 `PlayerWindowArgs` 或 `replayEnv` 带上）。
      if (!tokensSame) _lastTokens = tokens;
      if (!groupSame) _lastGroup = episodeGroup;
      if (!wakeSame) _lastWakeChromeAtCenter = wakeChromeAtCenter;
      return;
    }
    try {
      await c.invokeMethod<void>(
        kMethodArgs,
        PlayerWindowArgs.envJson(
          tokens: tokensSame ? null : tokens,
          episodeGroup: groupSame ? null : episodeGroup,
          wakeChromeAtCenter: wakeSame ? null : wakeChromeAtCenter,
        ),
      );
      // 发送成功才记账（失败时"想要的值"仍与"已推的值"不同，下次还会推）。
      if (!tokensSame) _lastTokens = tokens;
      if (!groupSame) _lastGroup = episodeGroup;
      if (!wakeSame) _lastWakeChromeAtCenter = wakeChromeAtCenter;
      _envRetries = 0;
    } catch (e) {
      // 环境推送失败不该影响播放；退避重试几次（窗口刚建时子窗口的处理器还没注册好）。
      _log('推送环境失败：$e');
      if (_envRetries < 3) {
        _envRetries++;
        final int waitMs = 400 * _envRetries;
        unawaited(
          Future<void>.delayed(Duration(milliseconds: waitMs), () {
            unawaited(pushArgs(
              tokens: tokens,
              episodeGroup: episodeGroup,
              wakeChromeAtCenter: wakeChromeAtCenter,
            ));
          }),
        );
      }
    }
  }

  /// 子窗口点的「下一集/上一集」没起来：把原因**推回播放窗口**（第三十八轮）。
  ///
  /// 三条规矩：
  /// * 没有窗口（还没开过 / 已经被关掉）就是**空操作** —— 那时用户本来就在主窗口，
  ///   主窗口的失败横幅已经说清楚了；
  /// * 通道失败**不再重试**：这条是"锦上添花的提示"，不是状态同步，丢一条不该反复骚扰；
  /// * 与播放无关的调用方（内嵌播放 / 组件测试）拿到的是 `Unconfigured` 占位实例，
  ///   `_controller == null` ⇒ 同样空操作，所以**不需要**新的端口方法。
  Future<void> notifyEpisodeSwitchFailed({
    required String title,
    required String message,
    String? hint,
  }) async {
    final WindowController? c = _controller;
    if (c == null) return;
    try {
      await c.invokeMethod<void>(kMethodSwitchFailed, <String, Object?>{
        'title': title,
        'message': message,
        if (hint != null && hint.trim().isNotEmpty) 'hint': hint,
      });
    } catch (e) {
      _log('推送切集失败原因失败（不影响播放）：$e');
    }
  }

  /// 无条件重推已存的环境（窗口刚建好时补一次，防开窗那一刻的竞态）。
  Future<void> replayEnv() async {
    final Map<String, Object?>? tokens = _lastTokens;
    final Map<String, Object?>? group = _lastGroup;
    final bool? wake = _lastWakeChromeAtCenter;
    if (tokens == null && group == null && wake == null) return;
    final WindowController? c = _controller;
    if (c == null) return;
    try {
      await c.invokeMethod<void>(
        kMethodArgs,
        PlayerWindowArgs.envJson(tokens: tokens, episodeGroup: group, wakeChromeAtCenter: wake),
      );
    } catch (e) {
      _log('补推环境失败：$e');
    }
  }

  /// 转发一条控制指令（暂停/继续、跳转、停止）。
  Future<void> send(String method, [Object? args]) async {
    final WindowController? c = _controller;
    if (c == null) return;
    try {
      await c.invokeMethod<void>(method, args);
    } catch (e) {
      _log('$method 失败：$e');
    }
  }

  /// 「关闭播放窗口」= **收起来**（默认关闭语义，见 [kMethodHideSelf]）。
  ///
  /// 只发一条 [kMethodHideSelf]：子窗口停播 + `ShowWindow(SW_HIDE)` + 回发
  /// [kMethodChildHidden]。**不拆引擎**，所以不会有拆除期的崩溃/卡死；
  /// 下次播放直接复用这扇窗（`open()` 会让它 `show()` 出来），秒开。
  ///
  /// 子窗口没回应（通道不通 → 通常意味着这扇窗已经没了）时不假装收起来了：
  /// 查一次真实窗口列表，确实不在就把状态收干净，用户还能重新打开。
  Future<void> hide() async {
    final WindowController? c = _controller;
    if (c == null) return;
    try {
      await c.invokeMethod<void>(kMethodHideSelf);
      // 乐观置位：`kMethodChildHidden` 会再确认一次（重复置位是幂等的）。
      // 不乐观置位的话，子窗口那条回发一旦丢了，状态栏会一直显示"正在播放"。
      _markHidden();
    } catch (e) {
      _log('收起失败：$e');
      if (!await _windowExists(c.windowId)) _forget();
    }
  }

  /// **彻底关闭**播放窗口：让子窗口优雅收尾（停播 + 落盘）后真关这一扇窗，
  /// 连带拆掉它的引擎（内存还给它）。
  ///
  /// 只在两条路上用：① 用户在状态栏右键选「彻底关闭播放器」；
  /// ② 子窗口连停播都没回应（那就没必要留着它）。
  /// 正常「关闭播放器」请用 [hide] —— 这条路的拆除期有历史崩溃/卡死记录。
  ///
  /// 绝不能在这条链路上的任何地方调 `windowManager.destroy()` —— 它在本机
  /// window_manager 0.5.1 里就是 `PostQuitMessage(0)`，会把整个进程的主消息循环
  /// 干掉（用户 2026-10-10：「关闭播放器后为什么全关了」）。
  Future<void> destroy() async {
    final WindowController? c = _controller;
    if (c == null) return;
    try {
      await c.invokeMethod<void>(kMethodCloseSelf);
    } catch (e) {
      _log('关闭请求下发失败：$e');
    }
    final String windowId = c.windowId;
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!await _windowExists(windowId)) break;
    }
    if (!await _windowExists(windowId)) {
      // 窗口确实没了：把状态收干净（正常情况下 onWindowsChanged 已经收过一遍，
      // 这里只是兜底，重复置位是幂等的）。
      _forget();
    } else {
      _log('关闭请求已下发，但窗口 $windowId 仍在：保持"开着"状态');
    }
  }

  /// 状态：这扇窗还开着（可能有画面，也可能被收着），但不在播了。
  void _markHidden() {
    isOpen.value = true; // 窗口还在（隐藏 ≠ 销毁）
    isHidden.value = true;
    currentTitle.value = null;
    reportedTitle.value = null;
  }

  /// 状态：这扇窗真的没了。
  void _forget() {
    _controller = null;
    isOpen.value = false;
    isHidden.value = false;
    currentTitle.value = null;
    reportedTitle.value = null;
  }

  /// 这个 windowId 还在不在（插件侧的真实窗口列表）。
  Future<bool> _windowExists(String windowId) async {
    try {
      final List<WindowController> all = await WindowController.getAll();
      return all.any((WindowController w) => w.windowId == windowId);
    } catch (e) {
      _log('查询窗口列表失败：$e');
      return false; // 问不到就当它没了：状态回到"没开"，用户还能再点播放
    }
  }

  /// 监听窗口列表变化：用户在子窗口上点 ✕ 时把状态同步回来。
  void _watchWindowsChanged() {
    _windowsSub ??= onWindowsChanged.listen((_) async {
      final List<WindowController> all = await WindowController.getAll();
      final WindowController? mine = _controller;
      if (mine == null) return;
      final bool stillThere = all.any((WindowController w) => w.windowId == mine.windowId);
      if (!stillThere) _forget();
    });
  }

  Future<void> dispose() async {
    await _windowsSub?.cancel();
    _windowsSub = null;
    isHidden.dispose();
    currentTitle.dispose();
    isOpen.dispose();
    reportedTitle.dispose();
  }
}

/// 播放窗口的开关 / 标题 / 外观：主窗口 UI（状态栏那颗指示）只读这几个。
///
/// Riverpod 3 没有 `ChangeNotifierProvider`，所以用一个薄 [Notifier] 把
/// [PlayerWindowService] 的 `ValueNotifier` 接进来。
final Provider<bool> playerWindowIsOpenProvider = Provider<bool>(
  (Ref ref) => ref.watch(_isOpenProvider),
);

/// 播放窗口是不是**被收起来了**（还在，只是隐藏 + 已停播）。
final Provider<bool> playerWindowIsHiddenProvider = Provider<bool>(
  (Ref ref) => ref.watch(_isHiddenProvider),
);

/// 「正在播放」（窗口可见且在播/暂停着）：状态栏那颗按钮据此换图标。
final Provider<bool> playerWindowVisibleProvider = Provider<bool>(
  (Ref ref) => ref.watch(playerWindowIsOpenProvider) && !ref.watch(playerWindowIsHiddenProvider),
);

final Provider<String?> playerWindowTitleProvider = Provider<String?>(
  (Ref ref) => ref.watch(_titleProvider),
);

final NotifierProvider<_NotifierBridge<bool>, bool> _isOpenProvider =
    NotifierProvider<_NotifierBridge<bool>, bool>(
      () => _NotifierBridge<bool>((PlayerWindowService s) => s.isOpen),
    );

final NotifierProvider<_NotifierBridge<bool>, bool> _isHiddenProvider =
    NotifierProvider<_NotifierBridge<bool>, bool>(
      () => _NotifierBridge<bool>((PlayerWindowService s) => s.isHidden),
    );

final NotifierProvider<_NotifierBridge<String?>, String?> _titleProvider =
    NotifierProvider<_NotifierBridge<String?>, String?>(
      () => _NotifierBridge<String?>((PlayerWindowService s) => s.currentTitle),
    );

/// 把一个 `ValueNotifier` 暴露成 Riverpod 状态。
class _NotifierBridge<T> extends Notifier<T> {
  _NotifierBridge(this.pick);

  final ValueNotifier<T> Function(PlayerWindowService service) pick;

  late final PlayerWindowService _service = ref.read(playerWindowServiceProvider);
  late final ValueNotifier<T> _source = pick(_service);

  @override
  T build() {
    void listener() => state = _source.value;
    _source.addListener(listener);
    ref.onDispose(() => _source.removeListener(listener));
    return _source.value;
  }
}

/// 浅比较两个 JSON map（只用于"值没变就别推"，不需要深比较语义的严格性）。
bool _mapEquals(Map<String, Object?>? a, Map<String, Object?>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (final MapEntry<String, Object?> e in a.entries) {
    if (!b.containsKey(e.key)) return false;
    if (b[e.key] != e.value) return false;
  }
  return true;
}

/// 窗口几何（逻辑像素）→ 可 JSON 传输的 map（子窗口报几何用）。
Map<String, Object?> encodeGeometry(Rect rect) => <String, Object?>{
  'left': rect.left,
  'top': rect.top,
  'width': rect.width,
  'height': rect.height,
};

/// 子窗口报上来的几何 → [Rect]；字段缺失/类型不对返回 null（不猜）。
Rect? decodeGeometry(Object? raw) {
  if (raw is! Map) return null;
  double? value(Object? v) => v is num ? v.toDouble() : null;
  final double? left = value(raw['left']);
  final double? top = value(raw['top']);
  final double? width = value(raw['width']);
  final double? height = value(raw['height']);
  if (left == null || top == null || width == null || height == null) return null;
  return Rect.fromLTWH(left, top, width, height);
}

/// 子窗口报上来的播放进度 → `(positionMs, durationMs, path)`；字段缺失/类型不对返回 null。
///
/// 负数一律夹到 0（时长未知时子窗口报 0，不能拿它当"时长 0 秒"去算进度）。
/// [path] 是子窗口**当前真正在放**的那一条（串流 URL / 本地路径），可以为 null
/// （老版本子窗口）：宿主拿它把进度归到正确的那一集（同一 torrent 里子窗口会自己换集，
/// 不经过宿主，见 `NowPlaying.watchByUrl`）。
({int positionMs, int durationMs, String? path})? decodeWatchProgress(Object? raw) {
  if (raw is! Map) return null;
  final Object? pos = raw['positionMs'];
  final Object? dur = raw['durationMs'];
  if (pos is! num || dur is! num) return null;
  final String path = (raw['path'] ?? '').toString().trim();
  return (
    positionMs: pos.toInt() < 0 ? 0 : pos.toInt(),
    durationMs: dur.toInt() < 0 ? 0 : dur.toInt(),
    path: path.isEmpty ? null : path,
  );
}

/// 宿主归组结果 → 可 JSON 传输的分组（子窗口是独立 isolate，只能传值）。///
/// 每集的 `streamUrl` 由宿主填好（引擎的 per-file 地址只有主窗口拿得到），
/// 子窗口点上一集/下一集时直接用这个地址（决策 B31）。
Map<String, Object?>? encodeEpisodeGroup(EpisodeGrouping? group) {
  if (group == null || group.entries.length <= 1) return null;
  return <String, Object?>{
    'currentIndex': group.currentIndex,
    'items': <Map<String, Object?>>[
      for (final EpisodeEntry e in group.entries)
        <String, Object?>{
          'path': e.path,
          'title': e.title,
          // 真实集号（不是下标）：缺集时用下标当集号会撒谎（用户 2026-10-11
          // 「播放列表太小了看不到集数了」）。
          'episode': ?e.episode,
          if (e.streamUri != null) 'streamUrl': e.streamUri.toString(),
        },
    ],
  };
}

/// 当前进程是不是「播放子窗口」？
///
/// 主窗口调 `WindowController.fromCurrentEngine()` 会抛（`getWindowDefinition`
/// 只在子窗口引擎里有值），所以用 try/catch 判定 —— 这是插件的既有行为。
Future<PlayerWindowArgs?> detectPlayerWindowArgs() async {
  try {
    final WindowController c = await WindowController.fromCurrentEngine();
    return PlayerWindowArgs.decode(c.arguments);
  } catch (_) {
    return null;
  }
}
