import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../app.dart';
import '../controllers/player_controller.dart';
import '../controllers/anime4k_controller.dart';
import '../controllers/playlist_controller.dart';
import '../controllers/settings_controller.dart';
import '../infra/diagnostics/diag.dart';
import '../models/episode_switch_notice.dart';
import '../models/media_item.dart';
import '../models/picture_menu.dart';
import '../models/player_action.dart';
import '../models/player_keys.dart';
import '../models/player_request.dart';
import '../models/subtitle_style.dart';
import '../models/theme_tokens.dart';
import '../models/upscale_scheme.dart';

import 'picture_panel.dart';
import '../models/video_stats.dart';
import 'context_menu.dart';
import 'control_bar.dart';
import 'episode_panel.dart';
import 'open_surface.dart';
import 'settings_panel.dart';
import 'stats_overlay.dart';
import 'title_bar.dart';
import 'video_stage.dart';

// ── 鼠标热区（纯函数：判定与渲染解耦，测试不必起播放器/引擎）────────────────────

/// 热区相对两条栏往外多算的容差（逻辑像素）—— 默认 4 → **28**（第二十六轮）。
///
/// 用户这一轮的原话是两句：「鼠标在热区内就会保持显现，移走后淡出」+「鼠标不动时才隐藏」，
/// 澄清后选的是「整条栏 + 更大容差」。为什么必须把容差做大（而不是继续用 4）：
/// 控制栏的**可见高度**是 `controlHeight + spacing`（上下内边距），标题栏底下还压着
/// 1px 分隔线与视频区——鼠标压在栏边一两像素的地方，用户心里是"我还在栏上"，
/// 而判定只认那 4 像素就会判成"已经离开"，于是栏在他手底下开始淡出。
/// 现在上下各放宽 28px：贴着栏、在栏附近游走都算命中，两条栏稳稳保持显现。
///
/// ⚠️ 它**不是**"整个窗口"：画面中间仍然判不命中（用户第十四轮明确要改掉的就是
/// "鼠标在画面中间动一下也把两条栏叫出来"）。7 行的播放器窗口里，
/// 2×28 的容差不会把中带挤没（`player_chrome_hotzone_test` 有"中带必须存在且不命中"的用例）。
const double kChromeHotZoneSlack = 28;

/// 两条栏的自动隐藏延时（毫秒）：鼠标停住 / 移出窗口后多久淡出。
///
/// 第二十七轮：2000 → **1000**（用户：「播放器控制栏等淡出时间减少一秒」）。
/// 抽成顶层常量是为了**测试能钉住它**：第二十六轮那次独立审查发现
/// "把 28 悄悄改回 4 用例仍全绿"（期望值也用同一个常量），
/// 这里同理 —— 延时写成私有字段时，只有"跑满 1 秒"这种不可观测的用例能守它。
const int kChromeAutoHideMs = 1000;

/// 鼠标是否落在「顶部标题栏热区」或「底部控制栏热区」内。
///
/// 用户 2026-10-12 第十四轮：「修改播放器逻辑，鼠标移动到标题栏/控制栏时才会显现」——
/// 澄清后的语义是**只有**鼠标进入这两条热区才唤起 chrome；在画面中间移动不再唤起
/// （旧实现是整个窗口一个 `MouseRegion`，任何位置动一下都会 `_pokeControls()`）。
///
/// 写成只吃 `Offset`/`Size` 的顶层纯函数（而不是藏在 State 里），是为了让
/// `test/widgets/player_chrome_hotzone_test.dart` **不起引擎、不起解码器**就能钉住
/// 边界（0 尺寸、正好压线、slack 容差）。它也正是 `onHover` 唯一调用的判定。
///
/// - [local]：指针在播放面内的局部坐标（`PointerHoverEvent.localPosition`）。
/// - [size]：播放面尺寸。**宽或高 ≤ 0 一律不命中**：窗口最小化/首帧未布局时是
///   `Size.zero`，而 `dy >= height - bottomHeight` 在 `height == 0` 时对**任何**
///   坐标都成立 ⇒ 鼠标一进中间就会被误判成"在底部控制栏上"、两条栏反复唤起。
/// - [topHeight] / [bottomHeight]：两条热区的高度（标题栏 / 控制栏）。
/// - [slack]：容差（默认 [kChromeHotZoneSlack]，做成参数而不是魔法数）。热区与真实栏
///   之间有几像素的过渡带（控制栏的可见高度其实是 `controlHeight + spacing` 的上下
///   内边距），给一点容差让贴着栏边缘的鼠标也算命中；测试里传 `slack: 0` 钉严格边界。
///
/// 纯几何判定：**不读任何状态**，所以"要不要真的显示"不在这里决定 ——
/// 见 [playerChromeMoveEffect] 与 `_PlayerSurfaceState._applyChromeEffect`。
bool playerChromeHotZoneHit(
  Offset local,
  Size size, {
  required double topHeight,
  required double bottomHeight,
  double slack = kChromeHotZoneSlack,
}) {
  // 0 尺寸（或负尺寸）窗口：判据会全体失真，直接判否。
  if (size.width <= 0 || size.height <= 0) return false;
  // 横向必须真的在窗口内：指针从左右外侧掠过时 localPosition 会越界，
  // 不判这一条的话「窗口外的正上方」也会被算成顶部热区。
  if (local.dx < 0 || local.dx > size.width) return false;
  if (local.dy <= topHeight + slack) return true;
  if (local.dy >= size.height - bottomHeight - slack) return true;
  return false;
}

/// 浮层（播放列表 / 设置）打开时，鼠标在播放面里**一律**算命中。
///
/// 理由：播放列表 / 设置面板是前景交互，鼠标在列表里移动却不给两条栏续命的话，
/// 1 秒后连光标都会在列表的空白处消失（列表行自己带 `click` 光标，行与行之间的
/// 内边距可没有）。只要求"命不命中"的调用方用这个（几何判定 + 浮层例外）。
bool playerChromeRevealHit(
  Offset local,
  Size size, {
  required bool overlayOpen,
  required double topHeight,
  required double bottomHeight,
  double slack = kChromeHotZoneSlack,
}) =>
    overlayOpen ||
    playerChromeHotZoneHit(
      local,
      size,
      topHeight: topHeight,
      bottomHeight: bottomHeight,
      slack: slack,
    );

/// 一次鼠标移动（或移出窗口）之后，两条栏该做什么。
///
/// **第二十六轮重构**：用户这一轮把 chrome 的显隐规则讲成了两句
/// 「鼠标在热区内就会保持显现，移走后淡出」+「鼠标不动时才隐藏」。
/// 于是规则从"只有进/出热区那两个**状态转换**才有动作"改成**按位置分三种结果**：
///
/// * [PlayerChromeMoveEffect.reveal] —— 指针在热区（或浮层开着）：**立即显示**两条栏，
///   并把 1 秒隐藏计时**重新开始**。指针停在栏上、在栏附近慢慢磨，都不会淡出
///   （`onHover` 只在指针**真的动**时才触发，停住不动才让计时跑到头）；
/// * [PlayerChromeMoveEffect.restart] —— 指针在窗口里、但在画面中间：**不显示**
///   （第十四轮的语义不变：画面中间不许把栏叫出来），只把计时**重新开始**。
///   这条就是「鼠标不动时才隐藏」：人还在窗口里动来动去，两条栏不该在他动的时候
///   消失；一停下来（`onHover` 不再触发）计时跑满 1 秒 → 淡出。
/// * [PlayerChromeMoveEffect.scheduleHide] —— 指针**移出了窗口**：不显示，只排定
///   1 秒后淡出（不立刻消失）。
///
/// 为什么要三个值而不是旧实现那种「命中/未命中 + 上一次是否命中」两值状态机：
/// 旧机器里"一直在画面中间动"是 [PlayerChromeMoveEffect.ignore]（**什么都不做**，
/// 连已有的隐藏计时都不给续命）—— 那正是用户这一轮要改掉的手感：在窗口里动着动着，
/// 两条栏会在半途自己淡掉。
enum PlayerChromeMoveEffect {
  /// 进（或仍在）热区 / 浮层开着：立即显示两条栏，并重新开始 1 秒隐藏计时。
  reveal,

  /// 在窗口里、但不在热区：不显示，只重新开始 1 秒隐藏计时（"鼠标不动时才隐藏"）。
  restart,

  /// 指针移出窗口：排定 1 秒后淡出（不是立刻消失）。
  scheduleHide,

  /// 什么都不做（拿不到尺寸、几何判据失真时宁可不动，也不误唤醒）。
  ignore,
}

