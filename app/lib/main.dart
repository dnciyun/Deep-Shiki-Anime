/// DSAnima 产品入口。
///
/// 启动顺序（每一步都对应一个真实依赖，失败都有可行动提示）：
/// 1. `WidgetsFlutterBinding.ensureInitialized()` —— **shikiin 的 `bootstrapPlayer`
///    不替宿主调**（见 spec §5.1 与 Lead 通知），必须最先执行；
/// 2. `bootstrapPlayer(appId: 'DSAnima')` —— Hive、窗口、主题、Anime4K、PlayerController；
/// 3. 打开宿主的键值 box（设置、以及将来注入给 core 的 queue/subs box）；
/// 4. `ProviderContainer` + `shikiinOverrides(...)`：把 shikiin 实例、我的外壳、
///    播放请求通道、Hive 存储、支持目录一次注入；
/// 5. `runApp`；随后若这次要起边车，先**有界地**把「首次启动的 tracker 列表」拉一次
///    并落进设置，再异步拉起 rqbit 边车 —— tracker 是边车的进程启动参数，顺序反了
///    就赶不上这次 `start()`（边车启动失败在设置页可见）；
/// 6. 关窗钩子：先保存续播位置 → 停边车 → 结束进程（libmpv 走 OS 回收）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:dsanima_core/sources/kv.dart' show KeyValueStore;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
// shikiin 用前缀导入：它的 `KeyValueStore` / `AppSettings` / `settingsProvider`
// 与宿主自己的同名类型重名（core 的 KeyValueStore 才是宿主要用的那个）。
// `AppShell` 现在由 barrel 导出（Lead 已加），不再深导入。
import 'package:shikiin/shikiin.dart' as shikiin;
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'domain/bangumi.dart' show BangumiClient;
import 'domain/download_dir.dart' show effectiveDownloadDir;
import 'domain/error_text.dart';
import 'domain/models.dart';
import 'domain/window_placement.dart' show kPlayerWindowMinSize;
import 'domain/windows_app_identity.dart';
import 'state/bangumi_meta.dart';
import 'state/bangumi_library.dart';
import 'state/bangumi_recommend.dart';
import 'state/cache_sweep.dart';
import 'state/cover_cache.dart';
import 'state/desktop_integration.dart';
import 'state/engine_bootstrap.dart';
import 'state/extension_schemes.dart';
import 'state/extensions.dart';
import 'state/extensions_adapter.dart';
import 'state/global_failure.dart';
import 'state/hive_store.dart';
import 'state/host_data.dart';
import 'state/library_provider.dart';
import 'state/player_adapter.dart';
import 'state/player_window_geometry.dart';
import 'state/playback.dart';
import 'state/providers.dart';
import 'state/settings_migration.dart';
import 'state/store_layout.dart';
import 'state/tracker_refresh.dart';
import 'state/update.dart';
import 'state/update_adapter.dart';
import 'state/window_close.dart';
import 'ui/player_window_app.dart';

/// 启动装配失败时：把原因**显示出来**，而不是让进程静默消失。
///
/// 用在 `main()` 里那些"失败就没什么可做"的步骤（第一处是打开设置库撞到另一个实例的
/// 锁）。窗口起不来时退回 stderr —— 总之不许静默。
Future<void> showStartupFailure(Object error, StackTrace stackTrace) async {
  final DsFailure failure = describeFailure(error, stackTrace: stackTrace);
  try {
    runApp(DsStartupFailureApp(failure: failure));
    await windowManager.show();
    await windowManager.focus();
  } catch (_) {
    stderr.writeln('DSAnima 启动失败：${failure.message}'
        '${failure.hint == null ? '' : '｜怎么办：${failure.hint}'}');
  }
}

