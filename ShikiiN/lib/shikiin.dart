/// ShikiiN —— DSAnima 的**内置播放器**（Flutter / Windows 桌面，libmpv）。
///
/// 唯一用法（宿主自己 `runApp`）：
/// ```dart
/// void main() => runGuarded(diag, () async {
///   WidgetsFlutterBinding.ensureInitialized();
///   final rt = await bootstrapPlayer(
///     appId: 'DSAnima',
///     tokens: myDsTokens.toShikiinTokens(),   // 可选：宿主的新拟态 token
///   );
///   final requests = PlayerRequestNotifier();
///   runApp(ProviderScope(
///     overrides: [
///       ...shikiinOverrides(rt, playerRequests: requests),
///       episodeGroupProvider.overrideWith((ref) => myGroup(ref)),  // 可选
///     ],
///     child: const MyApp(),   // 播放页里**常驻**挂 PlayerSurface()
///   ));
/// });
/// ```
///
/// 宿主投递播放请求（HTTP 串流 URL / 本地路径）走 [PlayerRequestNotifier]；
/// 播放器不扫盘、不自己开文件，点上一集/下一集也交回宿主这条链路。
library;

// Riverpod 3.3 起 `Override` 不再由主库导出；宿主构造 overrides 列表需要它。
export 'package:flutter_riverpod/misc.dart' show Override;

// ── 启动与注入 ────────────────────────────────────────────────────────────────
export 'infra/bootstrap.dart' show AppRuntime, bootstrapPlayer, shikiinOverrides;

// 「双击视频 / 二次实例转发」的原生接收端（`bootstrapPlayer` 默认已建；
// 宿主想自己接管时用得到它）。
export 'infra/file_open_channel.dart' show bindFileOpenRequests, kFileOpenChannelName;

// ── provider 契约（契约 §1：只有这几个）──────────────────────────────────────
export 'app.dart'
    show
        anime4kProvider,
        audioPresetsProvider,
        episodeGroupProvider,
        episodeSelectProvider,
        pictureMenuProvider,
        playerProvider,
        playerRequestProvider,
        storeProvider,
        subtitlePresetNotesProvider,
        subtitlePresetsProvider,
        switchNoticeProvider,
        tokensProvider;

// ── 控制器 ───────────────────────────────────────────────────────────────────
export 'controllers/anime4k_controller.dart' show Anime4kController;
export 'controllers/player_controller.dart' show PlayerController;
export 'controllers/playlist_controller.dart' show EpisodeGroup;

// ── 播放面（宿主挂进自己的播放页；**必须常驻挂载**，契约 §5）──────────────────
export 'widgets/player_surface.dart' show PlayerSurface;

// ── 宿主需要构造/消费的模型 ──────────────────────────────────────────────────
export 'models/media_item.dart' show MediaItem;
export 'models/episode_switch_notice.dart' show EpisodeSwitchNotice;
export 'models/player_request.dart' show PlayerRequest, PlayerRequestNotifier;
export 'models/app_settings.dart' show AppSettings;
export 'models/anime4k_preset.dart' show Anime4kPreset, anime4kShaderChain, kAnime4kShaderFiles;
export 'models/upscale_scheme.dart'
    show
        UpscaleScheme,
        UpscaleSchemeKind,
        UpscaleSelection,
        UpscaleTier,
        anime4kScheme,
        builtinUpscaleSchemes,
        mergedUpscaleSchemes,
        kAnime4kSchemeId;
export 'models/theme_tokens.dart' show ThemeTokens;
export 'models/subtitle_preset.dart' show SubtitlePreset;
export 'models/audio_fx.dart'
    show
        AudioFxPreset,
        AudioFxSelection,
        audioFxFilterSpec,
        audioFxFiltersCommand,
        kAudioFxBands,
        kAudioFxBandFrequencies;
export 'models/subtitle_style.dart' show SubtitleStyle;
export 'models/track.dart' show TrackInfo, TrackKind;
export 'models/picture_menu.dart'
    show
        PictureMenu,
        PictureMenuSelection,
        PictureParamInfo,
        PicturePresetInfo;

// ── 基础设施（宿主需要复用键值存储抽象与诊断）────────────────────────────────
export 'infra/persistence.dart' show HiveStore, KeyValueStore;
export 'infra/diagnostics/diag.dart' show Diag, diag;