/// 指针这一次的位置（[local] / [size] / [inWindow]）→ 两条栏该做什么。
///
/// 纯状态机，无副作用；调用方（`_applyChromeEffect`）负责把结果落到 `_controlsVisible`
/// 与 `_hideTimer` 上。**不读 `wasHit`**：第二十六轮之后每个位置都有明确动作
/// （见 [PlayerChromeMoveEffect]），不再需要记住"上一次在不在热区里"。
///
/// [revealCenter]（第二十七轮）：宿主设置里可以关掉"画面正中不唤起"这条规则 ——
/// 打开后窗口里**任何**位置动一下都算 [PlayerChromeMoveEffect.reveal]
/// （用户：「画面正中仍不唤起逻辑可在设置中关闭」）。默认 false = 第十四/二十六轮的语义。
PlayerChromeMoveEffect playerChromeMoveEffect(
  Offset local,
  Size size, {
  required bool inWindow,
  required bool overlayOpen,
  required double topHeight,
  required double bottomHeight,
  double slack = kChromeHotZoneSlack,
  bool revealCenter = false,
}) {
  // 拿不到尺寸（未布局 / renderObject 非 RenderBox）：判据失真，什么都不做。
  if (size.width <= 0 || size.height <= 0) return PlayerChromeMoveEffect.ignore;
  if (!inWindow) return PlayerChromeMoveEffect.scheduleHide;
  if (revealCenter) return PlayerChromeMoveEffect.reveal;
  if (playerChromeRevealHit(
    local,
    size,
    overlayOpen: overlayOpen,
    topHeight: topHeight,
    bottomHeight: bottomHeight,
    slack: slack,
  )) {
    return PlayerChromeMoveEffect.reveal;
  }
  return PlayerChromeMoveEffect.restart;
}

/// 1 秒计时跑到头了，这次到底该不该真把两条栏藏起来？

///
/// 纯函数（无副作用、不读 State），[PlayerSurface] 的 [_restartChromeHideTimer] 在
/// 计时器回调里读它。为什么单抽而不是在回调里写 `&&`：
///
/// * **[pointerInHotZone] 是这一条的关键**：`onHover` 只在指针**移动**时触发，
///   「鼠标停在标题栏/控制栏上不动」这段静止时间里一条事件都不会来，只有计时器会到点 ——
///   光看"计时跑满"就会把**还压在栏上的指针**判成"停住了"，两条栏在用户手底下淡出；
///   而淡出的标题栏**仍然可点**（✕ / 最大化 / 拖拽区都在），光标还会变成 `none`（能误触）。
///   所以指针在热区里一律不隐藏（用户原话：「鼠标在热区内就会保持显现」）。
/// * [overlayOpen]：设置浮层打开时挂起（浮层关闭的每条路径都会重新武装计时器）。
/// * [hasMedia]：空态 chrome 常驻，本来就不该有隐藏计时。
///
/// 抽出来是为了让"压在栏上不许消失"这条**能在测试里逐例钉住**
///（`player_chrome_hotzone_test.dart`）—— widget 级的 `PlayerSurface` 一起解码器就
/// 没法在测试里 build（见那个文件顶部的说明），这条规则只能这样守。
bool playerChromeShouldHide({
  required bool hasMedia,
  required bool overlayOpen,
  required bool pointerInHotZone,
}) {
  if (!hasMedia) return false;
  if (overlayOpen) return false;
  if (pointerInHotZone) return false;
  return true;
}

/// 切集反馈层该显示什么（第三十八轮）。
///
/// 用户原话：「优化反馈，点击下一集或上一集都没实质性反馈」。跨种子切集点下去要等
/// 「补磁力 → `addMagnet` 等元数据」，慢的时候几十秒到两分钟 —— 这一层就是那段等待与
/// 它的结局。**抽成纯函数**的理由与 [playerChromeShouldHide] 一样：`PlayerSurface`
/// 在本仓测试里挂不起来（一 build 到 `VideoStage` 就要 media_kit 的原生纹理），
/// 规则只能钉在能测的这一层（`player_switch_feedback_test.dart`）。
@immutable
class PlayerSwitchFeedback {
  const PlayerSwitchFeedback({
    this.pendingTitle,
    this.error,
    this.hint,
    this.waitedSeconds = 0,
  });

  /// 正在等的那一集的标题（非空 = 显示「正在切到《X》」）。
  final String? pendingTitle;

  /// 失败原因（非空 = 显示失败与「怎么办」）。
  final String? error;

  /// 「怎么办」（可空）。
  final String? hint;

  /// 已经等了多久（等待文案要把秒数说出来：数字在动才叫有反馈）。
  final int waitedSeconds;

  /// 这一层要不要出现。
  bool get visible => pendingTitle != null || error != null;

  @override
  bool operator ==(Object other) =>
      other is PlayerSwitchFeedback &&
      other.pendingTitle == pendingTitle &&
      other.error == error &&
      other.hint == hint &&
      other.waitedSeconds == waitedSeconds;

  @override
  int get hashCode => Object.hash(pendingTitle, error, hint, waitedSeconds);

  @override
  String toString() =>
      'PlayerSwitchFeedback(pending: $pendingTitle, error: $error, waited: ${waitedSeconds}s)';
}

/// 由「播放面本地状态 + 宿主推来的通知」算出切集反馈层该显示什么（纯函数）。
///
/// 优先级（这是本轮唯一的规则，测试逐条钉住）：
/// 1. **本地失败**（`_openMedia` 自己抛错）> **宿主推来的失败**（`switchNoticeProvider`）
///    > **等待**；
/// 2. 已经按 ✕ 关掉的那一条通知（[dismissed]）不再显示 —— 但宿主再推**另一条**
///    （对象不同）时照常显示；
/// 3. 什么都没发生时 `visible == false`（不占屏）。
PlayerSwitchFeedback playerSwitchFeedback({
  required String? pendingTitle,
  required DateTime? startedAt,
  required String? localError,
  required String? localHint,
  required EpisodeSwitchNotice? notice,
  required EpisodeSwitchNotice? dismissed,
  required DateTime now,
}) {
  final bool noticeFresh = notice != null && notice != dismissed;
  final String? error = localError ?? (noticeFresh ? notice.message : null);
  if (error != null) {
    return PlayerSwitchFeedback(
      error: error,
      hint: localError != null ? localHint : notice?.hint,
    );
  }
  if (pendingTitle == null) return const PlayerSwitchFeedback();
  final int waited = startedAt == null
      ? 0
      : now.difference(startedAt).inSeconds.clamp(0, 86400);
  return PlayerSwitchFeedback(pendingTitle: pendingTitle, waitedSeconds: waited);
}

/// 等待中的那句话（把秒数说出来）。
///
/// 8 秒是分界：mikan 补磁力通常在 1 秒内回来，剩下的时间都在等引擎的元数据，
/// 超过 8 秒就该解释一句"为什么还没好"，否则用户会以为程序卡死了。
String playerSwitchWaitingText(int waitedSeconds) => waitedSeconds >= 8
    ? '已经等了 $waitedSeconds 秒。跨种子切集要先补磁力、再等引擎拿到元数据，'
        '慢的时候要几十秒到两分钟 —— 引擎那边还在跑，不用重复点。'
    : '正在补磁力 / 等引擎元数据（已等 $waitedSeconds 秒）';

/// 内置播放面（取代旧 AppShell，1713 行 → 一个文件）。
///
/// 职责：消费宿主投递的播放请求、换片超分接线、续播读写、写死键位（含长按连发）、
/// 控制栏/标题栏自动隐藏、右键菜单（契约 §7）、全屏/PiP/置顶、视频数据浮层。
///
/// **宿主必须把本控件常驻挂载**（例如 `IndexedStack` 保活），且给它非 0 尺寸：
/// ① 0 尺寸 ⇒ libmpv `Failed to create EGL surface`，不能用 `Offstage`；
/// ② 宿主投递请求与本控件挂载同帧相撞会起播失败（契约 §5 第 1/2 条）。
///
/// 播放器**不扫盘、不自己开文件**：点上一集/下一集也交回宿主的
/// `playerRequestProvider.request(...)`（契约 §9）。
class PlayerSurface extends ConsumerStatefulWidget {
  const PlayerSurface({
    super.key,
    this.maximizeTogglesFullscreen = false,
    this.wakeChromeAtCenter = false,
  });

  /// 鼠标移到**画面正中**也唤起两条栏（宿主设置项，默认关）。
  ///
  /// 第二十七轮：用户「画面正中仍不唤起逻辑可在设置中关闭」—— 关着时保持第十四轮
  /// 「只有上下热区能唤起」的语义；打开后窗口里任何位置动一下都显示（见
  /// [playerChromeMoveEffect] 的 `revealCenter`）。
  final bool wakeChromeAtCenter;

  /// 标题栏的最大化键 / 双击标题栏：true = **切全屏**而不是原生最大化。
  ///
  /// 多窗口宿主（DSAnima 的弹出播放窗口）传 true：无边框弹窗被原生最大化会铺满整屏、
  /// 把主窗口 100% 盖住（用户 2026-10-11「开启播放器后整个程序都不能用了，
  /// 什么都点不了整个 DSAnime」）。全屏是用户显式动作，Esc / 双击画面随时能退。
  final bool maximizeTogglesFullscreen;

  @override
  ConsumerState<PlayerSurface> createState() => _PlayerSurfaceState();
}

/// 播放器自己的设置读写（内部实现细节，不进 barrel；宿主有自己的设置系统）。
final _settingsProvider = Provider<SettingsController>(
  (ref) => SettingsController(ref.read(storeProvider)),
);

class _PlayerSurfaceState extends ConsumerState<PlayerSurface> {
  /// 原生 IME 开关（windows/runner 的 `shikiin/ime` 通道）：文本框聚焦时启用，
  /// 离开则禁用，保证中文可输入且快捷键不被输入法吞。
  static const MethodChannel _imeChannel = MethodChannel('shikiin/ime');