Future<void> main(List<String> args) async {
  // ① shikiin 不替宿主初始化 binding。
  WidgetsFlutterBinding.ensureInitialized();

  // 启动面包屑（`--trace-startup`）：装配根任何一步卡住/抛异常都能定位到具体行，
  // 而不是只看到"窗口是白的"。写 stdout，截图脚本与手动运行都能看到。
  final bool traceStartup = args.contains('--trace-startup');
  void trace(String step) {
    if (traceStartup) stdout.writeln('[startup] $step');
  }

  // 同一个面包屑也写进 diag 日志（见下面 bootstrapPlayer 之后的说明）。
  void startup(String step) {
    trace(step);
    try {
      shikiin.diag.info('startup', step);
    } catch (_) {
      // 日志还没打开时（bootstrap 之前）忽略。
    }
  }

  // 未捕获的框架异常也打出来：白窗排查全靠它。
  //
  // 第四十二轮（`docs/ROUND42-UX.md` §2.1）：**不再只写 stderr**。只写 stderr 意味着
  // "漏包的 await 抛错"对用户是彻底静默的（不弹东西、界面停在原处），本轮 14 处
  // "失败不浮出"都借着这个前提。现在同一条异常还会经 `reportGlobalFailure` 广播出去，
  // 由 `DsGlobalFailureListener` 弹成一条带「怎么办」的失败提示。
  FlutterError.onError = (FlutterErrorDetails d) {
    stderr.writeln('[flutter-error] ${d.exception}');
    stderr.writeln(d.stack);
    reportGlobalFailure(d.exception, d.stack ?? StackTrace.current);
    FlutterError.presentError(d);
  };
  PlatformDispatcher.instance.onError = (Object e, StackTrace s) {
    stderr.writeln('[uncaught] $e');
    stderr.writeln(s);
    reportGlobalFailure(e, s);
    return false;
  };
  trace('binding ok');

  // 「我是播放子窗口吗？」——用户 2026-10-10 的硬要求：只有弹出窗口播放。
  // 子窗口是独立 Flutter 引擎，走一条**只做播放**的极简装配路径。
  final PlayerWindowArgs? playerWindowArgs = await detectPlayerWindowArgs();
  if (playerWindowArgs != null) {
    trace('child window: player');
    await _runPlayerWindow(playerWindowArgs, trace);
    return;
  }

  // 组件总览页（决策 A36）：`--preview` 或 `DSANIMA_PREVIEW=1`。
  // 用于「先看风格再铺页面」，以及后续任何人改 token 时一页看回归。
  final bool previewMode =
      args.contains('--preview') || (Platform.environment['DSANIMA_PREVIEW'] ?? '') == '1';

  // 数据根目录：**便携式**（用户 2026-10-11：「解压出来就是初始化的程序，一套文件夹
  // 一套设置，不在本地留垃圾」）。解析规则见 state/store_layout.dart：
  //   DSANIMA_DATA_DIR 环境变量 > `<exe目录>\DSAnima-data`（可写时）> %APPDATA%\...
  final DataRoot dataRoot = await resolveDataRoot();
  final Directory supportDir = Directory(dataRoot.path);
  startup('数据根目录 = ${dataRoot.path}（portable=${dataRoot.portable}'
      '${dataRoot.fallbackReason == null ? '' : '，原因：${dataRoot.fallbackReason}'}）');

  // 旧版本写在系统用户目录里的东西（%APPDATA%\com.dsanima\...、文档\DSAnima、
  // %LOCALAPPDATA%\rqbit 的 DHT 缓存）新版一个字都不读了：清掉，别在用户机器上留垃圾。
  // 绝不碰数据根目录自己（比真实路径，见单测）。
  try {
    final LegacyCleanup cleanup = await cleanupLegacyDataLocations(dataRoot: supportDir);
    if (cleanup.changed) {
      startup('清掉旧版数据位置 ${cleanup.removed.length} 处：${cleanup.removed.join(' | ')}');
    }
  } catch (error) {
    startup('旧版数据位置清理失败（不影响启动）：$error');
  }

  // `dataDir` / `supportDirPath`：Hive 与「日志 + Anime4K shader」都落在数据根目录下。
  final shikiin.AppRuntime runtime = await shikiin.bootstrapPlayer(
    appId: 'DSAnima',
    initWindow: true,
    lazyPlayer: true,
    dataDir: storeDirOf(supportDir).path,
    supportDirPath: supportDir.path,
    // 主窗口**不传** `extraSchemes`：它 `lazyPlayer: true`、不建 mpv，超分方案只对
    // 「播放子窗口」有意义（子窗口自己扫，见 `_runPlayerWindow`）。这里传只会让启动
    // 多一次目录扫描（1.1.0 M4/T18 正在砍启动路径，不在这上面花时间）。
  );
  // 启动面包屑**写进日志文件**（不只是 stdout）：启动期偶发 `0xC0000005` 时
  // 进程直接没了，stdout 也一起没 —— 只有已经落盘的那几行能说明"死在哪一步"。
  // 用户 2026-10-09~11 一直有这个偶发崩溃（约 2%），这几行就是给它准备的证据链。
  startup(
    'bootstrapPlayer ok (supportDir=${runtime.supportDir.path}, '
    'player=${runtime.hasPlayer ? 'created' : 'lazy'})',
  );

  // ③ 宿主自己的键值存储（core 的 KeyValueStore 抽象，Hive 实现）。
  // 具体类型不能写成 `KeyValueStore`：退出时要 `close()` 把 `dsanima.lock` 放掉
  // （用户 2026-10-12 第 10 轮：窗口秒关之后进程还会活一两秒，锁不提前放，
  //  用户这两秒里双击重开会撞 `lock failed`）。
  //
  // ⚠️ **这一句必须自己接住失败**（审查发现的"双击没反应"）：后台常驻开着的时候再起一个
  // 实例（或上一个进程还没退干净）时锁被占着，`open()` 抛 `PathAccessException`；
  // 旧代码让异常从 `main()` 冒出去 → 进程结束、窗口起不来，用户双击图标看到的是
  // **什么都没有**。现在改成把原因显示在一个最小窗口里再结束。
  final HiveKeyValueStore appStore;
  try {
    appStore = await HiveKeyValueStore.open('dsanima');
  } catch (error, stackTrace) {
    startup('appStore 打开失败：$error');
    await showStartupFailure(error, stackTrace);
    return;
  }
  trace('appStore ok');
  startup('appStore ok');

  // 播放请求通道：**只有弹出播放窗口用**（用户 2026-10-10：主窗口任何地方都不播）。
  //
  // `logger` 把主窗口这一侧的播放窗口事件写进 shikiin 的日志：用户 2026-10-11 报
  // 「关掉播放器后主窗口卡死」，只有日志能说明主窗口到底走到哪一步（收到窗口列表
  // 事件没有 / 子窗口回话没有）。`bindSelf()` 注册的是**主窗口自己**那条通道 ——
  // 子窗口收起自己时要能从反方向通知主窗口（插件的 unidirectional 通道）。
  //
  // `placeWindow` 只回答一件事：**这一次播放窗口该出现在哪**。
  // 2026-10-12（第七轮）的默认答案是"工作区正中间"（用户原话：「播放器应该在中心位置出现」），
  // 用户自己拖过的位置优先（见 state/player_window_geometry.dart）。
  //
  // ⚠️ 这条路**不再动主窗口**。第四轮为了给播放窗口腾地方，曾经在主窗口最大化时先把它
  // `unmaximize()` 降回还原尺寸（收起播放器时再 `maximize()` 还原）—— 用户 2026-10-12 报的
  // 「点开播放后为什么会取消主窗口的最大化」就是那一步。用户自己的窗口状态不该被我们改掉；
  // 而落点改成居中之后，"腾地方"本身也没有意义了，所以那条路连同 `restoreMainWindow`
  // 一起删掉。
  final PlayerWindowService playerWindow = PlayerWindowService(
    logger: (String message) => shikiin.diag.info('player-window', message),
    placeWindow: () => playerWindowPlan(
      appStore,
      log: (String message) => shikiin.diag.info('player-window', message),
    ),
    saveGeometry: (Rect rect) => savePlayerWindowBounds(appStore, rect),
  );
  await playerWindow.bindSelf();
  startup('bindSelf ok（主窗口通道）');

  // 桌面集成：真托盘 + 真系统通知（spec §7.3 Q14/Q16）。
  // 托盘图标必须是**真 .ico 文件路径**（Windows 的 tray_manager 走 LoadImage/LR_LOADFROMFILE）。
  final String? trayIconPath = await materializeTrayIcon(runtime.supportDir.path);
  final TrayManagerPort trayPort = TrayManagerPort(
    backend: TrayManagerBackend(),
    iconPath: trayIconPath ?? '',
  );
  final LocalNotifierPort notifierPort = LocalNotifierPort(LocalNotifierBackend());
  // ⚠️ 第一个通知之前必须 setup，否则会静默不弹（实测坑）。
  await notifierPort.initialize(appName: 'DSAnima');
  trace('notifier ok');
  startup('notifier ok');

  // 边车运行期持有者 + core 适配（装配根专有；UI/state 层只认端口抽象）。
  final EngineRuntimeHolder engineHolder = EngineRuntimeHolder();
  final CoreEnginePort enginePort = CoreEnginePort(engineHolder);

  // 宿主数据层：源注册表（nyaa/mikan/自定义 RSS）+ 订阅存储 + 队列管理器。
  // ⚠️ 一次性迁移**必须排在读设置之前**（第三十三轮：观看记录默认 30 天 → 不删）：
  // 迁移改的就是盘上那份 JSON，先读后迁会让这一进程仍按旧默认跑。
  // 用户：「历史记录从默认30天改为不删」。只动"旧默认值 30"，手选过 7/90 的不动。
  await migrateHistoryRetentionToNeverDelete(appStore);
  final AppSettings bootSettings = readSettings(appStore);
  // 调试/自动化开关：`--skip-first-run` 直接跳过首启向导（CI 冒烟、真机截图用）。
  // 只在进程参数里显式给出时生效，**不写回设置**，所以下次正常运行仍会走向导。
  final bool skipFirstRun = args.contains('--skip-first-run');
  // `--theme=light|dark`：只覆盖**本次进程**的外观，用于浅/深两套的截图对比。
  // 与 `--anime4k=` 同一风格：只在 `--skip-first-run` 下生效，不写回用户设置。
  final String themeArg = skipFirstRun
      ? args.firstWhere((String a) => a.startsWith('--theme='), orElse: () => '')
      : '';
  final String? themeOverride = themeArg.isEmpty
      ? null
      : (themeArg.substring('--theme='.length).trim() == 'dark' ? 'dark' : 'light');
  final AppSettings effectiveSettings = skipFirstRun
      ? bootSettings.copyWith(
          firstRunCompleted: true,
          complianceAccepted: true,
          themeId: themeOverride ?? bootSettings.themeId,
          // 截图/冒烟环境里也得让边车起得来，否则主页只能看到「未连接」。
          downloadDir:
              bootSettings.downloadDir ??
              p.join(runtime.supportDir.path, 'dsanima', 'debug-downloads'),
        )
      : bootSettings;
  final HostDataHolder hostData = HostDataHolder();

  // 第五十一轮：**三个 Bangumi 服务共用同一个客户端**（今日推荐 / 动漫库 / 元数据）。
  //
  // 为什么（用户 2026-10-17：「动漫库 bangumi 接口返不回来了，能不能做多个虚拟 ip
  // 访问」）：以前三个服务各 new 一个 `BangumiClient`，每条各有自己的 1.1s 限速闸门 ——
  // 主页的推荐窗口与动漫库的翻页同时开跑时，出站节奏可以逼近 3 次/秒。Bangumi 的公开
  // 接口对频率敏感（第三方监控 bgm-status.ry.mk 上 api.bgm.tv 的 down 记录里有相当一部分
  // 是超时），把自家 IP 玩进限流后再去轮换出口 IP 只会更糟。共用一条闸门，全进程的
  // Bangumi 请求按**每秒最多一次**排队，是"不给自己惹限流"的正解。
  //
  // 放在这里而不是某个 provider 里：三个服务在下面同一张 overrides 表里注入，
  // 手工传同一个实例最直白；`BangumiClient` 只在 app 生命周期内使用，退出进程即回收。
  final BangumiClient bangumiClient = BangumiClient();

  // 封面缓存：磁盘缓存 + **内存索引**（第三十七轮）。
  //
  // 为什么在这里建：`warmUp()` 必须在**启动清扫之后**跑（清扫会把过期文件删掉，
  // 先预热就会把已删的文件留在索引里），而"清扫 + 预热"又都不该挡首帧 ——
  // 所以两件事都丢进下面那个 `unawaited(...)` 里，顺序由那里保证。
  final HttpCoverCache coverCache =
      HttpCoverCache(cacheDir: coverCacheDirOf(runtime.supportDir));

  hostData.attach(
    HostDataRuntime(
      holder: hostData,
      store: appStore,
      enginePort: enginePort,
      torrentPort: QueueEngineBridge(engineHolder),
      settings: effectiveSettings,
      supportDir: runtime.supportDir,
    ),
  );
  await hostData.runtime!.init();
  trace('hostData ok');
  startup('hostData ok');
  startup('container 之前');

  // 更新端口的 HTTP 工厂要**每次请求现读设置**（代理改了当场生效），而设置只有
  // 容器能读 —— 容器又在下面才建出来。所以先留一个格子，建好之后立刻填上；
  // 那个闭包只在用户点「检查更新」时才会跑，那时格子早就填好了。
  ProviderContainer? liveContainer;

  final ProviderContainer container = ProviderContainer(
    // 不写显式类型：交给 `ProviderContainer(overrides: ...)` 的形参上下文推断即可。
    overrides: [
      // 播放器运行期注入（契约 §1：宿主自己 runApp，不再传 shellBuilder）。
      // ⚠️ 主窗口**不需要**播放请求通道：只有弹出窗口播放（用户 2026-10-10），
      // 主窗口既不挂播放面也不 new mpv，所以这里不给 `playerRequests`。
      ...shikiin.shikiinOverrides(runtime),
      // 宿主自己的端口
      // `--skip-first-run` 时换成**预置好的内存 store**：SettingsController 是从
      // keyValueStoreProvider 读设置的，不换这个就只改了 hostData、向导照样弹。
      // 用内存实现意味着「调试开关不会污染用户真实设置」。
      keyValueStoreProvider.overrideWithValue(
        skipFirstRun ? _debugStore(effectiveSettings, appStore) : appStore,
      ),
      supportDirProvider.overrideWithValue(runtime.supportDir),
      pickerPortProvider.overrideWithValue(const FilePickerPort()),
      enginePortProvider.overrideWithValue(enginePort),
      engineBootstrapPortProvider.overrideWithValue(CoreEngineBootstrap(engineHolder)),
      // 播放只走弹出窗口：宿主这一侧的播放器端口 = 跨窗口投递。
      playerWindowServiceProvider.overrideWithValue(playerWindow),
      playerPortProvider.overrideWith(
        (Ref ref) => PlayerWindowPort(
          service: ref.watch(playerWindowServiceProvider),
          readTokens: () => ref.read(themeTokensProvider),
          // 第二十七轮：新开的那扇窗也要知道「画面正中也唤起」的当前设置。
          readWakeChromeAtCenter: () => ref.read(settingsProvider).wakeChromeAtCenter,
        ),
      ),
      // 源 / 订阅 / 队列 / 主页追番表：core 真实现
      sourcePortProvider.overrideWithValue(hostData.runtime!.sourcePort),
      subsPortProvider.overrideWithValue(hostData.runtime!.subsPort),
      queuePortProvider.overrideWithValue(hostData.runtime!.queuePort),
      schedulePortProvider.overrideWithValue(hostData.runtime!.schedulePort),
      hostDataPortProvider.overrideWithValue(CoreHostDataPort(hostData)),
      // 源表版本号：设置页重建注册表 / 订阅源增删时 +1，让源下拉**当场重算**
      //（用户 2026-10-12 第 10 轮：「sukebe设置打开要重启，不能热加载」）。
      sourceRevisionProvider.overrideWithValue(hostData.sourceRevision),
      // 封面图磁盘缓存（mikan 图床 + Bangumi 图床共用；按响应真实格式定扩展名）。
      // 路径由 `coverCacheDirOf` 给：设置页的「立即清理」用**同一个函数**，别各写一份。
      // 第三十七轮：这个实例还要**预热内存索引**（`warmUp`），所以先建出来存成局部变量 ——
      // 详见下面 `_sweepCoverCacheAtStartup` 末尾那一步。
      coverCacheProvider.overrideWithValue(coverCache),
      // 今日推荐：Bangumi 全年代随机 5 部（结果按天缓存，封面走上面的磁盘缓存）。
      // 第五十一轮：与动漫库/元数据共用 `bangumiClient`（同一条 1.1s 限速闸门）。
      recommendPortProvider.overrideWithValue(
        BangumiRecommendPort(store: appStore, client: bangumiClient),
      ),
      // 动漫库（第三十三轮）：按筛选条件翻页浏览 Bangumi 全库 + 条目详情。
      // 页结果只在进程内缓存 10 分钟（浏览是"来回翻页"的动作，重复请求没有意义）；
      // 条目详情额外落盘（`dsanima.bangumi.subject.<id>`），重复点同一部不再等网络。
      bangumiLibraryProvider.overrideWithValue(
        BangumiLibraryService(store: appStore, client: bangumiClient),
      ),
      // Bangumi 元数据服务（spec §7.8，7 天磁盘缓存，失败静默降级）。
      // ⚠️ 2026-10-12 起**没有任何页面读它**：番剧详情页去掉了「Bangumi 元数据」块
      //（用户：「首页点开的不要加载 bangumi 了，只用 mikan 的就好」）。
      // 注入保留着，是因为它同时也是 `bangumi_meta_test.dart` 与 spec §7.8 的实现；
      // 要是哪天再需要按番名匹配（例如追番页显示评分），直接用这个 provider，别再另起一套。
      bangumiMetaProvider.overrideWithValue(
        BangumiMetaService(store: appStore, client: bangumiClient),
      ),
      // 桌面集成（真托盘 / 真通知）
      trayPortProvider.overrideWithValue(trayPort),
      notificationPortProvider.overrideWithValue(notifierPort),
      // 检查更新（第三十九轮）：GitHub Releases + 解压覆盖安装 + 重启。
      // * 工作目录在数据根下面（`<数据根>/update`：下载的 zip、脚本、日志、待办记录），
      //   删掉数据根 = 干净卸载，不留别处的垃圾；
      // * 覆盖目标 = **本 exe 所在目录**（便携式：程序目录就是安装目录）；
      // * HTTP 要接「设置 → 网络」的代理：GitHub 直连在很多网络里不通，
      //   而那一格就是用户唯一会去配的地方。每次请求现读设置 → 改代理当场生效。
      updatePortProvider.overrideWithValue(
        GitHubUpdatePort(
          workDir: Directory(p.join(runtime.supportDir.path, 'update')),
          installDir: File(Platform.resolvedExecutable).parent,
          clientFactory: () => core.IoHttpClientFactory(
            proxy: coreProxyConfig(liveContainer!.read(settingsProvider)),
          ).create(),
        ),
      ),
      // 扩展（1.1.0 M3）：装到 `<数据根>/extensions`（便携式：删数据根 = 干净卸载）。
      // 下载走与「检查更新」**同一条代理设置**（每次请求现读，改代理当场生效）；
      // 安装的语义（staging/校验/原子替换/卸载进回收站）全在适配器里，见
      // `domain/extensions_port.dart` 文件头的 6 条契约。
      extensionsPortProvider.overrideWithValue(
        ExtensionsAdapter(
          root: Directory(p.join(runtime.supportDir.path, 'extensions')),
          clientFactory: () => core.IoHttpClientFactory(
            proxy: coreProxyConfig(liveContainer!.read(settingsProvider)),
          ).create(),
        ),
      ),
      // 注意：播放页挂什么由**播放页自己**决定（`PlayerSurface`，契约 §5 要求常驻）。
      // 旧的 `playerSurfaceBuilderProvider` 已随 `AppShell` 一起删除（决策 B40）。
    ],
  );
  liveContainer = container;

  // 扩展页装/卸/启停成功 → 立刻通知**已经打开的**播放窗口重扫超分方案
  // （1.1.0 第六十四轮，用户实测：「删除扩展后，超分里的 anime4k-mini 不会消失，
  // 只有重启后才会没」）。不通知的话，那份清单要等下次开窗才更新；这里监听扩展版本号
  // （`ExtensionsController` 在装/卸/启停成功时 +1），没有播放窗口时那一次通知是空操作。
  container.listen<int>(
    extensionsRevisionProvider,
    (int? previous, int next) => unawaited(playerWindow.notifyExtensionsChanged()),
  );

  trace('runApp');
  startup('container ok → runApp');
  // 播放列表里点了一条（子窗口只报 id，见 `kMethodEpisodeSelect`）：交给宿主那条
  // 唯一开播链路 —— 补磁力 → 加种 → 投递播放请求。容器建好之后才接得上。
  playerWindow.onEpisodeSelected =
      (String itemId) => container.read(playbackProvider.notifier).playPlaylistEntry(itemId);
  // 子窗口报上来的播放进度（`kMethodWatchProgress`，第二十七轮）：观看记录 + 自动打勾。
  playerWindow.onWatchProgress =
      (Object? raw) => container.read(playbackProvider.notifier).onWatchProgress(raw);
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: skipFirstRun
          // 调试/自动化档才挂点击探针（见 [_PointerProbe]）；正常运行不写这一行日志。
          ? _PointerProbe(child: DsanimaApp(previewMode: previewMode))
          : DsanimaApp(previewMode: previewMode),
    ),
  );

  // 主窗口心跳（排障）：用户 2026-10-11 报「关掉播放器后主窗口卡死」。
  // 「卡死」有两种完全不同的成因，得用两种手段分别判定：
  // * **消息泵停了**（平台线程阻塞）→ `SendMessageTimeout(WM_NULL)` 能测出来；
  // * **Dart isolate 卡住**（平台线程照常转、界面不再重绘）→ 只能看"它还在写日志吗"。
  // 默认 60s 一行（一天 ~1.4k 行，可接受）；`--skip-first-run` 下可用
  // `--heartbeat-ms=N` 加速到毫秒级给真机探针用，且不写回用户设置。
  final String hbArg = skipFirstRun
      ? args.firstWhere((String a) => a.startsWith('--heartbeat-ms='), orElse: () => '')
      : '';
  final int heartbeatMs = hbArg.isEmpty
      ? 60000
      : (int.tryParse(hbArg.substring('--heartbeat-ms='.length).trim()) ?? 60000);
  if (heartbeatMs > 0) {
    int ticks = 0;
    Timer.periodic(Duration(milliseconds: heartbeatMs), (Timer _) {
      ticks++;
      try {
        shikiin.diag.info('heartbeat', 'main isolate alive #$ticks');
      } catch (_) {
        // 心跳失败不该影响任何东西（诊断都是尽力而为）。
      }
    });
  }
  // 这里的 `downloadDir` 是**生效值**（不是原始设置值）：
  // 用户 2026-10-11：「下载目录默认在 C:\Users\用户名\Downloads\Anime」——
  // 设置里没填过就用这个默认值（解析规则见 `domain/download_dir.dart`），
  // 原始值可能一直是 null，所以必须先解析再判空。
  final String downloadDir = effectiveDownloadDir(effectiveSettings.downloadDir);
  // 排障/截图/自动化验证开关（仅在 `--skip-first-run` 下生效，不污染真实使用）：
  //   `--tab=settings`       直接落到指定页面
  //   `--anime4k=standard`   启动即把超分档位设到指定档（走 Anime4kController 真实路径）
  //   `--play=<路径或URL>`    启动即投递一条真实播出请求（与「立即播放」同一条链路）
  // 后两个是为了把「内置 Anime4K 在真视频上真的生效」验到菜单层（见 spec §8.6）：
  // 单靠 asset 进包与 shader 编译探针，盖不住「控制器有没有在真实播出时把链挂上」。
  if (skipFirstRun) {
    final String tabArg = args.firstWhere((String a) => a.startsWith('--tab='), orElse: () => '');
    if (tabArg.isNotEmpty) {
      final String want = tabArg.substring('--tab='.length);
      for (final ShellTab tab in ShellTab.values) {
        if (tab.name == want) {
          container.read(navProvider.notifier).select(tab);
          break;
        }
      }
    }

    // 超分档位：**只走 Anime4kController.setPreset**（与右键菜单/面板切档同一入口）。
    final String a4kArg = args.firstWhere(
      (String a) => a.startsWith('--anime4k='),
      orElse: () => '',
    );
    if (a4kArg.isNotEmpty) {
      final String want = a4kArg.substring('--anime4k='.length).trim();
      final shikiin.Anime4kPreset? preset = shikiin.Anime4kPreset.values
          .where((shikiin.Anime4kPreset p) => p.name == want)
          .firstOrNull;
      if (preset == null) {
        stderr.writeln(
          '[debug] --anime4k=$want 不是合法档位；可用：'
          '${shikiin.Anime4kPreset.values.map((shikiin.Anime4kPreset p) => p.name).join(', ')}',
        );
      } else {
        // 此刻还没载入视频，setPreset 会先落 clr；真正挂链靠播出时的
        // exitSwitchWindow(reapply: true) —— 这正是要验的那条路径。
        unawaited(runtime.anime4k.setPreset(preset));
        stdout.writeln('[debug] --anime4k=${preset.name} 已下发（待播出时补发链）');
      }
    }

    // 真实播出：直接开播放窗口投一条请求（与点「立即播放」走同一个窗口通道，
    // 只是不经过队列/引擎解析 —— `--play=<本地文件或URL>` 是排障入口）。
    //
    // ⚠️ 走 `debugPlayUrl`（不是直接 `playerWindow.open`）：它**同时写 `nowPlaying`**，
    // 否则主窗口里那些「正在播放」的 UI（侧栏左下角那行「继续播放」）在探针里永远
    // 不出现，真机截图拍不到（第十七轮为了给那一行拍图才补的）。
    final String playArg = args.firstWhere((String a) => a.startsWith('--play='), orElse: () => '');
    if (playArg.isNotEmpty) {
      final String uri = playArg.substring('--play='.length);
      if (uri.isNotEmpty) {
        unawaited(
          container.read(playbackProvider.notifier).debugPlayUrl(
                uri,
                title: p.basenameWithoutExtension(uri),
              ),
        );
        stdout.writeln('[debug] --play=$uri 已投递播出请求（弹出播放窗口）');

        // `--replay-after-ms=N`：N 毫秒后再投一次**同一条**请求。
        //
        // 用途只有一个：真机验证「关掉播放器 = 收起来 → 再点播放 = 秒开」这条新路
        //（默认关闭不再拆引擎，所以"重新打开"必须复用同一扇窗并把它 show 出来）。
        // 只读参数、不写回设置，与 `--play` 同一档调试开关。
        final String replayArg = args.firstWhere(
          (String a) => a.startsWith('--replay-after-ms='),
          orElse: () => '',
        );
        final int replayMs = replayArg.isEmpty
            ? 0
            : (int.tryParse(replayArg.substring('--replay-after-ms='.length).trim()) ?? 0);
        if (replayMs > 0) {
          Timer(Duration(milliseconds: replayMs), () {
            unawaited(
              playerWindow.open(
                PlayerWindowArgs(
                  streamUrl: uri,
                  title: p.basenameWithoutExtension(uri),
                  tokens: encodeTokens(container.read(themeTokensProvider)),
                ),
              ),
            );
            stdout.writeln('[debug] 第二次投递 --play（验"收起 → 唤回"）');
          });
        }
      }
    }
  }
  // ⑤ 边车启动**之前**：tracker 首次启动自动加载一次（用户 2026-10-11）。
  //
  // 为什么必须排在这里：引擎的 tracker 是**进程启动参数**（`--trackers`），
  // 只有 `AppSettings.extraTrackers` 先落进设置，紧接着那次 `start()` 才带得上。
  // 原来这一支排在边车之后，而首次启动时边车还没起（下载目录为空的首次运行甚至不起），
  // 抓回来的列表就赶不上 `start()` —— "自动加载一次"看着像没生效。
  // 只在**从没更新过**（`trackerListUpdatedAt == null`）时才真的等网络
  //（整轮上限 20s，见 state/tracker_refresh.dart 的 ensureTrackersAtStartup）；
  // 已经更新过就立刻返回 skipped，不推迟引擎启动。
  final bool willStartEngine = downloadDir.trim().isNotEmpty;
  final TrackerRefreshOutcome trackerPreload = willStartEngine
      ? await ensureTrackersAtStartup(container)
      : const TrackerRefreshOutcome.skipped();
  if (trackerPreload.due) {
    startup('tracker 首次启动预载：updated=${trackerPreload.updated}｜${trackerPreload.note}');
  }

  // 有下载目录就拉起边车（首启向导没走完时保持未连接状态，UI 会说明原因）。
  if (willStartEngine) {
    unawaited(
      container.read(engineBootstrapProvider.notifier).start(
        // ⚠️ 用容器里的**当前**设置，而不是上面那份 `effectiveSettings` 快照：
        // 预载可能刚把新拉到的 `extraTrackers` 写进去，用快照等于把刚拉到的列表丢了
        //（这正是"自动加载一次没生效"的另一半原因）。
        settings: container.read(settingsProvider),
        supportDir: runtime.supportDir,
      ),
    );
  }

  // 封面缓存自动清理（用户 2026-10-11 第二阶段清单第 7 项）：启动后空闲时清一次过期的。
  // 周期取设置里的 `coverCacheMaxAgeDays`（0 = 不清除）；设置页的「立即清理」是同一个函数。
  // 放在 runApp 之后且不 await：清理慢一点也不该拖慢首帧。
  // 第三十七轮：**清完再预热内存索引**（同一个函数末尾做），于是"已落盘的封面当帧直出"
  // 从上一次启动的第一个页面就生效。
  unawaited(_sweepCoverCacheAtStartup(effectiveSettings, runtime.supportDir, coverCache));
  // KV 里的源缓存 / 推荐缓存也是"只涨不减"（core 只按 TTL 判读，条目永不删除）：
  // 同一时机按龄 + 条数上清扫一次（见 state/cache_sweep.dart）。
  unawaited(_sweepHostCachesAtStartup(appStore));

  // tracker **每日自动刷新**（用户 2026-10-11：「tracker加入每日刷新一次逻辑」）。
  //
  // 为什么要自动：公共 tracker 列表是社区每天更新的，而引擎的 tracker 是**进程启动
  // 参数** —— 用户不手动点一次、不重启边车，列表就永远停在装机那天。
  // 不 await：联网最多 20s，绝不能挡首帧；真的换到新列表而且边车在跑时，这行内部会
  // 重启边车让新参数生效（见 state/tracker_refresh.dart）。
  // ⚠️ 只有"上面那次预载压根没试"才走这里（`due == false` = 未到期或刚更新过）：
  // 预载已经打过一轮网络（不管成没成）时再补一次，就是同一个启动里白拉两次
  //（拉失败时 `trackerListUpdatedAt` 仍是 null，它下一次启动还会再试）。
  if (!trackerPreload.due) {
    unawaited(
      refreshTrackersAtStartup(container).then((TrackerRefreshOutcome outcome) {
        startup('tracker 每日刷新：updated=${outcome.updated}｜${outcome.note}');
      }),
    );
  }

  // ⑥ 关窗：按「后台常驻」决定询问/直接退出；托盘可用时隐藏并可从托盘唤回。
  final CloseCoordinator closeCoordinator = CloseCoordinator(
    runtime: runtime,
    container: container,
    engineHolder: engineHolder,
    hostData: hostData,
    // 退出时靠它 flush + 放掉 dsanima.lock（见 window_close.dart 的 _closeStores）。
    appStore: appStore,
  );
  windowManager.addListener(closeCoordinator);
  await windowManager.setPreventClose(true);
  unawaited(closeCoordinator.bindTray());
  // ⑦ 检查更新要用「立刻退出」这条路：覆盖脚本正等着本进程消失，而退出必须按
  //    上面⑥那套顺序走（先放 Hive 锁 → 再停边车）。登记进去，设置页那颗
  //    「立即重启并更新」才点得动（没登记时会抛，绝不假装已退出）。
  container.read(quitAppProvider).register(closeCoordinator.quit);
  startup('关窗协调器 + 托盘已接上（startup 走完）');
}

