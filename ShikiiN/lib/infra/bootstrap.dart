import 'package:flutter/services.dart' show rootBundle;
// 仅从 misc.dart 取 Override（Riverpod 3.3 起主库不再导出它）；
// Provider/ProviderScope 等由 app.dart 传递进来。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:ui' show Offset, Size;

import '../app.dart';
import '../controllers/anime4k_controller.dart';
import '../controllers/player_controller.dart';
import '../controllers/settings_controller.dart';
import '../models/app_settings.dart';
import '../models/player_request.dart';
import '../models/theme_tokens.dart';
import '../models/upscale_scheme.dart';
import 'anime4k_assets.dart';
import 'diagnostics/diag.dart';
import 'diagnostics/error_hooks.dart';
import 'file_open_channel.dart';
import 'diagnostics/mpv_log_bridge.dart';
import 'persistence.dart';
import 'window_anim.dart';
import 'window_setup.dart';

/// 播放器运行期实例集合。宿主（DSAnima）拿到它之后注入自己的 `ProviderScope`，
/// 即可在自有外壳里使用播放器的全部能力与 provider。
///
/// 生命周期：`bootstrapPlayer()` 创建 → 宿主 `runApp` → 退出前 [dispose]。
class AppRuntime {
  AppRuntime({
    required this.supportDir,
    required this.store,
    required this.anime4k,
    required this.launchFile,
    this.fileOpenRequests,
    required this.tokens,
    bool lazyPlayer = false,
  }) {
    // 默认（子窗口/单窗口宿主）保持历史行为：启动即建播放器。
    // 主窗口传 `lazyPlayer: true` —— 它从不播放，不该在进程里凭空多一个 mpv 实例
    //（用户 2026-10-10 第二阶段优化 1）。
    if (!lazyPlayer) _player = _createPlayer();
  }

  /// 应用支持目录（日志、shader 都在其下）。
  final Directory supportDir;

  /// 播放器键值存储（续播位置、设置…）。
  final HiveStore store;

  /// Anime4K 超分控制器（已按持久化档位初始化；失败降级为关）。
  final Anime4kController anime4k;

  /// 命令行指定的待播文件（无则 null）。
  final String? launchFile;

  /// 「双击视频 / 二次实例转发」进来的播放请求接收端（见 [bindFileOpenRequests]）。
  ///
  /// * 非 null：把它交给 `shikiinOverrides`（[shikiinOverrides] 在宿主没显式给
  ///   `playerRequests` 时会自动用它）—— 播放面 `PlayerSurface` 监听它；
  /// * null：这个宿主既没有原生投递端、命令行也没给文件（例如 DSAnima 主窗口的
  ///   runner 没实现 `shikiin/file_open`）。
  final PlayerRequestNotifier? fileOpenRequests;

  /// 新拟态 token（契约 §4）：宿主注入它的 DsTokens 同源值；未注入时为
  /// [ThemeTokens.fallback]。宿主用 `shikiinOverrides` 或直接 override
  /// `tokensProvider` 把它给播放面。
  final ThemeTokens tokens;

  PlayerController? _player;

  /// 播放器（media_kit）。**懒创建**：只有真的要用（播放面挂载 / 宿主主动取）
  /// 才会建原生 mpv 实例。
  PlayerController get player => _player ??= _createPlayer();

  /// 播放器是否已经建过 —— 退出落盘时用它避免"为了保存进度反而创建一个 mpv"。
  bool get hasPlayer => _player != null;

  PlayerController _createPlayer() {
    // 真要用播放器了才初始化 media_kit（见 [bootstrapPlayer] 的 lazyPlayer 说明：
    // 主窗口从不播，没必要在那一步加载 libmpv/ANGLE 那套原生件）。
    MediaKit.ensureInitialized();
    final PlayerController p = PlayerController();
    // libmpv warn/error/fatal → Diag（原生崩溃前最值钱线索）。跟随创建时机挂。
    installMpvLogBridge(p.player.stream.log, diag);
    return p;
  }

  bool _disposed = false;

