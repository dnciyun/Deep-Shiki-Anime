/// 播放器的 provider 契约（契约 §1）。
///
/// 这些 provider 由宿主在 `bootstrapPlayer()` 之后用 `shikiinOverrides(runtime)`
/// 一次性注入真实实例；宿主自己 `runApp`（不再有 `ShikiinApp`/`ShellBuilder`）。
///
/// 只有这 6 个：store / player / anime4k / playerRequest / episodeGroup / tokens。
/// 主题、键位、播放列表、片头片尾、启动文件等 provider 已随功能删除。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'controllers/anime4k_controller.dart';
import 'controllers/player_controller.dart';
import 'controllers/playlist_controller.dart';
import 'infra/persistence.dart';
import 'models/episode_switch_notice.dart';
import 'models/audio_fx.dart';
import 'models/media_item.dart';
import 'models/picture_menu.dart';
import 'models/player_request.dart';
import 'models/subtitle_preset.dart';
import 'models/theme_tokens.dart';

final storeProvider = Provider<KeyValueStore>((_) => throw UnimplementedError());
final playerProvider = Provider<PlayerController>((_) => throw UnimplementedError());
final anime4kProvider = Provider<Anime4kController>((_) => throw UnimplementedError());

/// 宿主注入：画面调节（picture-pack）的菜单/面板接口。默认 null = 没装画面调节包。
///
/// 为什么可空而不是像其它 provider 那样 throw：没装扩展是最常见的情况，
/// 播放器该**安静地不显示**这一项，而不是要求宿主必须装配它。
final pictureMenuProvider = Provider<PictureMenu?>((_) => null);

/// 宿主注入：字幕样式预设（通用扩展包 `preset-pack` / `player.subtitle` 面）。
///
/// 与 [pictureMenuProvider] 同一个理由：没装预设包是最常见的情况，播放器该**安静地
/// 不显示**「样式预设」这一区，而不是要求宿主必须装配。宿主扫完扩展目录后把预设
/// 数组 override 进来；装卸包后重新 override（热刷新由宿主推）。
final subtitlePresetsProvider =
    Provider<List<SubtitlePreset>>((_) => const <SubtitlePreset>[]);

/// 宿主注入：音效档位（通用扩展包 `audio-pack` / `player.audio` 面）。
///
/// 与 [subtitlePresetsProvider] 同一个口径：没装音效包是最常见的情况，播放器该
/// **安静地不显示**「音效」这一项，而不是要求宿主必须装配。
final audioPresetsProvider =
    Provider<List<AudioFxPreset>>((_) => const <AudioFxPreset>[]);

/// 宿主注入：字幕预设的**非致命提示**（目前是「字体没加载上」）。
///
/// 字体资产加载失败不挡预设（回退系统默认字体），但界面必须如实说 —— 否则用户
/// 只会觉得「这个预设没效果」。与 [subtitlePresetsProvider] 同一套注入方式。
final subtitlePresetNotesProvider = Provider<List<String>>((_) => const <String>[]);

/// 宿主投递播放请求的通道。默认 null = 无请求。
///
/// 宿主（DSAnima）override 成 [PlayerRequestNotifier] 后，任何 `request(...)`
/// （含 HTTP 串流 URL）都会被 [PlayerSurface] 消费并立即播放。
final playerRequestProvider = Provider<PlayerRequestNotifier?>((_) => null);

/// 宿主注入：当前剧集所在的那一组（契约 §9）。null = 没有组信息（单集播放），
/// 此时上一集/下一集按钮隐藏。
final episodeGroupProvider = Provider<EpisodeGroup?>((_) => null);

/// 宿主注入：切集失败的原因（第三十八轮，null = 没有失败）。
///
/// 用户原话：「优化反馈，点击下一集或上一集都没实质性反馈」。跨种子切集要等
/// 「补磁力 → 等引擎元数据」，失败原因原本只出现在**主窗口**的横幅里（被播放窗口
/// 盖住 = 等于没有）。宿主把它推过来，播放面顶在画面上 —— 见 [EpisodeSwitchNotice]。
final switchNoticeProvider = Provider<EpisodeSwitchNotice?>((_) => null);

/// 宿主注入：**点某一集**（上一集/下一集、播放列表里的一项）。
///
/// 契约 §9 说「点上一集/下一集时播放器不自己 open，交回宿主」；同一个 torrent 内的
/// 每集都有现成的 `streamUrl`，所以历史上走的是 `playerRequestProvider`。
/// 但**跨种子**的播放列表（用户 2026-10-11：「我要的播放列表为什么没有，按照我播放的
/// 同名同压制组」）里，其它集还是别的种子、还没进引擎 —— 那些条目没有 `streamUrl`，
/// 子窗口自己拿不到地址，只能把「用户点了哪一项」交回宿主去加种/起播。
///
/// 注入这个回调后：**没有 `streamUrl` 的条目**走它（宿主解析并起播），
/// 有 `streamUrl` 的条目照旧走 `playerRequestProvider`（同一 torrent 内秒切，不经宿主）。
final episodeSelectProvider = Provider<void Function(MediaItem item)?>((_) => null);

/// 新拟态 token：播放器风格的唯一入口（契约 §4）。宿主 override 成自己当前的
/// token（浅/深切换时更新它）；不 override 时用兜底深色。
final tokensProvider = Provider<ThemeTokens>((_) => ThemeTokens.fallback);