/// 启动时的封面缓存清理（尽力而为，绝不抛）。
///
/// 为什么需要：`HttpCoverCache.maxAge`（7 天）只管"过期就重新下载"，**过期文件从来
/// 不删** ⇒ `<支持目录>/cache/covers` 只涨不减。这里按用户选的周期清一次。
///
/// 另外无条件跑一次 [sweepLegacyThumbnailCovers]：第二十轮把封面从 `/r/100/`（100px 的
/// `images.grid`）改成按显示尺寸取档，盘上那批 100px 小图再也不会被请求 —— 与"定期清理
/// 周期"（甚至用户选的"不清除"）无关，这是升级迁移，顺手清掉。**第三十一轮**同理：
/// mikan 封面一律去掉会裁成正方形的 `height` 参数，盘上那批 400×400 的方图也成了死重量。
Future<void> _sweepCoverCacheAtStartup(
  AppSettings settings,
  Directory supportDir,
  HttpCoverCache cache,
) async {
  final Directory dir = coverCacheDirOf(supportDir);
  try {
    final CoverCacheSweep legacy = await sweepLegacyThumbnailCovers(dir);
    if (legacy.deleted > 0) {
      shikiin.diag.info(
        'startup',
        '清掉旧的封面（100px 小图 / 被裁成正方形的 mikan 方图）：'
        '${legacy.deleted} 张 / ${legacy.bytes} 字节',
      );
    }
  } catch (_) {
    // 迁移清理失败不影响任何功能（它只是省点盘）。
  }
  final int days = settings.coverCacheMaxAgeDays;
  if (days > 0) {
    try {
      final CoverCacheSweep sweep = await sweepCoverCache(dir, maxAge: Duration(days: days));
      if (sweep.deleted > 0) {
        shikiin.diag.info('startup', '封面缓存清理：${sweep.deleted} 张 / ${sweep.bytes} 字节（周期 $days 天）');
      }
    } catch (_) {
      // 缓存清理不是功能主路径，失败静默（下次启动再试）。
    }
  }
  // ⭐ 第三十七轮：上一步可能删了文件 ⇒ 先丢掉旧索引，再按**现在**盘上的样子预热。
  // 顺序反了就会把已删的文件交出去（`Image.file` 会走到 errorBuilder，那一格变灰框）。
  await _warmCoverCacheIndex(cache);
}