  /// 载入媒体后控制栏/标题栏的自动隐藏延时（契约 §8）。
  ///
  /// ⚠️ 第二十七轮：2000 → **1000**（用户：「播放器控制栏等淡出时间减少一秒」）。
  /// 值在 [kChromeAutoHideMs]（顶层公开常量，测试钉着它）。
  static const int _autoHideMs = kChromeAutoHideMs;

  static const Duration _fade = Duration(milliseconds: 180);

  late final SettingsController _settings = ref.read(_settingsProvider);
  final FocusNode _focusNode = FocusNode();

  StreamSubscription<Duration>? _posSub, _durSub;
  StreamSubscription<bool>? _playSub;
  StreamSubscription<double>? _volSub;

  PlayerRequestNotifier? _playerReq;
  PlayerRequest? _lastPlayerRequest;

  /// 播放器替宿主转发「上一集/下一集」时的 nonce（同一 URL 重开也要算新请求）。
  int _requestNonce = 0;

  bool _hasMedia = false;
  bool _playing = false;
  bool _controlsVisible = true;
  Timer? _hideTimer;

  /// 指针现在是否压在上下热区里（第二十六轮）。
  ///
  /// 为什么必须有它：`onHover` 只在指针**移动**时触发 —— 「鼠标停在栏上不动」这段
  /// 静止时间里一条事件都不会来，只有计时器会到点。没有这个标志的话，"计时跑满
  /// 1 秒"就等于"鼠标停住了"，于是**指针压着控制栏也会被判成停住**、两条栏消失。
  /// 见 [_restartChromeHideTimer] 与 [_setPointerInHotZone]。
  bool _pointerInHotZone = false;

  bool _barDragging = false; // 进度条/音量条拖动中（挂起自动隐藏）
  Duration _position = Duration.zero, _duration = Duration.zero;
  double _volume = 100;
  String? _currentPath;
  String? _nowPlaying;
  bool _rememberPosition = true;

  // 窗口状态
  bool _fullscreen = false;
  bool _alwaysOnTop = false;
  bool _pip = false;
  Size? _prePipSize;

  // 设置浮层
  bool _settingsOpen = false;

  /// 播放列表浮层（用户 2026-10-11：「我要的播放列表为什么没有」）。
  bool _playlistOpen = false;

  /// 用户拖出来的播放列表宽度（逻辑像素）。
  ///
  /// 用户 2026-10-11 第六轮：「播放列表改成可托大的，有些视频太长了」——
  /// 拖拽发生在 [EpisodePanel] 内部（它知道可用宽度），这里只**记住**结果，
  /// 关掉再打开时保持用户拖的宽度，不会每次弹回默认值。
  double? _playlistWidth;

  // 视频数据浮层（Tab）
  bool _statsVisible = false;
  VideoStats? _stats;
  Timer? _statsTimer;
  bool _statsBusy = false; // 上一次快照未完成时跳过本 tick

  // 长按连续触发：逻辑键 → 定时器
  final Map<LogicalKeyboardKey, Timer> _holdTimers = {};

  // 换片串行化（防 media_kit 原生崩溃）
  bool _opening = false;

  /// 排队中的下一次 open（含它自己的续播起点 —— 丢掉 startAt 会让"连着点两集"
  /// 的第二集从 0 开始，正是续播那条 bug 的翻版）。
  ({MediaItem item, Duration? startAt})? _pendingOpen;

  // ── 切集反馈（第三十八轮）──────────────────────────────────────────────────
  //
  // 用户原话：「优化反馈，点击下一集或上一集都没实质性反馈」。跨种子的播放列表里，
  // 其它集还没进引擎：点下去要等「补磁力 → addMagnet 等元数据」，慢的时候几十秒，
  // 而这段时间画面上什么都不发生。所以点下去**立刻**亮这一层，直到：
  // * 新画面起来（`_openMedia` 成功）→ 收掉；
  // * 宿主把失败原因推过来（`switchNoticeProvider`）→ 换成原因；
  // * `_openMedia` 自己抛错 → 也换成原因（以前这里只写日志，点了同样"没反应"）。
  String? _switchPendingTitle;
  DateTime? _switchStartedAt;
  Timer? _switchTicker;
  String? _switchError;
  String? _switchErrorHint;
  /// 已经按 ✕ 关掉的那条宿主通知（同一条不再重复弹）。
  EpisodeSwitchNotice? _dismissedNotice;

  // 音量落盘防抖（滑块 onChanged 每像素一发，不能直接写盘）
  Timer? _volumeSaveTimer;

  bool _imeEnabled = false;

