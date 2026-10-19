/// 播放子窗口的渲染入口（决策 B26/B28 + 用户 2026-10-10 的要求）。
///
/// **只有这个入口播放**。主窗口不挂任何播放面 —— 用户明确要求
/// 「只做弹出窗口，不要其他任何地方播放」。
///
/// 子窗口是独立 Flutter 引擎（独立 isolate）：这里自己 `bootstrapPlayer()`
/// 造一个属于本窗口的 mpv 实例，再把自己的 `ProviderScope` 装上。
/// 主窗口通过窗口通道下发三样东西：
/// * [kMethodOpen] —— 一条播放请求（换集时复用同一个窗口）；
/// * [kMethodArgs] —— 外观 token / 剧集分组（子窗口读不到主窗口的 provider 容器）；
/// * [kMethodPlayOrPause] / [kMethodSeek] / [kMethodStop] —— 控制。
///
/// 播放请求转成 [shikiin.PlayerRequestNotifier] 的一次 `request(...)`——于是播放面里
/// 那条既有的消费链路原样复用，不需要为"窗口"再写一条开播路径。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shikiin/shikiin.dart' as shikiin;
import 'package:window_manager/window_manager.dart' as wm;

import '../state/extension_schemes.dart';
import '../state/player_window.dart';
import '../state/store_layout.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// 子窗口的「环境」：外观 token 与剧集分组，由主窗口推过来。
///
/// 为什么不直接换 `ProviderScope` 的 override：换 override 会重建整个 scope，
/// 把 `PlayerSurface` 卸载重挂 —— 而播放面必须常驻挂载（契约 §5），重挂等于每次
/// 切浅/深/换集都把 mpv 拆了重建。走 notifier 只让**读它的 provider** 重算。
final ValueNotifier<DsTokens> windowTokensNotifier = ValueNotifier<DsTokens>(DsTokens.whiteInk);

/// 浅/深过渡时长（与主窗口 `kDsThemeAnimationDuration` 同一节奏，180ms）。
const Duration kDsTokenFadeDuration = Duration(milliseconds: 180);

final ValueNotifier<shikiin.EpisodeGroup?> windowEpisodeGroupNotifier =
    ValueNotifier<shikiin.EpisodeGroup?>(null);

/// 「画面正中也唤起两条栏」（宿主设置项，第二十七轮）：主窗口推过来。
///
/// 与 token/分组同一套推送机制 —— 子窗口读不到主窗口的 `settingsProvider`，
/// 设置页改了之后由 `app.dart` 的 `pushArgs(wakeChromeAtCenter: …)` 现场推。
final ValueNotifier<bool> windowWakeChromeAtCenterNotifier = ValueNotifier<bool>(false);

/// 播放窗口的根：把主窗口下发的请求喂给 `PlayerSurface`。
class PlayerWindowApp extends ConsumerStatefulWidget {
  const PlayerWindowApp({
    super.key,
    required this.args,
    required this.controller,
    this.onExtensionsChanged,
  });

  /// 启动参数（首次播放的那一条 + 那一时刻的外观/分组）。
  final PlayerWindowArgs args;

  /// 本窗口自己的 controller —— 主窗口通过它下发后续请求。
  final WindowController controller;

  /// 扩展目录变了：让宿主**重新扫一遍并补挂**画面调节菜单（返回时菜单已就位）。
  ///
  /// 为什么由宿主来做：装配它要用这个窗口自己的 `AppRuntime`（anime4k 控制器）
  /// 和刚扫出来的包 —— 这些只在 `main.dart._runPlayerWindow` 的作用域里，
  /// `PlayerWindowApp` 拿不到。（null = 组件测试/没装配，退回"只重扫现有菜单"。）
  final Future<void> Function()? onExtensionsChanged;

  @override
  ConsumerState<PlayerWindowApp> createState() => _PlayerWindowAppState();
}