/// 预热封面缓存的**内存索引**（第三十七轮，尽力而为，绝不抛）。
///
/// 为什么：索引命中 ⇒ `DsCover` 当帧就能画（`cachedNow` 是同步的），
/// 不再"每次进页面/滚动回来都先空一帧灰底"。
Future<void> _warmCoverCacheIndex(HttpCoverCache cache) async {
  cache.invalidate();
  try {
    await cache.warmUp();
    shikiin.diag.info(
      'startup',
      '封面缓存索引预热：${cache.indexedCount} 张'
      '${cache.warmedCount > 0 ? '（本次装进 ${cache.warmedCount} 条）' : ''} —— '
      '命中就第一帧直接画，不再空一帧',
    );
  } catch (_) {
    // 预热失败只是退回异步那条路（功能不变），不打扰用户。
  }
}

/// 启动时的 KV 缓存清扫（尽力而为，绝不抛）。
///
/// 为什么需要：`src_<sha1>` 源缓存与 `dsanima.bangumi.*` 都只在**读的时候**判 TTL，
/// 条目本身从来没有被删过（`SourceCache.clear()` 在生产里零调用）⇒ 键数单调增长。
/// 这里按龄（7 天）+ 条数上限清一次；设置页有「清空缓存」按钮走同一个模块。
Future<void> _sweepHostCachesAtStartup(KeyValueStore store) async {
  try {
    final HostCacheSweep sweep = await sweepHostCache(store);
    if (sweep.changed) {
      shikiin.diag.info('startup',
          '缓存清扫：删 ${sweep.removed} 条 / 留 ${sweep.kept} 条 / 释放约 ${sweep.freedBytes} 字节');
    }
  } catch (_) {
    // 缓存清理不是功能主路径，失败静默（下次启动再试）。
  }
}