  @override
  void initState() {
    super.initState();
    // 播放器实例由宿主 `bootstrapPlayer()` 造好、经 `shikiinOverrides` 注入。
    // 未注入时（widget 测试里常发生）**不要读取** —— 读了会抛
    // `UnimplementedError` 并把整个播放页炸掉；此时只渲染不透明占位面。
    //
    // ⚠️ 这里**不能用 `ref.exists(playerProvider)`**：Riverpod 3 里 `exists` 对
    // `overrideWithValue` 注入的 provider 会返回 false（实测：真实运行时
    // `exists(player)==false` 而 `read(player)` 正常拿到实例），用它判断会走进
    // "未注入"分支 ⇒ 弹出播放窗口永远停在空态。改成 try/catch。
    PlayerController? injected;
    try {
      injected = ref.read(playerProvider);
    } catch (_) {
      injected = null;
    }
    if (injected == null) return;
    final PlayerController player = injected;
    final saved = _settings.loadSettings();
    _rememberPosition = saved.rememberPosition;

    _posSub = player.player.stream.position.listen(_onPosition);
    _durSub = player.player.stream.duration.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _playSub = player.player.stream.playing.listen((b) {
      if (!mounted) return;
      setState(() => _playing = b);
      _pokeControls(); // 播放/暂停都重新计时（暂停也可隐藏，便于截图）
    });
    _volSub = player.player.stream.volume.listen((v) {
      if (mounted) setState(() => _volume = v);
    });

    // 启动设置：音量 + 字幕样式（超分档位由 bootstrap 按持久化值恢复）。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await player.setVolume(saved.volume);
      await player.applySubtitleStyle(saved.subtitleStyle);
      if (mounted) setState(() {});
    });

    // 宿主通过 playerRequestProvider 投递播放请求（含 HTTP 串流 URL）。
    _playerReq = ref.read(playerRequestProvider);
    _playerReq?.addListener(_onPlayerRequest);

    // 宿主可能在与挂载同一帧投递了请求：补消费一次（契约 §5 第 2 条）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      final req = _playerReq?.value;
      if (req != null && req != _lastPlayerRequest) {
        unawaited(_openPlayerRequest(req));
      }
    });

    FocusManager.instance.addListener(_syncIme);
  }

  @override
  void dispose() {
    _playerReq?.removeListener(_onPlayerRequest);
    _posSub?.cancel();
    _durSub?.cancel();
    _playSub?.cancel();
    _volSub?.cancel();
    _hideTimer?.cancel();
    _statsTimer?.cancel();
    _volumeSaveTimer?.cancel();
    _switchTicker?.cancel();
    _stopAllHolds();
    FocusManager.instance.removeListener(_syncIme);
    _focusNode.dispose();
    // 页面销毁时把当前位置落盘（宿主另有关闭协调器负责退出前的强制保存）。
    final path = _currentPath;
    if (path != null && _rememberPosition) {
      unawaited(_settings.saveResume(path, _position, force: true));
    }
    super.dispose();
  }

  // ── 播放请求 ────────────────────────────────────────────────────────────────

  void _onPlayerRequest() {
    final req = _playerReq?.value;
    if (req == null || req == _lastPlayerRequest || !mounted) return;
    _lastPlayerRequest = req;
    unawaited(_openPlayerRequest(req));
  }

  Future<void> _openPlayerRequest(PlayerRequest req) async {
    _lastPlayerRequest = req;
    if (!mounted) return;
    await diag.breadcrumbFlushed('open request: ${req.uri}');
    // ⚠️ 起点**交给 `_openMedia` 一起带下去**，不要在这之后自己再 seek 一次：
    // 原来是 `open` 完立刻 `seekTo(startAt)`，而那时 mpv 还没把文件 load 起来，
    // seek 直接被丢弃（画面从 0 开始）。现在由 `PlayerController.open` 等
    // 「duration 有值」之后再 seek（见那里的长注释 / 真机日志 2026-10-18 17:22:20）。
    await _openMedia(
      MediaItem(path: req.uri, title: req.title),
      startAt: req.startAt,
    );
    if (!mounted) return;
    final sub = req.subtitlePath;
    if (sub != null && sub.isNotEmpty && mounted) {
      // 宿主已经把外挂字幕取到本地：直接挂上（失败不打断播放，自己去菜单里选）。
      try {
        await ref.read(playerProvider).addExternalSubtitle(sub);
      } catch (e) {
        diag.error('player_surface', 'addExternalSubtitle failed: $sub', e, null);
      }
    }
  }

  /// 打开一项媒体。
  ///
  /// 换片超分接线**照搬旧 AppShell（真机验证过的防崩路径，勿"简化"）**：
  /// `enterSwitchWindow` → `clearForSwitch` → `open` → 等 `nextVideoReconfig`
  /// + 1500ms → `exitSwitchWindow(reapply: true)`。
  /// 串行化 open：上一个 open 还在进行（纹理创建中）时再次 open 会触发 media_kit
  /// 在 Windows 上的原生崩溃，故打开请求排队、最新请求胜出。
  Future<void> _openMedia(MediaItem item, {Duration? startAt}) async {
    if (_opening) {
      _pendingOpen = (item: item, startAt: startAt);
      return;
    }
    _opening = true;
    await diag.breadcrumbFlushed('open: ${item.path}');
    final player = ref.read(playerProvider);
    final a4k = ref.read(anime4kProvider);
    int? switchToken;
    try {
      // 起点：宿主显式给的（续播/继续播放）优先，其次才是子窗口自己按 URL 记的那份
      // （URL 带 token，换一次就 miss，只能当兜底）。
      final Duration? hostStart =
          (startAt != null && startAt > Duration.zero) ? startAt : null;
      final Duration? resume = hostStart ??
          (_rememberPosition ? _settings.loadResume(item.path) : null);
      // 换片闪退修复：超分 glsl-shaders `set` 撞上新文件视频输出(VO)重建，会与 GPU
      // 渲染上下文竞争 → libmpv 原生崩溃（关超分只发 clr 故不崩）。复刻用户实测安全的
      // 「先关超分→换片→再开超分」：换片前先清，open 后等 VO 就绪再把档位 set 回去。
      // 保护窗口对**每次换片**都开启：期间用户在右键菜单手动切档的 set 同样会撞
      // 重建，由控制器统一记账延后，出窗口按最新档位补发。
      switchToken = a4k.enterSwitchWindow();
      final reconfig = player.nextVideoReconfig(); // 必须在 open 前订阅，避免漏掉重配置事件
      if (a4k.hasShaders) await a4k.clearForSwitch();
      await player.open(item, startAt: resume);
      final token = switchToken;
      unawaited(reconfig.then((ready) async {
        // videoParams(w>0) 只代表解码器已知尺寸(开片 ~70ms)，此时 GPU 渲染面/交换链
        // 仍在重建，下发 set 会撞重建 → 崩(实测 72ms 下发仍崩)。再等一段让重建彻底
        // 完成，把 set 放到稳定 VO 上——复刻用户实测安全的「换片后等一会再开超分」。
        if (ready) await Future.delayed(const Duration(milliseconds: 1500));
        // 期间再次换片(currentPath 已变)则由新窗口接管，旧票据自然失效。
        if (player.currentPath != item.path) return;
        // 无视频轨/超时(!ready)：VO 状态未知，不冒险补发 set，只解除窗口。
        await a4k.exitSwitchWindow(token, reapply: ready);
      }));
      if (mounted) {
        setState(() {
          _hasMedia = true;
          _currentPath = item.path;
          _nowPlaying = item.title;
        });
        // 第三十八轮：画面起来了 ⇒ 等待/失败那一层收掉（切集成功就是"有反馈"）。
        _endEpisodeSwitch();
        _pokeControls();
        _focusNode.requestFocus(); // 打开后抢回焦点，保证快捷键可用
      }
    } catch (e, st) {
      diag.error('player_surface', 'openMedia failed: ${item.path}', e, st);
      // 第三十八轮：打开失败**要说出来**。以前这里只写日志 —— 用户点「下一集」
      // 看到的就是"点了没反应"（反馈缺口的另一半，见 _showSwitchError）。
      _showSwitchError(
        '打不开这一集：$e',
        hint: '串流地址可能已失效（引擎重启过 / 该分片还没下到）；'
            '可以按 ✕ 关掉这一层，回主窗口重新点一集。',
      );
      // open 失败：解除保护窗口但不补发（VO 状态未知）；不解除会把后续切档一直押到超时。
      if (switchToken != null) await a4k.exitSwitchWindow(switchToken, reapply: false);
    } finally {
      _opening = false;
    }
    final next = _pendingOpen;
    _pendingOpen = null;
    if (next != null) await _openMedia(next.item, startAt: next.startAt);
  }

  // ── 上一集 / 下一集（契约 §9：交回宿主，不自己 open）─────────────────────────

  void _playEpisode(MediaItem item) {
    final uri = item.streamUrl?.toString();
    // 跨种子的播放列表（宿主按「同名同压制组」组出来的）：其它集还是**别的种子**、
    // 还没进引擎，所以没有 streamUrl —— 子窗口自己拿不到地址，只能把"用户点了哪一项"
    // 交回宿主（用户 2026-10-11：「我要的播放列表为什么没有」）。
    if (uri == null) {
      final select = ref.read(episodeSelectProvider);
      if (select != null) {
        // 第三十八轮：交回宿主之后**要等**（补磁力 + 等元数据），先把等待亮出来，
        // 否则用户看到的是一颗按下去毫无反应的按钮。
        _beginEpisodeSwitch(item.title);
        select(item);
        return;
      }
    }
    final target = uri ?? item.path;
    final channel = ref.read(playerRequestProvider);
    if (channel != null) {
      // 走宿主那条唯一开播链路（PlayerPort.open → PlayerRequestNotifier），
      // 避免两边各自 open 造成双开。
      channel.request(PlayerRequest(uri: target, title: item.title, nonce: ++_requestNonce));
      return;
    }
    // 没有宿主请求通道（纯独立用法）：直接开。播放器只播这一条，不会双开。
    unawaited(_openMedia(MediaItem(path: target, title: item.title, streamUrl: item.streamUrl)));
  }

  /// 开始等宿主把「这一集」准备好（跨种子切集，第三十八轮）。
  ///
  /// 一秒一刷：等待秒数要**动**，用户才知道程序还活着（这正是本轮要的"实质性反馈"）。
  void _beginEpisodeSwitch(String title) {
    _switchTicker?.cancel();
    setState(() {
      _switchPendingTitle = title;
      _switchStartedAt = DateTime.now();
      _switchError = null;
      _switchErrorHint = null;
    });
    _switchTicker = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted || _switchPendingTitle == null) {
        timer.cancel();
        return;
      }
      setState(() {}); // 只为把"已经等了 N 秒"刷新出来
    });
  }

  /// 新画面起来了（或用户按 ✕）：把等待层收掉。
  void _endEpisodeSwitch() {
    _switchTicker?.cancel();
    _switchTicker = null;
    if (_switchPendingTitle == null && _switchError == null) return;
    setState(() {
      _switchPendingTitle = null;
      _switchStartedAt = null;
      _switchError = null;
      _switchErrorHint = null;
    });
  }

  /// 这一次切集失败了：把原因顶在画面上（本地打开失败与宿主推来的失败共用这一条）。
  void _showSwitchError(String message, {String? hint}) {
    _switchTicker?.cancel();
    _switchTicker = null;
    if (!mounted) return;
    setState(() {
      _switchPendingTitle = null;
      _switchStartedAt = null;
      _switchError = message;
      _switchErrorHint = hint;
    });
  }

  void _nextEpisode() {
    final group = ref.read(episodeGroupProvider);
    final next = group?.next;
    if (next != null) _playEpisode(next);
  }

  void _previousEpisode() {
    final group = ref.read(episodeGroupProvider);
    final previous = group?.previous;
    if (previous != null) _playEpisode(previous);
  }

  // ── 续播 ────────────────────────────────────────────────────────────────────

  void _onPosition(Duration d) {
    if (!mounted) return;
    setState(() => _position = d);
    final path = _currentPath;
    if (path != null && _hasMedia && _rememberPosition) {
      // 节流在 SettingsController 内部（同 key 5s 内只写一次）。
      unawaited(_settings.saveResume(path, d));
    }
  }

  void _saveResumeNow(Duration d) {
    final path = _currentPath;
    if (path == null || !_rememberPosition) return;
    unawaited(_settings.saveResume(path, d, force: true));
  }

  // ── 控制栏 / 标题栏显隐 ─────────────────────────────────────────────────────

  /// 显示两条栏并重新开始 1 秒隐藏计时（契约 §8）。
  ///
  /// ⚠️ **鼠标**移动不直接调它：那条路先过热区判定，只有命中标题栏/控制栏热区才会
  /// 走到这里（见 [_onChromeHover] / [_applyChromeEffect]）。本方法是
  /// **键盘与程序性**唤起的入口，调用方保持原样：
  /// 播放/暂停事件流（`_playSub`）、`TitleBar.onPoke`（指针按下时，本身就在热区里）、
  /// [_openMedia] 之后、[_toggleSettings] 关闭时、[_setBarDragging] 拖动结束后。
  void _pokeControls() {
    if (!_controlsVisible && mounted) setState(() => _controlsVisible = true);
    _restartChromeHideTimer();
  }

  /// 只把「1 秒后淡出」的计时重新开始（不改变当前可见性）。
  ///
  /// 第二十六轮抽出来：`onHover` 现在有两种"动一下就续命"的结果 —— 热区里是
  /// [_pokeControls]（显示 + 续命），画面中间是**只续命不显示**（用户这一轮的原话
  /// 「鼠标不动时才隐藏」：人还在窗口里动，两条栏不该在他动的时候自己淡掉）。
  /// 两条路都要走的"取消旧计时 + 排定新计时 + 挂起语义"就收在这里，别各写一份。
  void _restartChromeHideTimer() {
    _hideTimer?.cancel();
    // 拖动进度条/音量条期间不排定隐藏：拖拽被指针按下捕获，期间不会有 onHover，
    // 若照常计时，控制条会在拖动中途消失；松手后 _setBarDragging(false) 重新计时。
    if (_barDragging || _settingsOpen) return;
    // 只要载入了媒体就排定隐藏（不论播放/暂停），方便干净截图。
    if (_hasMedia) {
      _hideTimer = Timer(const Duration(milliseconds: _autoHideMs), () {
        // ⚠️ **指针还压在热区里就绝不隐藏**（第二十六轮自查修掉的一处缺陷，规则见
        // [playerChromeShouldHide]）：`onHover` 只在指针**移动**时触发，所以"停在
        // 标题栏/控制栏上不动"这段静止时间里一条 hover 都不会来、计时照样跑到头；
        // 光靠"计时跑满 = 鼠标停住"会把压在栏上的指针也算成"停住了"，
        // 两条栏在用户手底下消失（淡出的标题栏仍然可点、光标还变成 `none`，会误触）。
        if (!mounted) return;
        if (playerChromeShouldHide(
          hasMedia: _hasMedia,
          overlayOpen: _settingsOpen,
          pointerInHotZone: _pointerInHotZone,
        )) {
          setState(() => _controlsVisible = false);
        }
      });
    }
  }

  /// 设定「指针现在是否压在上下热区里」，并保证"在热区里就一直显现"。
  ///
  /// 只在**热区判定**发生变化时用（`reveal` ↔ 非 `reveal`），不是每一次 hover 都 setState。
  void _setPointerInHotZone(bool value) {
    if (_pointerInHotZone == value) return;
    if (mounted) {
      setState(() {
        _pointerInHotZone = value;
        // 在热区里 ⇒ 立刻显现（可能已经被上一次计时藏掉了，比如指针在画面中间停过 1 秒
        // 之后才滑到控制栏上）。
        if (value) _controlsVisible = true;
      });
    } else {
      _pointerInHotZone = value;
    }
  }

  void _setBarDragging(bool v) {
    if (_barDragging == v) return;
    _barDragging = v;
    _pokeControls();
    if (!v) _persistVolume();
  }

  /// 鼠标在播放面内移动：按位置决定两条栏做什么（第二十六轮，见 [PlayerChromeMoveEffect]）。
  ///
  /// 规则（用户这一轮的原话「鼠标在热区内就会保持显现，移走后淡出」+
  /// 「鼠标不动时才隐藏」）：
  /// * 落在上下热区里（容差 [kChromeHotZoneSlack]）→ 显示并重新计时，
  ///   于是**指针压在栏上、贴着栏游走都稳稳显现**；
  /// * 在画面中间的窗口里动 → **不显示**（第十四轮的语义照旧：中间不许把栏叫出来），
  ///   但把 1 秒计时重新开始 —— 人还在动就不淡出，停下来才淡出；
  /// * 判断不了尺寸（未布局）→ 什么都不做。
  ///
  /// `onHover` 只在指针**真的移动**时触发，所以"计时跑满 1 秒"这件事本身
  /// 就等于"鼠标停住了 / 离开了窗口"——这两句需求用的是同一个计时器。
  void _onChromeHover(Offset local) {
    // `context.size`：这里拿到的是播放面整个 box。回调只在布局之后触发（指针事件
    // 不可能早于首帧布局），所以是安全的；拿不到（renderObject 非 RenderBox）时
    // 按"不命中"处理，宁可不动也不误唤醒。
    final Size size = context.size ?? Size.zero;
    final PlayerChromeMoveEffect effect = playerChromeMoveEffect(
      local,
      size,
      inWindow: true,
      // 浮层（播放列表 / 设置）打开时**一律算命中** —— 规则与理由见 [playerChromeRevealHit]。
      overlayOpen: _playlistOpen || _settingsOpen,
      // 顶部用播放器自绘标题栏的真实高度（`TitleBar` 里就是它）。
      topHeight: ThemeTokens.titleBarHeight,
      // 底部用控制栏 token 高度；栏本身还带 `spacing/2` 的上下内边距，
      // 差的那几像素由 [kChromeHotZoneSlack] 的容差吸收。
      bottomHeight: ref.read(tokensProvider).controlHeight,
      // 宿主设置：打开后画面正中动一下也叫出两条栏（默认关）。
      revealCenter: widget.wakeChromeAtCenter,
    );
    _applyChromeEffect(effect);
  }

  /// 把「这一次指针在哪儿」落到状态上（见 [PlayerChromeMoveEffect]）。
  ///
  /// 指针移出窗口（`MouseRegion.onExit`）也走这里、按 `inWindow: false` 判定：
  /// 于是"移出窗口"会排定 1 秒淡出（不立刻消失），而拖动进度条 / 设置面板打开 /
  /// 空态这些挂起语义照旧由 [_restartChromeHideTimer] 内部把关（不会在拖动中途藏栏）。
  void _onChromeExit() => _applyChromeEffect(
    playerChromeMoveEffect(
      Offset.zero,
      context.size ?? Size.zero,
      inWindow: false,
      overlayOpen: _playlistOpen || _settingsOpen,
      topHeight: ThemeTokens.titleBarHeight,
      bottomHeight: ref.read(tokensProvider).controlHeight,
    ),
  );

  void _applyChromeEffect(PlayerChromeMoveEffect effect) {
    switch (effect) {
      case PlayerChromeMoveEffect.reveal:
        // 命中热区：立即显示 + 取消旧计时 + 重排 1 秒隐藏（拖动/设置面板期间挂起）。
        _setPointerInHotZone(true);
        _pokeControls();
      case PlayerChromeMoveEffect.restart:
      case PlayerChromeMoveEffect.scheduleHide:
        // 不显示（画面中间 / 窗口外都不该把栏叫出来），只让"停住 1 秒才淡出"的计时
        // 从头开始 —— 这两条正是"移走后淡出 / 不动时才隐藏"。
        _setPointerInHotZone(false);
        _restartChromeHideTimer();
      case PlayerChromeMoveEffect.ignore:
        // 尺寸判据失真（未布局）：什么都不做，宁可不动也不误唤醒。
        break;
    }
  }

  // ── 键位（契约 §6，写死 + 长按连发）────────────────────────────────────────

  void _startHold(LogicalKeyboardKey key, PlayerAction action) {
    if (_holdTimers.containsKey(key)) return; // 已在长按，避免重复起
    final started = DateTime.now();
    _holdTimers[key] = Timer.periodic(const Duration(milliseconds: kHoldTickMs), (_) {
      final heldMs = DateTime.now().difference(started).inMilliseconds;
      if (heldMs < kHoldStartDelayMs) return; // 初始延迟内不连发（区分单击）
      final player = ref.read(playerProvider);
      switch (action) {
        case PlayerAction.seekForward:
          player.seekRelative(seekStepSeconds(heldMs));
        case PlayerAction.seekBackward:
          player.seekRelative(-seekStepSeconds(heldMs));
        case PlayerAction.volumeUp:
          player.nudgeVolume(kVolumeStepPerTick);
        case PlayerAction.volumeDown:
          player.nudgeVolume(-kVolumeStepPerTick);
        default:
          break;
      }
    });
  }

  void _stopHold(LogicalKeyboardKey key) => _holdTimers.remove(key)?.cancel();

  void _stopAllHolds() {
    for (final t in _holdTimers.values) {
      t.cancel();
    }
    _holdTimers.clear();
  }

  bool _handleKey(KeyEvent event) {
    if (_isEditableFocused()) {
      if (event is KeyUpEvent) _stopHold(event.logicalKey);
      return false; // 输入框内让行（否则中文输入/退格被吞）
    }
    final action = kPlayerKeymap[event.logicalKey];

    if (event is KeyUpEvent) {
      final wasHold = _holdTimers.containsKey(event.logicalKey);
      _stopHold(event.logicalKey);
      return wasHold;
    }
    if (event is KeyRepeatEvent) {
      // 用自管定时器，不依赖 OS 重复；可长按动作的重复事件吞掉避免叠加。
      return action != null && kHoldableActions.contains(action);
    }
    if (event is KeyDownEvent) {
      if (action == null) return false;
      if (kHoldableActions.contains(action)) {
        _dispatch(action); // 立刻走一次（单击=一步）
        _startHold(event.logicalKey, action);
        return true;
      }
      _dispatch(action);
      return true;
    }
    return false;
  }

  /// 当前主焦点是否在一个文本输入框（EditableText）内。
  bool _isEditableFocused() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    if (ctx.widget is EditableText) return true;
    var found = false;
    ctx.visitAncestorElements((e) {
      if (e.widget is EditableText) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  /// 文本框聚焦时启用 IME（可输中文），离开则禁用（保证快捷键不被输入法吞）。
  void _syncIme() {
    final want = _isEditableFocused();
    if (want != _imeEnabled) {
      _imeEnabled = want;
      _imeChannel.invokeMethod(want ? 'enable' : 'disable');
    }
  }

  // ── 动作分发（写死键位 + 右键菜单 + 控制栏共用）─────────────────────────────

  void _dispatch(PlayerAction a) {
    final player = ref.read(playerProvider);
    switch (a) {
      case PlayerAction.playPause:
        unawaited(player.playOrPause());
      case PlayerAction.seekForward:
        unawaited(player.seekBy(const Duration(seconds: kSeekStepSeconds)));
      case PlayerAction.seekBackward:
        unawaited(player.seekBy(const Duration(seconds: -kSeekStepSeconds)));
      case PlayerAction.volumeUp:
        unawaited(player.nudgeVolume(kVolumeStep));
      case PlayerAction.volumeDown:
        unawaited(player.nudgeVolume(-kVolumeStep));
      case PlayerAction.toggleMute:
        unawaited(player.toggleMute());
      case PlayerAction.toggleFullscreen:
        unawaited(_toggleFullscreen());
      case PlayerAction.exitFullscreen:
        unawaited(_exitFullscreen());
      case PlayerAction.nextItem:
        _nextEpisode();
      case PlayerAction.previousItem:
        _previousEpisode();
      case PlayerAction.cycleAudioTrack:
        unawaited(player.cycleAudio());
      case PlayerAction.cycleSubtitleTrack:
        unawaited(player.cycleSubtitle());
      case PlayerAction.openSettings:
        _toggleSettings();
      case PlayerAction.closeVideo:
        unawaited(_closeVideo());
      case PlayerAction.togglePip:
        unawaited(_togglePip());
      case PlayerAction.toggleAlwaysOnTop:
        unawaited(_toggleAlwaysOnTop());
      case PlayerAction.toggleStats:
        unawaited(_toggleStats());
      case PlayerAction.openSubtitleFile:
        unawaited(_openSubtitleFile());
      case PlayerAction.toggleAnime4k:
        unawaited(_cycleUpscale());
    }
  }

  // ── 窗口：全屏 / PiP / 置顶 ─────────────────────────────────────────────────

  Future<bool> _isFullscreenNow() async {
    try {
      return await windowManager.isFullScreen();
    } catch (_) {
      return _fullscreen;
    }
  }

  Future<void> _toggleFullscreen() async {
    // 真实全屏（OS）；以实际窗口状态为准（本地标志会和标题栏最大化键等外部路径脱节）。
    final fs = await _isFullscreenNow();
    await windowManager.setFullScreen(!fs);
    _fullscreen = !fs;
    if (mounted) setState(() {});
  }

  /// Esc：全屏时退出全屏；非全屏时关掉已打开的浮层（统一「逃逸键」）。
  Future<void> _exitFullscreen() async {
    if (await _isFullscreenNow()) {
      await windowManager.setFullScreen(false);
      _fullscreen = false;
      if (mounted) setState(() {});
      return;
    }
    if (_settingsOpen) _closeSettingsOverlay();
    if (_playlistOpen) setState(() => _playlistOpen = false);
    _focusNode.requestFocus();
  }

  Future<void> _toggleAlwaysOnTop() async {
    _alwaysOnTop = !_alwaysOnTop;
    await windowManager.setAlwaysOnTop(_alwaysOnTop);
    if (mounted) setState(() {});
  }

  Future<void> _togglePip() async {
    _pip = !_pip;
    if (_pip) {
      _prePipSize = await windowManager.getSize();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSize(const Size(480, 270));
    } else {
      await windowManager.setAlwaysOnTop(_alwaysOnTop);
      final size = _prePipSize;
      if (size != null) await windowManager.setSize(size);
    }
    if (mounted) setState(() {});
  }

  Future<void> _closeVideo() async {
    // 先落盘当前位置：stop() 会把 position 归零、currentPath 清空，之后再存就晚了。
    _saveResumeNow(_position);
    await ref.read(playerProvider).stop();
    if (!mounted) return;
    setState(() {
      _hasMedia = false;
      _currentPath = null;
      _nowPlaying = null;
      // 空态 chrome 常驻，热区标记跟着作废（下一次 hover 会重新判定）。
      _pointerInHotZone = false;
    });
    _hideTimer?.cancel();
  }

  // ── 视频数据浮层（Tab）──────────────────────────────────────────────────────

  Future<void> _toggleStats() async {
    if (_statsVisible) {
      _statsTimer?.cancel();
      _statsTimer = null;
      setState(() => _statsVisible = false);
      return;
    }

    Future<void> refresh() async {
      if (_statsBusy) return;
      _statsBusy = true;
      try {
        final s = await ref.read(playerProvider).getStatsSnapshot();
        if (mounted && _statsVisible) setState(() => _stats = s);
      } finally {
        _statsBusy = false;
      }
    }

    setState(() => _statsVisible = true);
    await refresh();
    // await 期间可能已被再次 Tab 关掉/页面销毁：此时起定时器会变成无人跟踪的常驻轮询。
    if (!mounted || !_statsVisible) return;
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => refresh());
  }

  // ── 设置 / 字幕 / 超分 ──────────────────────────────────────────────────────

  void _toggleSettings() {
    if (_settingsOpen) {
      _closeSettingsOverlay();
      return;
    }
    setState(() => _settingsOpen = true);
    // 浮层开着期间挂起自动隐藏（见 [_restartChromeHideTimer] 的 `_settingsOpen` 判断）。
    _hideTimer?.cancel();
    _focusNode.requestFocus();
  }

  /// 关掉设置浮层，并把自动隐藏重新武装起来。
  ///
  /// ⚠️ **所有**关闭路径都必须走这里（Esc / 点遮罩 / 面板上的关闭键 / 点画面）：
  /// 打开浮层时计时器是**直接 cancel 掉**的（不重排），如果关闭只 `setState` 不重新排定，
  /// 两条栏就会**无限期常驻**下去（第二十六轮自查时被独立审查抓到的漏点）。
  void _closeSettingsOverlay() {
    if (!_settingsOpen) return;
    setState(() => _settingsOpen = false);
    _pokeControls();
    _focusNode.requestFocus();
  }

  void _onVolume(double v) {
    unawaited(ref.read(playerProvider).setVolume(v));
    _volumeSaveTimer?.cancel();
    _volumeSaveTimer = Timer(const Duration(milliseconds: 800), _persistVolume);
  }

  void _persistVolume() {
    _volumeSaveTimer?.cancel();
    _volumeSaveTimer = null;
    unawaited(_settings.patch((s) => s..volume = _volume));
  }

  void _onSubtitleStyle(SubtitleStyle s) {
    unawaited(ref.read(playerProvider).applySubtitleStyle(s));
    unawaited(_settings.patch((st) => st..subtitleStyle = s));
    if (mounted) setState(() {});
  }

  Future<void> _openSubtitleFile() async {
    final res = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['srt', 'ass', 'ssa', 'sub', 'vtt']);
    final path = res?.files.single.path;
    if (path != null) {
      await ref.read(playerProvider).addExternalSubtitle(path);
      _focusNode.requestFocus();
    }
  }

  /// 切换超分方案/档位（2026-10-17 方案制；Anime4K 仍是默认方案）。
  Future<void> _setUpscale(UpscaleSelection selection) async {
    await ref.read(anime4kProvider).setSelection(selection);
    await _settings.patch((s) => s
      ..upscaleSchemeId = selection.schemeId
      ..anime4kPreset = selection.preset);
    if (mounted) setState(() {});
  }

  /// 控制栏超分胶囊：关 → Anime4K 轻/标/极 → 其他实时方案 → 关。
  Future<void> _cycleUpscale() {
    final Anime4kController a4k = ref.read(anime4kProvider);
    return _setUpscale(a4k.selection.cycle(a4k.schemes));
  }

  // ── 右键菜单（契约 §7）──────────────────────────────────────────────────────

  Future<void> _showContextMenu(Offset pos) async {
    final tokens = ref.read(tokensProvider);
    final player = ref.read(playerProvider);
    final a4k = ref.read(anime4kProvider);
    final fs = await _isFullscreenNow();
    if (!mounted) return;
    final entries = defaultContextEntries(
      audioItems: trackSubmenuItems(player.audioTracks, player.activeAudioId, noneLabel: '自动'),
      subtitleItems:
          trackSubmenuItems(player.subtitleTracks, player.activeSubtitleId, noneLabel: '关闭字幕'),
      upscale: a4k.selection,
      upscaleSchemes: a4k.schemes,
      pictureMenu: ref.read(pictureMenuProvider),
      alwaysOnTop: _alwaysOnTop,
      fullscreen: fs,
      pip: _pip,
      nvVsrAvailable: player.nvVsrAvailable,
      nvVsrEnabled: player.nvVsrEnabled,
    );
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _MenuHost(
        position: pos,
        tokens: tokens,
        entries: entries,
        onAction: _dispatch,
        onSubmenuSelect: _onSubmenuSelect,
        onCommand: _onMenuCommand,
        onDismiss: () {
          if (entry.mounted) entry.remove();
        },
      ),
    );
    overlay.insert(entry);
  }

  /// 弹出「画面调节」滑杆面板（点面板外的透明命中面关闭）。
  ///
  /// 用 Overlay 而不是弹 Dialog：播放面是全屏自绘的，Dialog 会带路由动画和
  /// 一层系统遮罩，观感上像"跳出去"了；这里只是画面上浮一块。
  ///
  /// ⚠️ 浮层里**不许铺遮罩色**（用户 2026-10-18：「打开滑杆面板时画面有层透明白色」）：
  /// 面板的用途就是看着画面调，任何压暗/提亮都会让判断失真。理由与测试见
  /// [PicturePanelLayer]。
  void _openPicturePanel(PictureMenu menu) {
    final OverlayState overlay = Overlay.of(context, rootOverlay: true);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (BuildContext ctx) => PicturePanelLayer(
        menu: menu,
        tokens: ref.read(tokensProvider),
        onClose: () {
          if (entry.mounted) entry.remove();
        },
      ),
    );
    overlay.insert(entry);
  }

  /// 命令条目（不占 [PlayerAction] 的菜单行，见 `ContextEntry.command`）。
  void _onMenuCommand(String elementId) {
    if (elementId == 'contextMenu.nvVsr') {
      unawaited(_toggleNvVsr());
    }
  }

  /// 开/关 NV-VSR，并把结果落到 store（下次开窗口还是上次的选择）。
  Future<void> _toggleNvVsr() async {
    final PlayerController player = ref.read(playerProvider);
    await player.setNvVsrEnabled(!player.nvVsrEnabled);
    if (mounted) setState(() {}); // 菜单文案「关闭/开启」跟着换
  }

  void _onSubmenuSelect(String elementId, SubmenuItem item) {
    final v = item.value;
    if (v is UpscaleSelection) {
      unawaited(_setUpscale(v));
      return;
    }
    if (v is PictureMenuSelection) {
      final PictureMenu? menu = ref.read(pictureMenuProvider);
      if (menu != null) {
        if (v.openPanel) {
          _openPicturePanel(menu);
        } else {
          unawaited(menu.selectPreset(v.presetId));
        }
      }
      return;
    }
    final player = ref.read(playerProvider);
    switch (elementId) {
      case 'contextMenu.audioTrack':
        unawaited(player.setAudioTrackById(v as int?));
      case 'contextMenu.subtitleTrack':
        unawaited(player.setSubtitleTrackById(v as int?));
    }
  }

  // ── build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final ThemeTokens tokens = ref.watch(tokensProvider);
    // 播放器没注入（widget 测试里常见）：给一个**非零尺寸的不透明占位面**。
    // ⚠️ 判据用 try/catch 而不是 `ref.exists`：Riverpod 3 的 `exists` 对
    // `overrideWithValue` 注入的 provider 会返回 false（见 State.initState 的说明），
    // 用它判断会在真实运行时误判成"未注入"⇒ 弹出播放窗口永远停在空态。
    PlayerController? injected;
    try {
      injected = ref.read(playerProvider);
    } catch (_) {
      injected = null;
    }
    if (injected == null) {
      return Material(color: tokens.base, child: OpenSurface(tokens: tokens));
    }
    final PlayerController player = injected;
    // 音效档位：宿主从扩展包扫来的清单灌给控制器（清单没变则直接返回）。
    // 放在 build 里是为了「这扇窗开着时装包」也能立刻认到新档位。
    player.seedAudioFxPresets(ref.watch(audioPresetsProvider));
    final EpisodeGroup? group = ref.watch(episodeGroupProvider);
    // `anime4kProvider` 走的是 `overrideWithValue`，同样不能用 `exists` 判（见上）。
    Anime4kController? a4k;
    try {
      a4k = ref.read(anime4kProvider);
    } catch (_) {
      a4k = null;
    }
    // 契约 §9：没有组信息（或只有一集）时，上一集/下一集按钮隐藏而不是禁用；
    // 到边界（第一集/最后一集）同样隐藏。
    final hasGroup = group != null && group.items.length > 1;
    final canPrevious = hasGroup && group.hasPrevious;
    final canNext = hasGroup && group.hasNext;
    // 空态时 chrome 常驻；载入媒体后随控制条一起淡隐。
    final chromeVisible = _controlsVisible || !_hasMedia;
    final sp = tokens.spacing;

    // 切集反馈（第三十八轮）：本地失败 > 宿主推来的失败 > 等待。三条都并到这一层里显示。
    final PlayerSwitchFeedback feedback = playerSwitchFeedback(
      pendingTitle: _switchPendingTitle,
      startedAt: _switchStartedAt,
      localError: _switchError,
      localHint: _switchErrorHint,
      notice: ref.watch(switchNoticeProvider),
      dismissed: _dismissedNotice,
      now: DateTime.now(),
    );

    return Material(
      color: tokens.base,
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (_, e) =>
            _handleKey(e) ? KeyEventResult.handled : KeyEventResult.ignored,
        child: MouseRegion(
          // 载入媒体且控制栏收起时隐藏鼠标光标（干净截图）。
          cursor: (_hasMedia && !_controlsVisible)
              ? SystemMouseCursors.none
              : MouseCursor.defer,
          // ⚠️ 鼠标唤起**只走热区**（用户 2026-10-12 第十四轮「鼠标移动到标题栏/控制栏时
          // 才会显现」）：这里以前是无条件 `_pokeControls()`，整个窗口任何位置动一下
          // 都会把两条栏叫出来；现在先做位置判定，画面中间一律不唤起。
          //
          // 第二十六轮起，画面中间的移动**只续命不显示**（用户：「鼠标不动时才隐藏」）——
          // 详见 [_onChromeHover] 与 [playerChromeMoveEffect]。
          onHover: (PointerHoverEvent e) => _onChromeHover(e.localPosition),
          // 鼠标移出窗口：按"不在窗口里"处理 ⇒ 排定 1 秒淡出（不立刻消失）。
          onExit: (_) => _onChromeExit(),
          child: GestureDetector(
            onSecondaryTapUp: (d) => unawaited(_showContextMenu(d.globalPosition)),
            onTap: () {
              _focusNode.requestFocus(); // 点击画面抢回键盘焦点
              if (_settingsOpen) _closeSettingsOverlay();
              if (_playlistOpen) setState(() => _playlistOpen = false);
            },
            child: Stack(
              children: [
                // 视频始终渲染（纹理早就绪，消除首个视频「有声无画」）。
                //
                // ⚠️ 画面区底色用 `ThemeTokens.videoLetterbox`（纯黑），**不能**用
                // `tokens.base` —— 那正是标题栏的底色，画面留黑边时两条栏会和黑边
                // 糊成一片、看起来"变粗"（用户 2026-10-10 的要求）。
                Positioned.fill(
                  child: VideoStage(
                    controller: player,
                    onDoubleTap: () => unawaited(_toggleFullscreen()),
                    background: ThemeTokens.videoLetterbox,
                    subtitleStyle: player.subtitleStyle,
                  ),
                ),
                // 空态：**不透明覆盖层**，外壳保持挂载（契约 §5 第 1/2 条）。
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: _hasMedia,
                    child: AnimatedOpacity(
                      opacity: _hasMedia ? 0 : 1,
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOut,
                      child: OpenSurface(tokens: tokens),
                    ),
                  ),
                ),
                if (_settingsOpen) _settingsLayer(tokens),
                if (_playlistOpen && hasGroup) _playlistLayer(tokens, group),
                // 切集反馈（第三十八轮）：放在两条栏**上面**，用户点完立刻看得到。
                if (feedback.visible) _switchLayer(tokens, feedback),
                if (_hasMedia)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      ignoring: !_controlsVisible,
                      child: AnimatedOpacity(
                        opacity: _controlsVisible ? 1 : 0,
                        duration: _fade,
                        curve: Curves.easeOut,
                        child: ControlBar(
                          tokens: tokens,
                          playing: _playing,
                          position: _position,
                          duration: _duration,
                          volume: _volume,
                          onPlayPause: () => _dispatch(PlayerAction.playPause),
                          onFullscreen: () => unawaited(_toggleFullscreen()),
                          onSeek: (d) {
                            unawaited(player.seekTo(d));
                            _saveResumeNow(d);
                          },
                          onVolume: _onVolume,
                          onBarDragging: _setBarDragging,
                          onPrevious: canPrevious ? _previousEpisode : null,
                          onNext: canNext ? _nextEpisode : null,
                          // 播放列表按钮：有组信息就常显（首集/末集也要能打开列表选别的）。
                          onPlaylist: hasGroup
                              ? () => setState(() => _playlistOpen = !_playlistOpen)
                              : null,
                          upscaleLabel: a4k?.selection.label(a4k.schemes),
                          upscaleOn: a4k?.selection.isOff == false,
                          onCycleUpscale: () => unawaited(_cycleUpscale()),
                        ),
                      ),
                    ),
                  ),
                // 标题栏置顶，随 chrome 一起淡隐（空状态常驻）。
                //
                // ⚠️ 这里**不能**包 `IgnorePointer(ignoring: !chromeVisible)`：那样控件
                // 自动淡隐之后标题栏就"看得见按不动"，用户报的「标题栏按住无法拖动」
                // 就是它。淡隐只影响透明度；命中测试交给标题栏自己。
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: AnimatedOpacity(
                    opacity: chromeVisible ? 1 : 0,
                    duration: _fade,
                    curve: Curves.easeOut,
                    child: TitleBar(
                      tokens: tokens,
                      nowPlaying: _nowPlaying,
                      fullscreen: _fullscreen,
                      onPoke: _pokeControls,
                      // 弹出播放窗口：最大化键改成切全屏（见 `maximizeTogglesFullscreen`）。
                      onMaximize: widget.maximizeTogglesFullscreen
                          ? () => unawaited(_toggleFullscreen())
                          : null,
                    ),
                  ),
                ),
                // 视频数据浮层（Tab），左上角、避开标题栏。
                if (_statsVisible && _stats != null)
                  Positioned(
                    // 避开标题栏：用播放器自己那个 28px 的标题栏高度，不是 barHeight(56)。
                    top: ThemeTokens.titleBarHeight + sp,
                    left: sp + 4,
                    child: IgnorePointer(
                      child: StatsOverlay(tokens: tokens, stats: _stats!),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _settingsLayer(ThemeTokens tokens) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _closeSettingsOverlay,
        child: Padding(
          padding: EdgeInsets.all(tokens.spacing * 2),
          child: Center(
            child: GestureDetector(
              onTap: () {}, // 吸收面板内的点击，避免点到面板就关
              child: SettingsPanel(
                tokens: tokens,
                volume: _volume,
                onVolume: _onVolume,
                subtitleStyle: ref.read(playerProvider).subtitleStyle,
                onSubtitleStyle: _onSubtitleStyle,
                // 宿主从扩展包扫出来的字幕样式预设（没装包时是空列表 → 不显示这一区）。
                presets: ref.watch(subtitlePresetsProvider),
                // 字体没加载上之类的非致命提示：显示在预设区下面。
                presetNotes: ref.watch(subtitlePresetNotesProvider),
                onClose: _closeSettingsOverlay,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 播放列表**右侧栏**：显示宿主组好的那一组（同名同压制组的各集），点一项交回宿主起播。
  ///
  /// 用户 2026-10-11：「播放列表太小了看不到集数了应该放在右边栏里」——
  /// 旧实现是居中的 380×460 浮层，而播放器弹窗真机上只有 462×260 逻辑像素，
  /// 浮层比窗口还大、被裁掉。现在贴着窗口右边缘、撑满高度，宽度自适应。
  Widget _playlistLayer(ThemeTokens tokens, EpisodeGroup group) {
    return Positioned(
      // 顶部让开标题栏：它在 Stack 里更靠后（画在上层）且**不可隐藏**，
      // 不让开的话侧栏表头（含"收起列表"键）会被它压住、点不到。
      top: ThemeTokens.titleBarHeight + 1,
      left: 0,
      right: 0,
      bottom: 0,
      child: Row(
        children: <Widget>[
          // 左侧留一块点击即收起的遮罩（透明：不遮住画面，只接住点击）。
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _playlistOpen = false),
              child: const SizedBox.expand(),
            ),
          ),
          EpisodePanel(
            tokens: tokens,
            group: group,
            // 用户拖过左边框就用他拖出来的宽度（见 `_playlistWidth` 的说明）。
            width: _playlistWidth,
            onWidthChanged: (double w) => setState(() => _playlistWidth = w),
            onSelect: (MediaItem item) {
              setState(() => _playlistOpen = false);
              _playEpisode(item);
            },
            onClose: () => setState(() => _playlistOpen = false),
          ),
        ],
      ),
    );
  }

  /// 切集反馈层（第三十八轮）：等待中 = 转圈 + 集名 + 等待秒数；失败 = 原因 + 怎么办。
  ///
  /// 用户原话：「优化反馈，点击下一集或上一集都没实质性反馈」。这一层就是那句
  /// 「实质性反馈」：点下去**立刻**有东西出现，等多久看得见，失败了原因就在画面上
  /// （而不是躺在被播放窗口盖住的主窗口横幅里）。
  Widget _switchLayer(ThemeTokens t, PlayerSwitchFeedback feedback) {
    final bool waiting = feedback.error == null;
    final String title =
        waiting ? '正在切到《${feedback.pendingTitle ?? ''}》' : '这一集没切过去';
    final String detail = waiting
        ? playerSwitchWaitingText(feedback.waitedSeconds)
        : <String?>[feedback.error, feedback.hint].whereType<String>().join('\n');
    return Positioned.fill(
      // 等待时不挡鼠标（画面照旧能点）；失败时**要能点**，否则那颗「关闭」按不动。
      child: IgnorePointer(
        ignoring: waiting,
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 520),
            margin: const EdgeInsets.all(24),
            padding: EdgeInsets.symmetric(horizontal: t.spacing * 1.5, vertical: t.spacing),
            decoration: BoxDecoration(
              color: t.raised,
              borderRadius: BorderRadius.circular(t.radiusCard),
              border: Border.all(color: t.line),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (waiting)
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: t.accent,
                        ),
                      )
                    else
                      Icon(Icons.error_outline, size: 16, color: t.danger),
                    SizedBox(width: t.spacing / 2),
                    Flexible(
                      child: Text(
                        title,
                        style: TextStyle(
                          color: t.text,
                          fontSize: t.fontSize,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: EdgeInsets.only(top: t.spacing / 2),
                  child: Text(
                    detail,
                    style: TextStyle(color: t.text2, fontSize: t.fontSize - 1, height: 1.5),
                  ),
                ),
                // 失败时给一个「关掉」：这一层是提示，不该挡着用户去点别的地方。
                if (!waiting)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: EdgeInsets.only(top: t.spacing / 2),
                      child: GestureDetector(
                        onTap: _dismissSwitchLayer,
                        child: Text(
                          '关闭',
                          style: TextStyle(
                            color: t.accent,
                            fontSize: t.fontSize,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 关掉切集反馈层：失败提示要能手动收掉（同一条宿主通知不再弹）。
  void _dismissSwitchLayer() {
    setState(() {
      _dismissedNotice = ref.read(switchNoticeProvider) ?? _dismissedNotice;
      _switchPendingTitle = null;
      _switchStartedAt = null;
      _switchError = null;
      _switchErrorHint = null;
    });
  }
}

/// 右键菜单宿主：全屏遮罩（点空白关闭）+ 锚定光标（越界时最小回移）+ 160ms 淡入淡出。
class _MenuHost extends StatefulWidget {
  final Offset position;
  final ThemeTokens tokens;
  final List<ContextEntry> entries;
  final void Function(PlayerAction) onAction;
  final void Function(String, SubmenuItem) onSubmenuSelect;
  final ValueChanged<String>? onCommand;
  final VoidCallback onDismiss;

  const _MenuHost({
    required this.position,
    required this.tokens,
    required this.entries,
    required this.onAction,
    required this.onSubmenuSelect,
    required this.onDismiss,
    this.onCommand,
  });

  @override
  State<_MenuHost> createState() => _MenuHostState();
}

class _MenuHostState extends State<_MenuHost> with SingleTickerProviderStateMixin {
  static const Duration _dur = Duration(milliseconds: 160);

  late final AnimationController _c = AnimationController(vsync: this, duration: _dur)..forward();
  bool _closing = false;

  Future<void> _close([PlayerAction? a]) async {
    if (_closing) return;
    _closing = true;
    await _c.reverse();
    if (a != null) widget.onAction(a);
    widget.onDismiss();
  }

  /// 命令条目：先收起菜单再执行（执行里可能要发 mpv 命令，别让菜单动画卡着）。
  Future<void> _closeCommand(String elementId) async {
    if (_closing) return;
    _closing = true;
    await _c.reverse();
    widget.onDismiss();
    widget.onCommand?.call(elementId);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final maxH = (screen.height - 16).clamp(120.0, double.infinity);
    final curved = CurvedAnimation(parent: _c, curve: Curves.easeOut);
    return Stack(children: [
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _close(),
          onSecondaryTap: () => _close(),
        ),
      ),
      Positioned.fill(
        child: CustomSingleChildLayout(
          delegate: _MenuLayoutDelegate(widget.position),
          child: AnimatedBuilder(
            animation: curved,
            builder: (context, child) => Opacity(
              opacity: curved.value.clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(0, (1 - curved.value) * -8),
                child: child,
              ),
            ),
            child: ContextMenuOverlay(
              tokens: widget.tokens,
              entries: widget.entries,
              maxHeight: maxH,
              submenuOnLeft: widget.position.dx > screen.width * 0.55,
              onAction: (a) => _close(a),
              onCommand: (eid) => _closeCommand(eid),
              onSubmenuSelect: (eid, item) {
                _close();
                widget.onSubmenuSelect(eid, item);
              },
            ),
          ),
        ),
      ),
    ]);
  }
}

/// 把菜单锚定在右键点；只有越界时才按实际尺寸最小回移，保证整菜单在屏内且贴近光标。
class _MenuLayoutDelegate extends SingleChildLayoutDelegate {
  final Offset anchor;
  _MenuLayoutDelegate(this.anchor);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // 默认从光标向右下展开；贴底则向上张开、贴右则向左张开（始终锚在光标）。
    double fit(double pos, double child, double extent) {
      double p = pos;
      if (p + child > extent) p = pos - child; // 翻转：从光标反向展开
      return p.clamp(0.0, (extent - child).clamp(0.0, extent));
    }

    return Offset(
      fit(anchor.dx, childSize.width, size.width),
      fit(anchor.dy, childSize.height, size.height),
    );
  }

  @override
  bool shouldRelayout(_MenuLayoutDelegate oldDelegate) => oldDelegate.anchor != anchor;
}