class _PlayerWindowAppState extends ConsumerState<PlayerWindowApp>
    with SingleTickerProviderStateMixin {
  /// 「正在关窗」标志：`setPreventClose` 会让我们收到多次关窗请求，只处理第一次。
  bool _closing = false;

  /// 几何上报的去抖定时器（拖动/缩放结束后 350ms 才发一条）。
  Timer? _geometryTimer;

  /// 播放请求通道：**必须**用容器里那一个（`shikiinOverrides` 注入的），
  /// 不能自己 `PlayerRequestNotifier()` 造一个新的 —— 那样投进去的请求
  /// 播放面根本读不到（它读的是 provider 里那个），表现就是"窗口开了但一直空态"。
  late final shikiin.PlayerRequestNotifier _requests =
      ref.read(shikiin.playerRequestProvider) ??
      (throw StateError('子窗口缺少播放请求通道：装配根必须传 playerRequests'));
  int _nonce = 0;

  /// 浅/深切换的平滑过渡（用户 2026-10-10：「切换深色生硬会闪烁」）。
  ///
  /// 播放窗口的 token 是**主窗口推过来**的（`tokensProvider` override），走不到
  /// `MaterialApp` 的 ThemeData 插值，所以这里自己 lerp：180ms 内从旧 token 过渡到新 token。
  late final AnimationController _tokenFade = AnimationController(
    vsync: this,
    duration: kDsTokenFadeDuration,
  );
  shikiin.ThemeTokens? _tokenFrom;
  shikiin.ThemeTokens? _tokenTo;

  @override
  void initState() {
    super.initState();
    // 启动参数自带第一条请求与那份环境：先灌环境，再 request —— 播放面在
    // initState/postFrame 会补消费 `value`（契约 §5 第 2 条），不会丢。
    _trace('initState: args=${widget.args.streamUrl}');
    _applyEnv(widget.args);
    _deliver(widget.args);
    // 观看记录的第二十七轮改动：进度只有这一侧知道（主窗口没有播放信号）。
    _bindProgressReporting();

    // 主窗口后续的请求/控制走这里。
    unawaited(widget.controller.setWindowMethodHandler((MethodCall call) async {
      switch (call.method) {
        case kMethodOpen:
          final PlayerWindowArgs? args = PlayerWindowArgs.decode(_encodeArgs(call.arguments));
          if (args != null) {
            _deliver(args);
            // 被收起来的那扇窗：主窗口要求播放 = 同时要求它显示出来。
            await _surfaceIfHidden();
          }
        case kMethodArgs:
          final PlayerWindowArgs? args = PlayerWindowArgs.decode(_encodeArgs(call.arguments));
          if (args != null) _applyEnv(args);
        case kMethodPlayOrPause:
          await ref.read(shikiin.playerProvider).playOrPause();
        case kMethodSeek:
          final Object? ms = call.arguments;
          if (ms is num) {
            await ref.read(shikiin.playerProvider).seekTo(Duration(milliseconds: ms.toInt()));
          }
        case kMethodStop:
          await ref.read(shikiin.playerProvider).stop();
        case kMethodHideSelf:
          // 主窗口的「关闭播放窗口」：与用户点 ✕ 走同一条**收起**路径。
          await _hideSelf('主窗口要求收起');
        case kMethodCloseSelf:
          // 主窗口的「彻底关闭播放器」：真关这一扇窗（拆引擎）。
          await _destroySelf('主窗口要求彻底关闭');
        case kMethodSwitchFailed:
          // 第三十八轮：用户点的「下一集/上一集」没起来 —— 把原因顶到他眼前
          // （他人在播放窗口里，主窗口那条横幅被这扇窗盖住）。
          final shikiin.EpisodeSwitchNotice? notice = decodeSwitchNotice(call.arguments);
          if (notice != null) {
            _trace('切集失败通知：${notice.message}');
            windowSwitchNoticeNotifier.value = notice;
          }
        case kMethodExtensionsChanged:
          // 1.1.0 第六十四轮（用户实测）：主窗口装了/卸了/启停了扩展 —— 本窗口是独立
          // 引擎，方案清单是开窗时扫的，不重扫就会一直挂着已经没了的扩展。
          await _reloadExtensionSchemes();
      }
      return null;
    }));

    // 关窗：**先拦下来**做收尾，收完再把这一扇窗收起来（默认）或关掉。
    //
    // 拦下来这一步是必须的：`WM_CLOSE` 一旦放行，`DefWindowProc` 会立刻
    // `DestroyWindow`，子窗口引擎（libmpv/ANGLE/纹理）就会在**还在播放**的状态下被拆 ——
    // 实测这一步会间歇性把整个进程带走（fast-fail 0xC0000409），
    // 也可能把主窗口拖到不响应（用户 2026-10-11 报的「主窗口卡死」）。
    wm.windowManager.addListener(_OnClose(_hideSelf));
    // 兜底：这扇窗**绝不允许处于最大化状态**。
    //
    // 用户 2026-10-11 的「开启播放器后整个程序都不能用了，什么都点不了整个 DSanime」
    // 真机上就是它被最大化（自己报回来的几何 `-7,-7 2062x1246` = 铺满工作区）。
    // 正常路径已经堵住（`setMaximizable(false)` + 自绘标题栏的最大化键改成切全屏 +
    // 宿主给了 `setMaximumSize`），这里是**最后一道**：真收到最大化事件就立刻退回去。
    wm.windowManager.addListener(_OnMaximize(_undoMaximize));
    // 用户拖过/缩过这扇窗 → 报给主窗口记住（下次开窗还放这儿）。
    // 只在**移动/缩放结束**时触发（window_manager 的 Moved/Resized 是"结束后一次"），
    // 再加一层去抖，拖动过程中不会刷屏。
    wm.windowManager.addListener(_OnGeometry(_scheduleGeometryReport));
    unawaited(_armPreventClose());

    // 排障：把「本窗口是谁」记进日志（见 [_traceHwnd]）。
    unawaited(_traceHwnd('initState'));
  }

  /// 扩展目录变了 → 重扫方案清单并灌进正在跑的播放器（见 [kMethodExtensionsChanged]）。
  ///
  /// 失败只记日志、**不影响当前播放**：最坏情况是菜单里还挂着旧扩展，用户重开播放窗口
  /// 就能恢复（那条路径每次开窗都重扫）。
  Future<void> _reloadExtensionSchemes() async {
    try {
      final DataRoot dataRoot = await resolveDataRoot();
      final ExtensionSchemeRefresh refresh = await refreshExtensionSchemes(
        controller: ref.read(shikiin.anime4kProvider),
        supportDir: Directory(dataRoot.path),
      );
      _trace(
        '扩展变更：方案 ${refresh.schemes.length} 个（选中 ${refresh.selection.schemeId}'
        '${refresh.selectionReset ? '，原方案已被卸载/禁用 → 已回退内置 Anime4K' : ''}）',
      );
      // 画面调节包也要重扫：① 用户在扩展页关掉了某些预设（`extension-settings.json`）；
      // ② 更常见的：**这扇窗已经开着的时候才装上的画面调节包** —— 开窗那次扫描
      // 当然没看到它，而 `pictureMenuProvider` 是只读 Provider（第一次读到 null
      // 就被缓存住），不重新挂 + 不丢缓存的话右键菜单里永远没有「画面调节」。
      // 用户 2026-10-18 原话：「装完插件后播放器不会立马生效」（只有重启 app 才行）。
      try {
        final Future<void> Function()? rescan = widget.onExtensionsChanged;
        if (rescan != null) {
          await rescan(); // 宿主：重扫 + 必要时现场挂上（`main.dart._ensurePictureMenu`）
        } else {
          // 没有装配根回调（组件测试）：至少把现有菜单重扫一遍。
          await ref.read(shikiin.pictureMenuProvider)?.reload();
        }
        // 菜单实例可能刚被换上/摘下：丢掉旧缓存，让右键菜单下次读到新值。
        ref.invalidate(shikiin.pictureMenuProvider);
      } catch (e) {
        _trace('扩展变更后重扫画面调节包失败（菜单保持旧清单）：$e');
      }
      // 方案清单变了：控制栏胶囊文案/菜单都读它，重建一次让界面跟上。
      if (mounted) setState(() {});
    } catch (e) {
      _trace('扩展变更后重扫方案失败（当前播放不受影响，重开播放窗口会再扫）：$e');
    }
  }

  /// 收到"被最大化"就退回去（见 `_OnMaximize` 的说明）。
  Future<void> _undoMaximize() async {
    _trace('检测到自己被最大化 → 立刻退回（这扇窗不许铺满整屏盖住主窗口）');
    try {
      await wm.windowManager.unmaximize();
    } catch (e) {
      _trace('退回最大化失败：$e');
    }
  }

  /// 让本窗口的 `WM_CLOSE` 先回到 Dart（否则没机会做收尾）。
  Future<void> _armPreventClose() async {
    try {
      await wm.windowManager.setPreventClose(true);
    } catch (e) {
      // 拦不住就退回原生默认关闭（会少一次收尾，但绝不让窗口关不掉）。
      _trace('preventClose 设置失败：$e');
    }
  }

  /// 默认关闭语义：**先把自己收起来，再停播**（`ShowWindow(SW_HIDE)`），引擎留着。
  ///
  /// 顺序是用户 2026-10-11 第三次报障改的：「点击关闭后会卡一会儿才关掉」——
  /// 原来先 `await stop()`（上限 1500ms，mkv 收尾实测能花满）再 `hide()`，
  /// 那 1.5 秒里窗口还杵在屏幕上，用户看到的就是"关不掉/卡一下"。
  /// 现在：**先 hide（立刻消失）→ 报告几何 → 告诉主窗口 → 后台停播**。
  ///
  /// 为什么不真关（用户 2026-10-10「关闭播放器后为什么全关了」+ 2026-10-11
  /// 「主窗口会卡死」）：真关 = `DestroyWindow` → `FlutterWindow::OnDestroy`
  /// 同步拆掉子窗口的 Flutter 引擎，而这一步跑在**主线程的消息泵里**、还要 join
  /// 子窗口的 UI 线程。同一个拆除过程真机实测既会 fast-fail（0xC0000409，
  /// 整个进程一起消失），也会把主窗口拖住到不响应。收起来完全不碰拆除。
  ///
  /// 停播失败就**不留它在暗处响**：退回[彻底关闭]（拆掉窗口，声音一定停）。
  Future<void> _hideSelf(String reason) async {
    if (_closing) return;
    _closing = true;
    await _traceHwnd(reason);
    _trace('$reason：先把这一扇窗收起来（立刻消失，不拆引擎），再停播');

    try {
      await wm.windowManager.hide();
    } catch (e) {
      _trace('$reason：隐藏失败 → 退回彻底关闭：$e');
      await _destroySelf(reason, alreadyClosing: true);
      return;
    }
    // 告诉主窗口「我还在，只是收起来了」：状态栏据此从"正在播放"切回"唤回播放器"，
    // 主窗口也会被唤到前台。放在停播**之前** —— 用户按下 × 之后该立刻看到主窗口。
    await _reportGeometry();
    await _notifyParent(kMethodChildHidden);

    // 藏起来之后才停播：这步可能要 1.5s，绝不能挡在用户点 × 的前面。
    if (!await _stopPlayback(reason)) {
      _trace('$reason：停播没成功 → 退回彻底关闭（不能让声音留在看不见的窗口里）');
      await _destroySelf(reason, alreadyClosing: true);
      return;
    }
    // 窗口还在：把闸门放开，下次还能收起 / 还能彻底关。
    _closing = false;
  }

  /// 播放器点了播放列表里的一条：把**条目 id** 交回主窗口。
  ///
  /// 只传 id（不传磁力/地址）：主窗口那边才有源客户端与边车，补磁力、加种、
  /// 拿 `streamUrl` 都得它来做（见 `kMethodEpisodeSelect`）。
  void _onEpisodeSelected(shikiin.MediaItem item) {
    unawaited(_notifyParent(kMethodEpisodeSelect, item.path));
  }

  /// 把当前位置/大小报给主窗口（主窗口落盘记住，下次开窗放回这里）。
  Future<void> _reportGeometry() async {
    try {
      final Rect bounds = await wm.windowManager.getBounds();
      await _notifyParent(kMethodGeometry, encodeGeometry(bounds));
    } catch (e) {
      _trace('报告窗口几何失败：$e');
    }
  }

  void _scheduleGeometryReport() {
    _geometryTimer?.cancel();
    _geometryTimer = Timer(const Duration(milliseconds: 350), () {
      unawaited(_reportGeometry());
    });
  }

  /// 停播（带上限）。返回 true = 已经停下来（或本来就没在播）。
  Future<bool> _stopPlayback(String reason) async {
    // 停之前先报一条进度：`stop()` 会把 position 打回 0，而观看记录要的是"看到哪儿"。
    await _reportWatchProgress();
    try {
      await ref.read(shikiin.playerProvider).stop().timeout(const Duration(milliseconds: 1500));
      return true;
    } catch (e) {
      _trace('$reason：停播收尾失败：$e');
      return false;
    }
  }

  /// 彻底关闭：停播 → 落盘 → **放掉 Hive 锁** → 放行 → 关这一扇窗（**只关这一扇**）。
  ///
  /// ⚠️ 只在两条路上用：① 主窗口明确要求「彻底关闭播放器」；② [.._hideSelf] 里
  /// 停播/隐藏失败（那时留着它比关掉更糟）。默认关闭请用 [_hideSelf]。
  ///
  /// 每一步都有上限：收尾失败也必须把窗口关掉，绝不让用户遇到"点了✕关不掉"。
  Future<void> _destroySelf(String reason, {bool alreadyClosing = false}) async {
    if (!alreadyClosing) {
      if (_closing) return;
      _closing = true;
    }
    await _traceHwnd(reason);
    _trace('$reason：先停播收尾，再关这一扇窗');

    await _stopPlayback(reason);
    // 给渲染/解码线程一点时间把手里的资源放掉（这一步是实测出来的：直接关会炸）。
    await Future<void>.delayed(const Duration(milliseconds: 150));

    // 用户 2026-10-11 第二阶段清单第 3 项：放掉 Hive 占位锁（`<box>.lock`）。
    // 只在这条"这扇窗真的要消失"的路上做 —— 收起（hide）时引擎还活着、box 还要用。
    // 放在放行之前：拆除期手里少一个文件句柄与锁。
    try {
      await ref.read(shikiin.storeProvider).close();
      _trace('已释放 Hive 锁');
    } catch (e) {
      _trace('释放 Hive 锁失败（照常关窗）：$e');
    }

    try {
      await wm.windowManager.setPreventClose(false);
    } catch (_) {
      // 放行失败也要试 close：最坏情况回到"原生默认关闭"。
    }
    try {
      await wm.windowManager.close();
    } catch (e) {
      _trace('关窗失败：$e');
    }
  }

  /// 被子窗口收起来之后又被要求播放：先 show 出来（这是插件真实现了的
  /// `window_show` 那条路），再 focus。
  Future<void> _surfaceIfHidden() async {
    try {
      if (await wm.windowManager.isVisible()) return;
      await wm.windowManager.show();
      await wm.windowManager.focus();
      _trace('被收起的窗口已重新显示');
    } catch (e) {
      _trace('重新显示窗口失败：$e');
    }
  }

  /// 反过来通知主窗口一条方法（子 → 父）。
  ///
  /// 方向与 `kMethodOpen` 相反，靠的是插件里的跨窗口通道：
  /// 每个窗口用自己的 id 注册 `mixin.one/window_controller/<id>`，
  /// 那条通道是 unidirectional —— **任何引擎都能调**。主窗口的 id 从
  /// `getAll()` 里挑（列表里除了自己那一条就是主窗口）。
  Future<void> _notifyParent(String method, [Object? arguments]) async {
    try {
      final List<WindowController> all = await WindowController.getAll();
      for (final WindowController w in all) {
        if (w.windowId == widget.controller.windowId) continue;
        await w.invokeMethod<void>(method, arguments);
        return;
      }
      _trace('通知主窗口失败（$method）：窗口列表里找不到主窗口');
    } catch (e) {
      _trace('通知主窗口失败（$method）：$e');
    }
  }

  @override
  void dispose() {
    unawaited(_posSub?.cancel());
    unawaited(_durSub?.cancel());
    _geometryTimer?.cancel();
    _tokenFade.dispose();
    super.dispose();
  }

  // ── 观看进度上报（第二十七轮）──────────────────────────────────────────────
  //
  // 为什么由**子窗口**报：主窗口拿不到播放信号（`PlayerWindowPort.signals` 是空流），
  // 而"看到哪儿了"只存在于这一侧的 mpv 里。播放面是 ShikiiN 的，不该为宿主的观看记录
  // 长出一个上报口，所以这里直接订阅 ShikiiN 暴露的 `PlayerController.player`
  // （media_kit 的 `Player`，`stream.position/duration` 是它的公开流）。
  //
  // ⚠️ 只报**递增**的位置：`stop()` / 换片会把 position 打回 0，
  // 照单全收就会把"看到 18 分钟"改写成 0（观看记录里显示成没看过）。
  // 换片靠 `currentPath` 变化识别（那时才把基准清回 0）。
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  String? _progressPath;
  int _reportedPositionMs = 0;
  int _durationMs = 0;

  /// 本窗口的播放控制器（`_bindProgressReporting` 拿到后就留着，报告时要读 `currentPath`）。
  shikiin.PlayerController? _playerCtrl;

  void _bindProgressReporting() {
    try {
      final shikiin.PlayerController ctrl = ref.read(shikiin.playerProvider);
      _playerCtrl = ctrl;
      _durSub = ctrl.player.stream.duration.listen((Duration d) {
        if (d.inMilliseconds > _durationMs) _durationMs = d.inMilliseconds;
      });
      _posSub = ctrl.player.stream.position.listen((Duration p) {
        final String? path = ctrl.currentPath;
        if (path != _progressPath) {
          // 换了一集：进度基准从 0 重新算（上一条已经报出去了）。
          _progressPath = path;
          _reportedPositionMs = 0;
        }
        final int ms = p.inMilliseconds;
        if (ms <= _reportedPositionMs) return; // 停播回零 / 回退：不当进度
        if (ms - _reportedPositionMs < kWatchProgressReportMs) return;
        _reportedPositionMs = ms;
        unawaited(_reportWatchProgress());
      });
    } catch (e) {
      // 上报接不上只影响观看记录，不该影响播放（组件测试/内嵌宿主也会走到这里）。
      _trace('观看进度上报没接上：$e');
    }
  }

  /// 把当前进度报给主窗口（主窗口配 `nowPlaying` 的元数据写一条观看记录）。
  ///
  /// [path] 一并报上去（= 这一侧**真正在放**的那一条）：同一个 torrent 里的其它集是
  /// 子窗口**自己**开盘的（`streamUri` 已在分组里），宿主并不知道换了集 ——
  /// 没有这个字段，第 2 集的进度会写进第 1 集的记录（见 `NowPlaying.watchByUrl`）。
  Future<void> _reportWatchProgress() async {
    if (_reportedPositionMs <= 0) return;
    await _notifyParent(kMethodWatchProgress, <String, Object?>{
      'positionMs': _reportedPositionMs,
      'durationMs': _durationMs,
      if ((_playerCtrl?.currentPath ?? '').isNotEmpty) 'path': _playerCtrl!.currentPath,
    });
  }

  /// `Map<Object?, Object?>` → JSON 文本（复用同一套解析，避免两条解析路径）。
  static String _encodeArgs(Object? raw) {
    if (raw is! Map) return '';
    final Map<String, Object?> out = <String, Object?>{'type': kPlayerWindowType};
    raw.forEach((Object? k, Object? v) {
      if (k is String) out[k] = v;
    });
    return const JsonEncoder().convert(out);
  }

  /// 外观/分组变化：更新环境 notifier（`main.dart` 把那两个接到 shikiin 的
  /// `tokensProvider` / `episodeGroupProvider` 上）。
  void _applyEnv(PlayerWindowArgs args) {
    final Map<Object?, Object?>? tk = args.tokens;
    if (tk != null) windowTokensNotifier.value = decodeTokens(tk);
    final Map<Object?, Object?>? eg = args.episodeGroup;
    if (eg != null) windowEpisodeGroupNotifier.value = decodeEpisodeGroup(eg);
    final bool? wake = args.wakeChromeAtCenter;
    if (wake != null) windowWakeChromeAtCenterNotifier.value = wake;
  }

  void _deliver(PlayerWindowArgs args) {
    _applyEnv(args);
    if (args.streamUrl.isEmpty) return; // 纯环境推送，不是播放请求
    _requests.request(
      shikiin.PlayerRequest(
        uri: args.streamUrl,
        title: args.title,
        startAt: args.startAtMs == null ? null : Duration(milliseconds: args.startAtMs!),
        subtitlePath: args.subtitlePath,
        nonce: ++_nonce,
      ),
    );
  }

  /// 子窗口的排障面包屑（落 shikiin 的 `logs/shikiin-*.log`）。
  ///
  /// 子窗口是**独立引擎**，它的 stdout 不一定进宿主那份重定向日志（实测），
  /// 所以"窗口开了但没播"这类问题只能靠这里定位。
  void _trace(String message) {
    try {
      shikiin.diag.info('player-window', message);
    } catch (_) {
      // diag 没打开也无所谓：这只是排障线索。
    }
  }

  /// 记下本窗口 `window_manager` 认为自己在管哪个 HWND。
  ///
  /// 「关播放器把整个应用关了」这种问题，第一件要确认的事就是**子窗口的
  /// `window_manager` 到底指向谁**（它来自 `GetAncestor(view, GA_ROOT)`）。
  /// 这个值在真机日志里一比就能定位，不需要再猜。
  Future<void> _traceHwnd(String what) async {
    try {
      final int hwnd = await wm.windowManager.getId();
      _trace('$what：本窗口 HWND=0x${hwnd.toRadixString(16)}');
    } catch (e) {
      _trace('$what：取 HWND 失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens tokens = ref.watch(windowTokensProvider);
    final bool wakeChromeAtCenter = ref.watch(windowWakeChromeAtCenterProvider);
    final shikiin.ThemeTokens target = windowThemeTokens(tokens);
    _syncTokenFade(target);

    // 内层 `ProviderScope` 只为了把外观接给播放器：外层（`main.dart`）**不能**覆盖
    // `tokensProvider` —— `shikiinOverrides` 已经覆盖过一次，同容器二次覆盖会撞
    // Riverpod 断言（实测整屏红）。
    // 播放面是 `const`：外观/分组变化只重建这一层，不会卸载它（契约 §5 常驻挂载）。
    return AnimatedBuilder(
      animation: _tokenFade,
      builder: (BuildContext context, Widget? _) {
        return ProviderScope(
          // 不写显式类型：交给 `ProviderScope(overrides: ...)` 的形参上下文推断。
          overrides: [
            shikiin.tokensProvider.overrideWithValue(_shownTokens(target)),
            // 「同名同压制组」播放列表里的其它集是**别的种子**，子窗口没有它们的
            // 串流地址：把"用户点了哪一条"交回主窗口（补磁力→加种→起播）。
            shikiin.episodeSelectProvider.overrideWithValue(_onEpisodeSelected),
            // 切集失败的原因：接给播放面顶在画面上（第三十八轮）。
            shikiin.switchNoticeProvider
                .overrideWith((Ref ref) => ref.watch(windowSwitchNoticeProvider)),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            title: 'DSAnima 播放器',
            theme: buildDsanimaTheme(tokens: tokens),
            themeAnimationDuration: kDsTokenFadeDuration,
            themeAnimationCurve: Curves.easeOutCubic,
            home: Scaffold(
              body: shikiin.PlayerSurface(
                // 弹出播放窗口：标题栏的最大化键 / 双击标题栏**切全屏**，不做原生最大化。
                // 无边框弹窗一旦被最大化就铺满整屏、把主窗口 100% 盖住（用户 2026-10-11
                // 「开启播放器后整个程序都不能用了，什么都点不了整个 DSAnime」）。
                maximizeTogglesFullscreen: true,
                // 「设置 → 播放器 → 画面正中也唤起」（第二十七轮）：主窗口推过来。
                wakeChromeAtCenter: wakeChromeAtCenter,
              ),
            ),
          ),
        );
      },
    );
  }

  /// token 变了就起一次 180ms 的过渡（值没变则不动，避免每次推环境都重启动画）。
  void _syncTokenFade(shikiin.ThemeTokens target) {
    final shikiin.ThemeTokens? to = _tokenTo;
    if (to == target) return;
    _tokenFrom = _shownTokens(to ?? target);
    _tokenTo = target;
    // token 过渡动画：`forward` 的 TickerFuture 只在动画跑完时 resolve，
    // 这里不等它（等也没意义）—— 用 unawaited 写明是**有意丢弃**。
    unawaited(_tokenFade.forward(from: 0));  }

  /// 当前该用的 token：动画中 = 旧→新插值，否则 = 目标值。
  shikiin.ThemeTokens _shownTokens(shikiin.ThemeTokens target) {
    final shikiin.ThemeTokens? from = _tokenFrom;
    final shikiin.ThemeTokens? to = _tokenTo;
    if (from == null || to == null || !_tokenFade.isAnimating) {
      return to ?? target;
    }
    return shikiin.ThemeTokens.lerp(from, to, Curves.easeOutCubic.transform(_tokenFade.value));
  }
}

/// 本窗口的外观（主窗口推过来 → 这里映射成播放器的 token）。
///
/// Riverpod 3 已经没有 `ChangeNotifierProvider`，所以用一个薄 [Notifier] 把
/// `ValueNotifier` 接进来：notifier 变了 → provider 失效 → 播放面**重建**
/// （不会被卸载，契约 §5）。
final Provider<DsTokens> windowTokensProvider = Provider<DsTokens>(
  (Ref ref) => ref.watch(_windowTokensProvider),
);

final NotifierProvider<_NotifierBridge<DsTokens>, DsTokens> _windowTokensProvider =
    NotifierProvider<_NotifierBridge<DsTokens>, DsTokens>(
      () => _NotifierBridge<DsTokens>(windowTokensNotifier),
    );

final Provider<shikiin.EpisodeGroup?> windowEpisodeGroupProvider = Provider<shikiin.EpisodeGroup?>(
  (Ref ref) => ref.watch(_windowGroupProvider),
);

final NotifierProvider<_NotifierBridge<shikiin.EpisodeGroup?>, shikiin.EpisodeGroup?>
_windowGroupProvider =
    NotifierProvider<_NotifierBridge<shikiin.EpisodeGroup?>, shikiin.EpisodeGroup?>(
      () => _NotifierBridge<shikiin.EpisodeGroup?>(windowEpisodeGroupNotifier),
    );

/// 「画面正中也唤起两条栏」（第二十七轮）：与 token/分组同一套 Notifier 桥。
final Provider<bool> windowWakeChromeAtCenterProvider = Provider<bool>(
  (Ref ref) => ref.watch(_windowWakeChromeAtCenterProvider),
);

final NotifierProvider<_NotifierBridge<bool>, bool> _windowWakeChromeAtCenterProvider =
    NotifierProvider<_NotifierBridge<bool>, bool>(
      () => _NotifierBridge<bool>(windowWakeChromeAtCenterNotifier),
    );

/// 切集失败的通知（第三十八轮，主窗口 → 本窗口，见 `kMethodSwitchFailed`）。
///
/// 与 token/分组同一套「ValueNotifier + 桥」的推法：播放面 `PlayerSurface` 读
/// `shikiin.switchNoticeProvider`，本窗口把它接到这条 notifier 上。
final ValueNotifier<shikiin.EpisodeSwitchNotice?> windowSwitchNoticeNotifier =
    ValueNotifier<shikiin.EpisodeSwitchNotice?>(null);

/// 把切集失败通知接给播放面（子窗口的 `ProviderScope` 里 override）。
final Provider<shikiin.EpisodeSwitchNotice?> windowSwitchNoticeProvider =
    Provider<shikiin.EpisodeSwitchNotice?>(
  (Ref ref) => ref.watch(_windowSwitchNoticeProvider),
);

final NotifierProvider<_NotifierBridge<shikiin.EpisodeSwitchNotice?>,
        shikiin.EpisodeSwitchNotice?> _windowSwitchNoticeProvider =
    NotifierProvider<_NotifierBridge<shikiin.EpisodeSwitchNotice?>,
        shikiin.EpisodeSwitchNotice?>(
  () => _NotifierBridge<shikiin.EpisodeSwitchNotice?>(windowSwitchNoticeNotifier),
);

/// 把一个全局 `ValueNotifier` 暴露成 Riverpod 状态（`ValueNotifier` 是
/// `ChangeNotifier`，`addListener` 就是它那套）。
class _NotifierBridge<T> extends Notifier<T> {
  _NotifierBridge(this.source);

  final ValueNotifier<T> source;

  @override
  T build() {
    void listener() => state = source.value;
    source.addListener(listener);
    ref.onDispose(() => source.removeListener(listener));
    return source.value;
  }
}

/// 宿主 token → 播放器 token（与 `state/player_bridge.dart` 同一套映射）。
shikiin.ThemeTokens windowThemeTokens(DsTokens t) => shikiin.ThemeTokens(
  base: t.base,
  raised: t.raised,
  sunken: t.sunken,
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
  // 字号跟宿主正文档走（见 `player_bridge.dart` 同一处说明）。
  fontSize: t.bodySize,
  // 宿主「简洁模式」下不画阴影，播放器跟着不画。
  // 扁平化（第二十九轮）：主窗口不再传阴影 —— 播放窗口的卡片也没有阴影。
  shadowLight: DsTokens.noShadow,
  shadowDark: DsTokens.noShadow,
);

/// 切集失败通知（`kMethodSwitchFailed` 的参数）→ 播放面的 `EpisodeSwitchNotice`。
///
/// 坏参数（不是 Map / 没有 message）返回 null：**绝不因为一条提示解析失败影响播放**。
shikiin.EpisodeSwitchNotice? decodeSwitchNotice(Object? raw) {
  if (raw is! Map) return null;
  final Object? message = raw['message'];
  if (message is! String || message.trim().isEmpty) return null;
  final Object? hint = raw['hint'];
  return shikiin.EpisodeSwitchNotice(
    message: message.trim(),
    hint: hint is String && hint.trim().isNotEmpty ? hint.trim() : null,
  );
}

/// 分组 JSON → 播放器的 `EpisodeGroup`（字段缺失/只有一集就当作没有分组）。
shikiin.EpisodeGroup? decodeEpisodeGroup(Map<Object?, Object?>? map) {
  if (map == null) return null;
  final Object? rawItems = map['items'];
  if (rawItems is! List) return null;
  final List<shikiin.MediaItem> items = <shikiin.MediaItem>[];
  for (final Object? raw in rawItems) {
    if (raw is! Map) continue;
    final Object? path = raw['path'];
    if (path is! String || path.isEmpty) continue;
    final Object? url = raw['streamUrl'];
    final Object? episode = raw['episode'];
    items.add(
      shikiin.MediaItem(
        path: path,
        title: (raw['title'] as String?) ?? path,
        streamUrl: url is String && url.isNotEmpty ? Uri.tryParse(url) : null,
        // 真实集号由宿主算好带过来（播放器不自己解析标题，免同一集两处显示不一样）。
        episode: episode is num ? episode.toInt() : null,
      ),
    );
  }
  if (items.length <= 1) return null;
  final int index = (map['currentIndex'] as num?)?.toInt() ?? 0;
  return shikiin.EpisodeGroup(items: items, currentIndex: index.clamp(0, items.length - 1));
}

/// 关窗请求的**入口**：把原生 `WM_CLOSE` 转给 [_hideSelf]（见那里的说明）。
///
/// ⚠️ 这里**绝不能**调 `window_manager.destroy()`：它在本机 0.5.1 的 Windows 侧就是
/// `PostQuitMessage(0)`（`window_manager.cpp:232`）——一个**进程级**退出请求。
/// 从"独立播放子窗口"里调它，语义上就是错的：它把 `WM_QUIT` 投给处理这次调用的线程，
/// `main.cpp` 的 `GetMessage` 循环一收到就退出，主窗口、托盘、边车一起没。
/// 收窗也不需要它：`windowManager.hide()` 只是 `ShowWindow(SW_HIDE)`；
/// 真要拆掉这一扇窗走 `_destroySelf`（`SC_CLOSE` → `WM_CLOSE` →
/// `DefWindowProc` → `DestroyWindow`，只毁这一扇）。
class _OnClose with wm.WindowListener {
  _OnClose(this._onClose);

  final Future<void> Function(String reason) _onClose;

  @override
  void onWindowClose() {
    shikiin.diag.info('player-window', '窗口收到关闭请求');
    unawaited(_onClose('用户关窗'));
  }
}

/// 窗口被最大化时通知（兜底：这扇窗不许最大化，见 `_undoMaximize`）。
///
/// 为什么还要这一层：`setMaximizable(false)` 挡的是**用户**路径（最大化键 / 拖到屏幕
/// 顶边的 Aero Snap），自绘标题栏那一键也被宿主改成了切全屏；但 `ShowWindow(SW_MAXIMIZE)`
/// 这类**程序化**最大化不受 `WS_MAXIMIZEBOX` 约束。真发生了就立刻退回去，
/// 而不是等着用户来抱怨"整个程序都不能用了"。
class _OnMaximize with wm.WindowListener {
  _OnMaximize(this._onMaximize);

  final Future<void> Function() _onMaximize;

  @override
  void onWindowMaximize() => unawaited(_onMaximize());
}

/// 窗口被移动/缩放**结束**时回一次几何（window_manager 的 Moved/Resized 就是
/// "结束后一次"；再叠一层去抖，拖动过程中不会连发）。
///
/// 用途：用户把播放窗口拖到顺手的位置之后，下次播放还放那儿 ——
/// 主窗口把这份几何落盘（`state/player_window_geometry.dart`）。
class _OnGeometry with wm.WindowListener {
  _OnGeometry(this._report);

  final void Function() _report;

  @override
  void onWindowMoved() => _report();

  @override
  void onWindowResized() => _report();
}