/// 启动早期同步读设置（core 的 `KeyValueStore.get` 是同步的）。
AppSettings readSettings(KeyValueStore store) {
  final Object? raw = store.get(SettingsController.storageKey);
  return AppSettings.fromJson(raw is Map ? raw.cast<Object?, Object?>() : null);
}

/// `--skip-first-run` 用的调试 store。
///
/// 为什么需要换 store 而不是只改 `hostData` 的 settings：`SettingsController.build()`
/// 是**自己从 `keyValueStoreProvider` 读**的，所以不换存储的话向导照样会弹。
///
/// 设计要点：
/// * **只读内存、不回写**：调试/截图/CI 冒烟不会污染用户真实设置（`appStore` 原封不动）；
/// * 除设置外仍代理真实 store，保证「追番 / 缓存 / 订阅」等数据在截图时是真的；
/// * 顺手补一个下载目录，好让边车在截图环境里也能起来（否则主页会显示未连接）。
KeyValueStore _debugStore(AppSettings seeded, KeyValueStore fallback) {
  final Map<String, Object?> memory = <String, Object?>{
    SettingsController.storageKey: seeded.toJson(),
  };
  return _OverlayStore(memory, fallback);
}

/// 内存优先、其余透传的 store（`--skip-first-run` 专用）。
class _OverlayStore implements KeyValueStore {
  _OverlayStore(this._memory, this._fallback);