  /// 收尾：只做「安全、可等待」的事。
  ///
  /// **故意不 dispose PlayerController**：libmpv 原生资源拆解在 Windows 上偶发卡顿，
  /// 既有行为是退出时直接结束进程、由操作系统回收。宿主若要干净退出，请先调用
  /// [saveResumePosition] 落盘，再结束进程。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await saveResumePosition();
    await diag.flush();
  }

  /// 关掉键值存储（放掉 `<box>.lock`）。**只给"彻底关闭这一扇窗"用**。
  ///
  /// 用户 2026-10-11 第二阶段清单第 3 项：「关窗时主动释放 Hive 占位锁」。
  /// 语义边界很重要：默认「关闭播放器」= **收起来**（引擎留着、下次秒开），
  /// 那时绝不能关；只有这扇窗真的要消失时，才在 teardown **之前**把锁放掉 ——
  /// teardown 期手里少一个文件句柄与锁，正是前面那两次真机崩溃/卡死想要的状态。
  /// 关掉之后 [saveResumePosition] 直接返回（不会再碰已关的 box）。
  Future<void> closeStore() async {
    _storeClosed = true;
    try {
      await store.close();
      diag.info('bootstrap', 'store closed (lock released)');
    } catch (e, st) {
      diag.warn('bootstrap', 'store close failed', e, st);
    }
  }

  bool _storeClosed = false;

  /// 强制保存当前续播位置（键与 `SettingsController.resumeKey` 完全一致，
  /// 否则既有的续播记录读不出来）。
  ///
  /// 网流（HTTP 串流 URL）同样适用：键基于 URL 文本 + 文件大小（URL 下 lengthSync
  /// 失败 → size 0），同一集的串流地址稳定，续播可生效。
  Future<void> saveResumePosition() async {
    if (_storeClosed) return; // 已经放掉 box（彻底关闭流程）就别再碰它
    final PlayerController? player = _player;
    // 从没建过播放器（主窗口）：不为了落盘去建一个 mpv —— 那也是它该做的事为零。
    if (player == null) return;
    try {
      final path = player.currentPath;
      if (path == null) return;
      final posMs = player.player.state.position.inMilliseconds;
      await store.put(SettingsController.resumeKey(path), posMs);
    } catch (e, st) {
      diag.warn('bootstrap', 'resume flush failed', e, st);
    }
  }
}