  final Map<String, Object?> _memory;
  final KeyValueStore _fallback;

  @override
  Object? get(String key) => _memory.containsKey(key) ? _memory[key] : _fallback.get(key);

  @override
  Future<void> put(String key, Object? value) async {
    _memory[key] = value; // 只在内存里改，不落盘
  }

  @override
  Future<void> delete(String key) async {
    _memory.remove(key);
  }

  @override
  Iterable<String> get keys => <String>{..._memory.keys, ..._fallback.keys};

  @override
  Future<void> clear() async {
    _memory.clear();
  }
}

/// 播放子窗口的装配（独立引擎/独立 isolate）。
///
/// 只做三件事，**不碰**宿主的数据层/托盘/引擎边车：
/// 1. `bootstrapPlayer` 造本窗口自己的 mpv（探针实测子窗口里硬解渲染正常）；
/// 2. 建一个本次进程专属的 `PlayerRequestNotifier`（主窗口的请求由
///    `PlayerWindowApp` 通过窗口通道转进来）；
/// 3. `runApp(PlayerWindowApp)`。
///
/// 刻意不启动 rqbit 边车、不开托盘、不建引擎端口 —— 那些属于主窗口。
Future<void> _runPlayerWindow(PlayerWindowArgs args, void Function(String) trace) async {
  trace('player window: bootstrapPlayer 前');
  // 数据根目录与主窗口**同一套规则**（便携式：跟着 exe 目录走）；
  // 子窗口只多开一个自己专用的 Hive 目录（排他锁，见下）。
  final DataRoot dataRoot = await resolveDataRoot();
  final Directory playerDataDir = playerStoreDirOf(Directory(dataRoot.path));
  await playerDataDir.create(recursive: true);
  // 落点/尺寸由主窗口算好随启动参数带过来（`domain/window_placement.dart`）：
  // 默认是**工作区正中**（用户 2026-10-12：「播放器应该在中心位置出现」），
  // 用户拖过的位置优先。没有这个参数就退回插件默认（也是居中，1280×720）。
  final Rect? box = _playerBox(args.windowBounds);
  final shikiin.AppRuntime runtime = await shikiin.bootstrapPlayer(
    appId: 'DSAnima',
    // 子窗口自己管窗口尺寸/标题栏：`initWindow: true` 会走 ShikiiN 的无边框设置，
    // 与主窗口的配置一致（播放窗口也要能拖、能全屏、有自绘标题栏）。
    initWindow: true,
    // ⚠️ 子窗口必须用**自己的** Hive 目录：主窗口已经持有 `shikiin.lock`
    // （排他锁），子窗口开同一个 box 会抛 `PathAccessException: lock failed`，
    // 而那个异常发生在 `runApp` **之前** ⇒ 弹出窗口是一片白（实测踩过）。
    dataDir: playerDataDir.path,
    boxName: 'shikiin_player',
    supportDirPath: dataRoot.path,
    windowSize: box?.size ?? const Size(1280, 720),
    // 最小尺寸必须显式给：`setupWindow` 的默认最小尺寸是 640×400，而小屏上居中的落点
    // 可能比它还小（工作区 1024×600 时算出来约 853×480）—— 用默认值会把窗口**顶到
    // 640×400 以上**、把算好的落点撑破。这里给播放窗口自己的最小尺寸。
    windowMinSize: kPlayerWindowMinSize,
    // ⚠️ 这里**故意不传 `windowMaxSize`**（2026-10-11 第五轮）：那个上限走
    // `setMaximumSize` → 原生 `WM_GETMINMAXINFO` 的 `ptMaxTrackSize`，而它会
    // **连 `SetWindowPos` 一起夹** —— 全屏（就是 `SetWindowPos` 到显示器尺寸）
    // 与"拖右边框拉宽"全都被锁在开窗那条 462×260 里。用户报的
    // 「播放器全屏不了 / 右边不能拉大」就是它。详见
    // `domain/window_placement.dart` 里删掉 `playerWindowMaxSize` 的那段注释。
    // "不让播放窗口盖住主窗口"改由下面这条 `windowMaximizable: false` +
    // `player_window_app.dart` 的 `_undoMaximize` 两层兜底（都不碰窗口尺寸）。
    windowMaximizable: false,
    windowPosition: box?.topLeft,
    // 1.1.0 M3/T17：把「扩展」里装好的 GLSL 包变成超分方案（挂进播放器的「超分」菜单）。
    // 子窗口是独立引擎，所以**每次开播放窗口都重新扫一遍** —— 装完扩展重开播放就生效，
    // 不需要重启整个应用。扫不出来（没装/被禁用/文件缺）就只上内置那两张，绝不影响开播。
    extraSchemes: await loadExtensionUpscaleSchemes(Directory(dataRoot.path)),
  );
  trace('player window: bootstrapPlayer ok');
  // 任务栏 / Alt-Tab 的图标与标题（第十七轮），见 [_applyPlayerWindowChrome]。
  await _applyPlayerWindowChrome(args, trace, dataRoot.path);
  // 排障：这一扇窗**自己是谁**（window_manager 认为它在管哪个 HWND）、它以为自己多大。
  // 用户 2026-10-11 反复报「开启播放器后整个程序都不能用了」：先要能回答
  // "子窗口的 window_manager 有没有指错窗口" 与 "它是不是被最大化了" 这两个问题，
  // 所以每次开窗都把这两行写进日志（配套探针 `tool/probe_input.ps1`）。
  await _tracePlayerWindow(trace);

  final WindowController controller = await WindowController.fromCurrentEngine();
  trace('player window: controller ok');

  // 环境：外观 token 与剧集分组**由主窗口推过来**（这里没有主窗口那套 provider）。
  // 用薄 Notifier 桥接：值变了只让读它的 provider 重算，播放面（常驻）不重挂。
  windowTokensNotifier.value = decodeTokens(args.tokens);
  windowEpisodeGroupNotifier.value = decodeEpisodeGroup(args.episodeGroup);
  trace(
    'player window: env ok (tokens=${args.tokens != null}, '
    'group=${args.episodeGroup != null})',
  );

  // 播放请求通道：**本窗口专属**，主窗口的请求由 PlayerWindowApp 通过窗口通道转进来。
  final shikiin.PlayerRequestNotifier requests = shikiin.PlayerRequestNotifier();

  trace('player window: runApp');
  runApp(
    ProviderScope(
      // 不写显式类型：交给 `ProviderScope(overrides: ...)` 的形参上下文推断即可。
      overrides: [
        // ⚠️ 这里**不能**再 override `shikiin.tokensProvider`：`shikiinOverrides`
        // 已经 override 过一次（`runtime.tokens`），同一个容器里 override 两次会撞
        // Riverpod 的断言 —— 实测报的是
        // `Tried to override a provider twice within the same container`，子窗口整屏红。
        // 外观在 `PlayerWindowApp` 里用**内层** `ProviderScope` 接（见那里的说明）。
        ...shikiin.shikiinOverrides(runtime, playerRequests: requests),
        // 上一集/下一集（决策 B31）：主窗口按引擎文件清单归好组推过来。
        shikiin.episodeGroupProvider.overrideWith(
          (Ref ref) => ref.watch(windowEpisodeGroupProvider),
        ),
      ],
      child: PlayerWindowApp(args: args, controller: controller),
    ),
  );
}

/// 启动参数里的窗口几何 → `Rect`（逻辑像素）；缺失/坏了返回 null。
Rect? _playerBox(Map<String, Object?>? raw) {
  if (raw == null) return null;
  double? value(Object? v) => v is num ? v.toDouble() : null;
  final double? left = value(raw['left']);
  final double? top = value(raw['top']);
  final double? width = value(raw['width']);
  final double? height = value(raw['height']);
  if (left == null || top == null || width == null || height == null) return null;
  if (width < 200 || height < 100) return null;
  return Rect.fromLTWH(left, top, width, height);
}

/// ⚠️ 这里原来还有一个 `_playerMaxSize()`（把 `maxWidth/maxHeight` 解析成
/// `setMaximumSize` 的尺寸上限）。2026-10-11 第五轮**删掉了**：那把上限会被
/// 原生 `WM_GETMINMAXINFO` 的 `ptMaxTrackSize` 执行，而 `ptMaxTrackSize` 连
/// `SetWindowPos` 一起夹 —— 于是"真全屏"（`SetWindowPos` 到显示器尺寸）和
/// "拖右边框拉宽"都被锁死在开窗那条 462×260 上（用户报的「播放器全屏不了 /
/// 右边不能拉大」）。别再把它加回来：见 `domain/window_placement.dart` 里
/// 删掉 `playerWindowMaxSize` 的那段长注释。