/// 初始化播放器运行期（原 `main.dart` 中 `runApp` 之前的全部逻辑）。
///
/// [appId]：Hive 数据目录名（宿主应传自己的产品名）。
/// [boxName]：主键值 box 名。
/// [initWindow]：是否由本函数初始化窗口（内嵌宿主自行管理窗口时传 false，
/// 但 `window_manager` 仍需宿主自己 `ensureInitialized`）。
/// [launchFile]：命令行待播文件；null 表示无。
/// [windowSize] / [windowMinSize]：覆盖初始/最小窗口尺寸（不传则 1100×680 / 640×400）。
/// [tokens]：宿主的新拟态 token（不传则 [ThemeTokens.fallback]）。
/// [dataDir]：Hive 数据目录的**绝对路径**。不传 = `Hive.initFlutter(appId)`
/// （单窗口宿主的默认行为）。多窗口宿主必须给每个引擎**不同**的目录：Hive 的
/// `<box>.lock` 是**排他锁**，第二个引擎开同一个 box 会抛
/// `PathAccessException: lock failed`（实测：子窗口因此白屏 —— 异常发生在
/// `runApp` 之前，连首帧都出不来）。
/// [supportDirPath]：支持目录（日志 + Anime4K shader 的家）的**绝对路径**。
/// 不传 = `getApplicationSupportDirectory()`（Windows = `%APPDATA%\<company>\<product>`）。
/// 便携式宿主（数据跟着程序目录走）应当传，否则日志会落在系统用户目录里。
/// [lazyPlayer]：**不建播放器**（也不在启动时下发 Anime4K 链）。自己从不播放的宿主
/// （例如 DSAnima 的主窗口：只有弹出播放窗口播）传 `true`，省掉一份 mpv 原生实例；
/// 真正播放的窗口（子窗口）保持默认 `false`，行为与历史完全一致。
/// [bindFileOpen]：建「双击视频 / 二次实例转发」的原生接收端
/// （`shikiin/file_open`，见 [bindFileOpenRequests]）。默认开；宿主 runner 没实现这条
/// 通道时会**自动判定为未接通**（记一行 info、返回 null），不影响启动。
Future<AppRuntime> bootstrapPlayer({
  required String appId,
  String boxName = 'shikiin',
  String? launchFile,
  bool initWindow = true,
  bool logToDisk = true,
  bool lazyPlayer = false,
  bool bindFileOpen = true,
  String? dataDir,
  String? supportDirPath,
  Size? windowSize,
  Size? windowMinSize,

  /// 窗口初始位置（逻辑像素，桌面坐标）。多窗口宿主用它把播放窗口放到主窗口旁边，
  /// 而不是居中把主窗口整个盖住（见 [setupWindow]）。
  Offset? windowPosition,

  /// 窗口**允许的最大尺寸**（逻辑像素），转给 [setupWindow] 的 `maxSize`。
  ///
  /// ⚠️ **会连全屏一起夹死**：它落到原生 `WM_GETMINMAXINFO` 的 `ptMaxTrackSize`，
  /// 而那个夹取连 `SetWindowPos` 一起管 —— "真全屏"就是 `SetWindowPos` 到显示器尺寸，
  /// 于是全屏 / 双击画面 / 拖边框拉宽全部失效（2026-10-11 第五轮实测，详见
  /// [setupWindow] 的说明）。DSAnima 的播放窗口**不再传**它。
  Size? windowMaxSize,

  /// 允不允许**原生最大化**（`WS_MAXIMIZEBOX`）。多窗口宿主给播放窗口传 false：
  /// 无边框弹窗一旦被最大化就会铺满整屏、把主窗口 100% 盖住（用户 2026-10-11
  /// 「开启播放器后整个程序都不能用了，什么都点不了」）。自绘标题栏的最大化键
  /// 由宿主自己改成切全屏（见 shikiin 的 `PlayerSurface(maximizeTogglesFullscreen:)`）。
  bool windowMaximizable = true,
  ThemeTokens? tokens,
}) async {
  installErrorHooks(diag); // 早装：连早期异常也走 Diag

  // 支持目录：日志与 Anime4K shader 都落在它下面。
  //
  // 不传时走 `getApplicationSupportDirectory()`（Windows 上是
  // `%APPDATA%\<company>\<product>`）——**多数宿主应该传**：DSAnima 用便携式数据根
  // （数据跟着程序目录走，解压一份就是一套独立设置，见 app/lib/state/store_layout.dart）。
  final Directory supportDir = supportDirPath != null && supportDirPath.trim().isNotEmpty
      ? Directory(supportDirPath)
      : await getApplicationSupportDirectory();
  if (logToDisk) {
    await diag.open(supportDir);
  }
  diag.info('bootstrap', 'shikiin bootstrap start (appId=$appId)');
  if (launchFile != null) diag.info('bootstrap', 'launch with file: $launchFile');

  // 「双击视频 / 二次实例转发 / 命令行带文件」→ 播放请求。
  //
  // 原生侧（`windows/runner/flutter_window.cpp`）一直在 `shikiin/file_open` 上投递
  // （`ready` 握手 + `WM_COPYDATA` 转发），但修前 Dart 侧**没有任何接收方**：
  // `launchFile` 只写上面那行日志、`PlayerRequest.fromLaunchFile` 零调用者 ——
  // 双击视频等于"没反应也不报错"。这里把接收端建起来，并随 [AppRuntime] 交给
  // `shikiinOverrides`（宿主显式传了 playerRequests 时以宿主那份为准）。
  final PlayerRequestNotifier? fileOpenRequests =
      bindFileOpen ? await bindFileOpenRequests(launchFile: launchFile) : null;

  // MediaKit：**只有真会播放的那个引擎才在启动时初始化**。
  //
  // `MediaKit.ensureInitialized()` 在 Windows 上要加载 libmpv 并起 ANGLE/EGL 那套原生件；
  // 真机实测（2026-10-11，`tool/measure_startup.ps1` 30 次）主窗口里这一步之后
  // **约 10% 的启动会 `0xC0000005` 崩掉**，日志正好停在
  // `bootstrap media_kit ok` 与 `bootstrap hive ok` 之间 —— 说明故障来自 media_kit
  // 初始化的原生副作用（子窗口日志里长期有 `Failed to create EGL surface`）。
  // 主窗口从不播放（`lazyPlayer: true`），所以这一步推迟到**真的建播放器**时
  // （见 [AppRuntime._createPlayer]）。真正播放的子窗口保持原样：启动即初始化。
  if (!lazyPlayer) {
    try {
      MediaKit.ensureInitialized();
    } catch (e, st) {
      diag.error('bootstrap', 'MediaKit.ensureInitialized failed', e, st);
    }
  }
  // 启动面包屑（启动期偶发 0xC0000005 只能靠"最后写到哪一行"定位：原生崩溃
  // 是接不住的，Dart 侧看到的就是日志忽然断掉）。这几行是那类崩溃的证据链。
  diag.info('bootstrap', 'media_kit ${lazyPlayer ? 'deferred (this engine never plays)' : 'ok'}');

  if (dataDir != null && dataDir.trim().isNotEmpty) {
    // 多窗口：每个引擎一个目录，避开 Hive 的排他锁（见 [dataDir] 说明）。
    Hive.init(dataDir);
  } else {
    await Hive.initFlutter(appId);
  }
  final store = await HiveStore.open(boxName);
  diag.info('bootstrap', 'hive ok (box=$boxName)');
  if (initWindow) {
    await setupWindow(
      size: windowSize,
      minSize: windowMinSize,
      maxSize: windowMaxSize,
      maximizable: windowMaximizable,
      position: windowPosition,
    );
    disableWindowTransitions(); // 关 DWM 过渡动画：最大化/还原/全屏切换不再顿
    diag.info('bootstrap', 'window ok');
  }

  // 超分：解包 shader（Anime4K + 随包 GLSL 方案）、构造控制器、载入持久化档位。
  // 失败绝不阻断启动。
  //
  // runner 绑到 runtime.player：**懒创建**（先建 runtime 再装 shader 目录，
  // 否则 eager 分支的 setPreset 会在 runtime 赋值前碰到 `late` 变量）。
  late final AppRuntime runtime;
  final anime4k = Anime4kController(
    runner: (List<String> args) => runtime.player.runMpvCommand(args),
    // 仅诊断用：apply 时把硬解状态/像素格式记进日志（LUMA 钩子是否会被旁路）。
    readProperty: (String name) => runtime.player.readMpvProperty(name),
  );
  try {
    final shaderDir = await unpackAnime4kShaders(
      loadAsset: (path) async => (await rootBundle.load(path)).buffer.asUint8List(),
      targetRootDir: supportDir.path,
    );
    anime4k.setShaderDir(shaderDir);
    diag.info('bootstrap', 'anime4k shaders ok');
    final savedSettings = AppSettings.fromMap(store.get('app_settings') as Map?);
    // 方案清单：内置 Anime4K 三档 + Anime4K-Ultra（用户「仅保留anime4k包括u」）。
    // 扩展安装的 GLSL 包在 M3 接进来；mpv 缩放器/ACNet/ARNet/FSR/RCAS 都已按用户要求移除。
    anime4k.setSchemes(builtinUpscaleSchemes());
    final UpscaleSelection savedSelection = UpscaleSelection.fromSettings(
      schemeId: savedSettings.upscaleSchemeId,
      presetName: savedSettings.anime4kPreset.name,
      schemes: anime4k.schemes,
    );
    runtime = AppRuntime(
      supportDir: supportDir,
      store: store,
      anime4k: anime4k,
      launchFile: launchFile,
      fileOpenRequests: fileOpenRequests,
      tokens: tokens ?? ThemeTokens.fallback,
      lazyPlayer: lazyPlayer,
    );
    if (lazyPlayer) {
      // 只记选择：下发会经 runner 去建 mpv —— 而这正是要避免的那份实例。
      anime4k.loadSelection(savedSelection);
    } else {
      await anime4k.setSelection(savedSelection);
    }
    diag.info('bootstrap',
        'anime4k selection ok (${savedSelection.schemeId}/${savedSelection.preset.name}, lazy=$lazyPlayer)');
    return runtime;
  } catch (e, st) {
    diag.warn('bootstrap', 'anime4k init failed (降级为关)', e, st);
  }

  // shader 解包失败也要给出 runtime（超分降级为关，不影响播放）。
  return AppRuntime(
    supportDir: supportDir,
    store: store,
    anime4k: anime4k,
    launchFile: launchFile,
    fileOpenRequests: fileOpenRequests,
    tokens: tokens ?? ThemeTokens.fallback,
    lazyPlayer: lazyPlayer,
  );
}