/// 主窗口的**点击探针**（排障；只在 `--skip-first-run` 档挂上）。
///
/// 为什么需要：用户 2026-10-11 第四次报「打开播放器后，除了播放器，其余全部卡死」，
/// 而真机同时测到：心跳一直在写、消息泵一直在转、播放窗口 0% 覆盖、九点命中全在主窗口。
/// 那"点不动"就只剩两种可能，必须**分开量**：
/// * 输入**到不了** Dart（鼠标被别的窗口捕获 / 焦点不在 / 隔着一层看不见的东西）
///   → 探针（`tool/probe_input.ps1`）数出来的「click-probe」计数不会涨；
/// * 输入到了但界面不响应（重建/重绘卡住）→ 计数照涨。
///
/// 只做一件事：每一次指针按下写一行日志。透明监听，不改变命中测试、不影响任何交互。
class _PointerProbe extends StatelessWidget {
  const _PointerProbe({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (PointerDownEvent e) {
        try {
          shikiin.diag.info(
            'click-probe',
            'pointer down @ ${e.position.dx.round()},${e.position.dy.round()} kind=${e.kind.name}',
          );
        } catch (_) {
          // 探针失败不该影响任何交互。
        }
      },
      child: child,
    );
  }
}

/// 把播放子窗口的"我是谁 / 我以为我多大 / 有没有被最大化"写进日志（排障用）。///
/// 用户 2026-10-11 第四次报「开启播放器后，整个程序都不能用了，什么都点不了整个
/// DSanime」时，真机日志里能拿来定罪的只有两件事：子窗口的 `window_manager` 有没有
/// 指到**别的**窗口，以及它是不是被最大化了（铺满整屏 ⇒ 主窗口 100% 被盖住）。
/// 两步都加超时：这里绝不允许把开窗流程卡住。
Future<void> _tracePlayerWindow(void Function(String) trace) async {
  const Duration limit = Duration(seconds: 2);
  try {
    final int hwnd = await windowManager.getId().timeout(limit);
    final Rect bounds = await windowManager.getBounds().timeout(limit);
    final bool maximized = await windowManager.isMaximized().timeout(limit);
    final bool fullscreen = await windowManager.isFullScreen().timeout(limit);
    trace(
      'player window: hwnd=0x${hwnd.toRadixString(16)} '
      '${bounds.left.toStringAsFixed(0)},${bounds.top.toStringAsFixed(0)} '
      '${bounds.width.toStringAsFixed(0)}x${bounds.height.toStringAsFixed(0)} '
      'maximized=$maximized fullscreen=$fullscreen',
    );
  } catch (e) {
    trace('player window: 取窗口信息失败：$e');
  }
}

/// 给播放窗口**显式**设图标与标题（用户 2026-10-12 第十七轮：「播放器的图标是白纸了」）。
///
/// 真机量到的事实（PowerShell 直接读那颗窗口的类图标 / `WM_GETICON`）：
/// 子窗口是 `desktop_multi_window` 用 `CreateWindowEx` 建的，图标只挂在**窗口类**上
/// （插件注册类时 `ExtractIcon(exe, 0)` 取 exe 里那张），而窗口自己**从来没有
/// `WM_SETICON`** —— `SendMessage(WM_GETICON, ICON_BIG/SMALL)` 两条都是 0。
/// 任务栏 / Alt-Tab 取图标的第一顺位恰恰就是窗口图标，为 0 才回落类图标；而子窗口
/// 建出来时标题是**空串**（插件传的是 `L""`），Alt-Tab 里就是一条没名字的条目。
///
/// ⚠️ 但**只设图标是不够的**（这一点是第十七轮真机 A/B 量出来的）：即使把
/// `WM_GETICON` 与类图标都设成正确那张，任务栏那一格**仍然是系统默认的白纸** ——
/// 真正决定它的是窗口的「应用身份」。修复看
/// `domain/windows_app_identity.dart`（AUMID + 重启命令/图标），这里两件事都做：
/// 应用身份解决**任务栏那一格**，窗口图标/标题解决"属性本身是空的"这件事。
///
/// 三步都**不让失败挡住开窗**：设不上最多还是原来的样子，绝不能因此播不了。
Future<void> _applyPlayerWindowChrome(
  PlayerWindowArgs args,
  void Function(String) trace,
  String supportDir,
) async {
  try {
    final String? ico = await materializeTrayIcon(supportDir);
    if (ico == null || ico.trim().isEmpty) {
      trace('player window: .ico 释放不出来，跳过 setIcon');
    } else {
      await windowManager.setIcon(ico);
      trace('player window: setIcon ok ← $ico');
    }
  } catch (e) {
    trace('player window: setIcon 失败（不影响播放）：$e');
  }
  try {
    final String item = args.title.trim();
    await windowManager.setTitle(item.isEmpty ? 'DSAnima 播放器' : 'DSAnima 播放器 · $item');
  } catch (e) {
    trace('player window: setTitle 失败（不影响播放）：$e');
  }
  // 应用身份：任务栏那一格的图标/名字按它去查（这是"白纸"的真因，见上面的说明）。
  try {
    final int hwnd = await windowManager.getId();
    final String exePath = Platform.resolvedExecutable;
    final bool ok = applyWindowsAppIdentity(
      windowHandle: hwnd,
      relaunchCommand: exePath,
      relaunchIconResource: '$exePath,0',
    );
    trace('player window: 应用身份 hwnd=0x${hwnd.toRadixString(16)} ok=$ok ← $exePath');
  } catch (e) {
    trace('player window: 写应用身份失败（不影响播放）：$e');
  }
}