/// 把 [runtime] 注入 `ProviderScope` 的覆盖列表（契约 §1）。
///
/// 宿主用法：
/// ```dart
/// runApp(ProviderScope(
///   overrides: [
///     ...shikiinOverrides(runtime, playerRequests: requests),
///   ],
///   child: const MyApp(),   // 宿主自有外壳；播放页里常驻挂 PlayerSurface()
/// ));
/// ```
///
/// 没有 `shellBuilder`（宿主自己 runApp），也没有 `CloseHandler`（宿主自有关闭
/// 协调器）。`episodeGroupProvider` 由宿主按需另行 override（默认 null）。
List<Override> shikiinOverrides(AppRuntime runtime, {PlayerRequestNotifier? playerRequests}) => [
  storeProvider.overrideWithValue(runtime.store),
  // ⚠️ 必须用 `overrideWith`（惰性）而不是 `overrideWithValue(runtime.player)`：
  // 后者要**先把实参求值出来**，于是 `runtime.player` 这个懒 getter 当场被调，
  // "主窗口不建 mpv"（`lazyPlayer: true`）立刻失效 —— 真机表现就是主窗口照样在
  // 启动时建一份 mpv/ANGLE 渲染面（日志里 `Failed to create EGL surface`、
  // 以及启动期偶发 `0xC0000005`）。改成惰性之后：读它的那一刻才建。
  playerProvider.overrideWith((ref) => runtime.player),
  anime4kProvider.overrideWithValue(runtime.anime4k),
  tokensProvider.overrideWithValue(runtime.tokens),
  // 宿主显式给的请求通道优先；没有就用启动时建的「原生打开文件」接收端
  // （独立 exe 不传 playerRequests，双击视频/命令行传文件就靠这一条）。
  if ((playerRequests ?? runtime.fileOpenRequests) case final PlayerRequestNotifier requests)
    playerRequestProvider.overrideWithValue(requests),
];
