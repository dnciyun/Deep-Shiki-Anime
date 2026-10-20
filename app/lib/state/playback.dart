/// 播放编排：点播 → 拿到引擎串流 URL → 交给内嵌播放器；播完自动下一集。
///
/// 设计要点（对应 spec §4.3 点播路径 / §5.2 播放集成）：
/// 1. **边下边播**：`addMagnet` 等元数据就绪就立刻把 `streamUrl` 交给 mpv，
///    **不等下载完**；mpv 用 HTTP Range 读，缺片时边车挂起请求而不是报错。
/// 2. **优先走 core 的 QueueManager**（入队 + 持久化 + 预取 + 省流量策略）；
///    core 的 `subs/` 尚未注入时，退化为「直接 addMagnet → streamUrl」这条
///    同样真实的路径（真起种子、真给 mpv 真 URL），只是不进队列、不做预取。
/// 3. **播完自动下一集**：`autoPlayNext` 开关 + 本次点播的后续集列表。
library;

import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../domain/episode_group.dart';
import '../domain/episodes.dart';
import '../domain/error_text.dart';
import '../domain/format.dart' show formatEpisodeHints;
import '../domain/local_media.dart';
import '../domain/models.dart';
import '../domain/playlist.dart';
import '../domain/ports.dart';
import '../domain/watch_history.dart';
import 'last_playback.dart';
import 'local_library.dart';
import 'providers.dart';
import 'series_loader.dart';

/// 一次点播解析出的可播目标。
@immutable
class PlayTarget {
  final int engineId;
  final int fileIndex;
  final Uri streamUrl;
  final String? subtitlePath;

  /// 命中该文件的 torrent 视图：归组（上一集/下一集）需要它的完整文件清单。
  /// 引擎直连路径（磁力链刚加种）可能还没有清单，所以可为空。
  final EngineTorrentView? torrent;

  const PlayTarget({
    required this.engineId,
    required this.fileIndex,
    required this.streamUrl,
    this.subtitlePath,
    this.torrent,
  });
}

@immutable
class PlaybackUiState {
  final NowPlaying? nowPlaying;

  /// 「上次播放」的落盘快照（进程重启后从 KV 读回来）。
  ///
  /// ⚠️ **不是 `nowPlaying`**：没有有效的 `streamUrl`/`engineId` 时不许假装"正在播"
  /// （侧栏那行据此显示「继续播放」而不是「正在播放」，点它才去引擎里找 torrent）。
  /// 开播成功 / `stop()` 都会把它清掉；恢复失败时**故意保留**（不许无声吞掉，见
  /// `resumeRestored`）。
  final LastPlayback? restored;

  final bool busy;
  final bool playing;
  final DsFailure? failure;

  const PlaybackUiState({
    this.nowPlaying,
    this.restored,
    this.busy = false,
    this.playing = false,
    this.failure,
  });

  PlaybackUiState copyWith({
    NowPlaying? nowPlaying,
    LastPlayback? restored,
    bool? busy,
    bool? playing,
    DsFailure? failure,
    bool clearFailure = false,
    bool clearNowPlaying = false,
    bool clearRestored = false,
  }) =>
      PlaybackUiState(
        nowPlaying: clearNowPlaying ? null : (nowPlaying ?? this.nowPlaying),
        restored: clearRestored ? null : (restored ?? this.restored),
        busy: busy ?? this.busy,
        playing: playing ?? this.playing,
        failure: clearFailure ? null : (failure ?? this.failure),
      );
}

class PlaybackController extends Notifier<PlaybackUiState> {
  StreamSubscription<PlaybackSignal>? _sub;

  /// 当前这一次播放的**播放列表**（同名同压制组，见 `domain/playlist.dart`）。
  ///
  /// 为什么放在这里而不是放在播放窗口服务里：「点了列表里其它一集」= 再次走
  /// [playItem] 那条链路（补磁力 → 加种 → 投递），而这条链路的状态（`nowPlaying`、
  /// 队列、续播）本来就归本控制器管。播放窗口服务只负责把"用户点了哪一条"转过来。
  Playlist? _playlist;

  /// 当前播放列表（UI/诊断只读）。null = 单集播放，没有列表。
  Playlist? get playlist => _playlist;

  /// 当前这一集最近一次进度（毫秒）。快照写盘用它 —— 「收起/关窗」那一刻未必还有
  /// `PlaybackPosition` 信号可等，手里得先有最近的位置。
  int _positionMs = 0;

  /// 上次**成功写盘**的时刻（快照节流用；只看写盘，不看内存里的更新）。
  DateTime? _snapshotSavedAt;

  /// 进度快照的写盘节流：进度 5 秒一条，每一条都落盘没必要（Hive 写是同步落盘）。
  ///
  /// 15 秒的取舍：最坏情况丢 15 秒进度（重启后从 15 秒前接着播，比"从头"好得多），
  /// 写盘频率从 0.2 次/秒降到约 0.07 次/秒。**用户明确动作**（开播/收起窗口/停止）
  /// 不受节流影响：开播、收起窗口强制写，停止则**清空**。
  static const Duration kSnapshotWriteInterval = Duration(seconds: 15);

  @override
  PlaybackUiState build() {
    ref.onDispose(() {
      unawaited(_sub?.cancel());
      _sub = null;
    });
    // 「上次播放」快照是**同步**读的（`KeyValueStore.get` 同步，Hive 也是），所以
    // 启动第一帧侧栏就能拿到 `restored`，不需要等任何异步加载。
    //
    // ⚠️ 刻意用 `read` 而不是 `watch`：写快照会更新 `lastPlaybackProvider` 的状态，
    // 若 watch 它，本控制器会整体重建、把 `nowPlaying/playing` 一起冲掉（正在播的
    // 东西突然消失）—— 那是比"重启后没有继续播放"严重得多的回归。
    final LastPlayback? restored = ref.read(lastPlaybackProvider);
    return PlaybackUiState(restored: restored);
  }

  void _ensureSubscribed() {
    _sub ??= ref.read(playerPortProvider).signals.listen(_onSignal);
  }

  /// 点播一集：入队/加种 → 立刻起播。
  ///
  /// [playlist] 是**这一批结果**（搜索结果 / 番剧页剧集列表 / 订阅命中的条目）。
  /// 给了它就会按「同名同压制组」算出播放列表推给播放窗口（用户 2026-10-11：
  /// 「我要的播放列表为什么没有，按照我播放的同名同压制组」）。
  ///
  /// [showTitle] / [coverUrl] / [mikanBangumiId] 这一组是**观看记录**要的"这一部番是谁"
  /// （第二十七轮）：条目本身只有"第 03 集"这种标题，封面与番剧 id 只有调用页面知道
  /// （番剧详情页/正在追卡片有）。不传就退回条目标题，仍然会记一条 —— 只是没有封面。
  Future<void> playItem(
    SourceItemView item, {
    List<SourceItemView> upNext = const <SourceItemView>[],
    List<SourceItemView> playlist = const <SourceItemView>[],
    String? showTitle,
    String? showTitleEn,
    String? coverUrl,
    String? coverReferer,
    String? mikanBangumiId,
  }) async {
    state = state.copyWith(busy: true, clearFailure: true);
    try {
      // 换集时按省流量策略处理上一集（不再做种）。
      await _stopSeedingOnSwitch();
      // mikan 的**搜索结果**里没有磁力（RSS 不带 magnet，磁力只在单集详情页）：
      // 不补这一步，点「播放」必定失败（用户 2026-10-11：「搜索内的全部无法播放
      // mikan 的」）。补全失败就原样继续，交给下面的错误路径说清楚原因。
      final SourceItemView playable = await _ensurePlayable(item);
      // 观看记录的键在这里算好（进度是子窗口之后才报上来的，见 `WatchMeta`）。
      final WatchMeta watch = buildWatchMeta(
        title: (showTitle ?? '').trim().isEmpty ? playable.displayTitle : showTitle!.trim(),
        titleEn: showTitleEn,
        coverUrl: coverUrl,
        coverReferer: coverReferer,
        mikanBangumiId: (mikanBangumiId ?? '').trim().isEmpty
            ? _bangumiIdOf(playable)
            : mikanBangumiId!.trim(),
        group: playable.group,
        episode: episodeNumber(playable),
        episodeLabel: playable.episodeHints.isEmpty
            ? null
            : formatEpisodeHints(playable.episodeHints),
        infoHash: playable.infoHash,
        sourceItemId: playable.id,
      );
      // 播放列表：**这一批结果的原始条目 + 整部番的剧集清单**。
      //
      // 基准必须是原始条目（补详情的副本标题可能和同批其它条目不完全一样，
      // 拿它当基准会把自己的集数算丢）；而整部番那一份要等详情页带回 bangumiId 才能取
      // （用户 2026-10-11 第五次：「不会有前几集，我点第8集就没有765等」）。
      final Playlist? list = await _playlistFor(item, playable, playlist);
      _playlist = list;
      // 预热素材（第三十八轮）：有整部番的剧集清单就用它，没有就退回这一批的后续集。
      // 传**整批**而不是只传下一条：挑哪几条交给 core 的档位（默认 0 = 关）去定，
      // 换档位不用动这里。
      final PlayTarget target = await _prepare(
        playable,
        upNext,
        preheatBatch: list?.items ?? playlist,
      );
      // 同一个 torrent 里的剧集归组（「上一集/下一集」+ 观看记录的归位表共用这一份）。
      final EpisodeGrouping? torrentGroup = (list != null || target.torrent == null)
          ? null
          : episodeGroupingFor(
              torrent: target.torrent!,
              fileIndex: target.fileIndex,
              engine: ref.read(enginePortProvider),
            );
      final Map<String, ({WatchMeta watch, int? fileIndex})> watchByUrl = _watchByUrlForGroup(
        show: watch,
        torrent: target.torrent,
        group: torrentGroup,
        currentUrl: target.streamUrl,
        currentFileIndex: target.fileIndex,
      );
      // 续播（用户 2026-10-18：「发现bug继续观看回不到上一次的观看位置」）：
      // 任何入口点开一集，只要观看记录里有"上次看到哪儿"就把起点交给播放器。
      // 之前**只有**「观看记录」页的「继续播放」和重启后侧栏那行传了起点，
      // 正在追 / 今日更新 / 搜索结果 / 播放列表切集一律从 0 开始；而子窗口自己那份
      // 续播记忆是按**串流 URL** 记的（带边车 token，重启即换）⇒ 必然 miss。
      // 看完的集 `resumePositionMs` 是 null（看完了就该从头），这里不另设阈值。
      final int? resumeMs =
          resumePositionForRecord(ref.read(watchHistoryProvider), watch.recordId);
      await ref.read(playerPortProvider).open(
            PlayerRequest(
              streamUrl: target.streamUrl,
              title: playable.displayTitle,
              engineId: target.engineId,
              fileIndex: target.fileIndex,
              subtitlePath: target.subtitlePath,
              startAt: resumeMs == null ? null : Duration(milliseconds: resumeMs),
            ),
            // 上一集/下一集（决策 B31）：**这一刻**按刚解析出来的文件序号归组，
            // 不能读 currentEpisodeGroupProvider（它看的是还没更新的 nowPlaying）。
            //
            // 「同名同压制组」的播放列表优先于「同一个种子里的文件清单」：
            // mikan 上一集一个种子，后者永远只有一项（这正是用户报的"没有列表"）。
            // 列表里每项的 `path` 是**条目 id**（不是流地址）—— 其它集还没进引擎，
            // 播放器点它时会把 id 交回宿主（见 `episodeSelectProvider`）。
            episodeGroup: list != null ? _groupingOf(list) : torrentGroup,
          );
      _ensureSubscribed();
      state = PlaybackUiState(
        nowPlaying: NowPlaying(
          title: playable.displayTitle,
          engineId: target.engineId,
          fileIndex: target.fileIndex,
          upNext: upNext,
          watch: watch,
          watchByUrl: watchByUrl,
        ),
      );
      // 「上次播放」快照：开播成功就落一次（位置 = 这次起播的起点；之后进度节流更新）。
      // 放在这里而不是等第一次进度：用户可能刚点开就关掉程序 —— 那时也得记得"在看哪一集"。
      _positionMs = resumeMs ?? 0;
      await _saveSnapshotNow();
      // 观看记录：开播就写一条（**不等它** —— 记不上账也不该挡着出画面）。
      unawaited(_recordWatchStart(
        watch,
        engineId: target.engineId,
        fileIndex: target.fileIndex,
      ));
      // 起播成功之后（`open` 已返回、`nowPlaying` 已写）才去补全集，而且**不等它**：
      // 补全集要联网翻页搜索，绝不能挡在出画面之前。判据与做法见 _backfillSeries。
      unawaited(_backfillSeries(
        original: item,
        batch: playlist,
        current: list,
        engineId: target.engineId,
        fileIndex: target.fileIndex,
      ));
      await _recordRecent(
        title: playable.displayTitle,
        engineId: target.engineId,
        fileIndex: target.fileIndex,
        sourceItemId: playable.id,
      );
    } catch (error, stackTrace) {
      state = state.copyWith(
        busy: false,
        failure: describeFailure(error, stackTrace: stackTrace),
      );
    }
  }

  /// 播一条**本地文件**（「本地」页里点的）。
  ///
  /// 与 [playItem] 的区别：不碰引擎（没有入队/磁力/串流 URL），地址就是磁盘上的
  /// 路径 —— 交给播放窗口时转成 `file:` URI（见 `domain/local_media.dart` 里
  /// [localFileUriText] 的说明：`Uri.parse(r'F:\a.mkv')` 会得到垃圾 URI）。
  ///
  /// 三件"跟在线对齐"的事：
  /// * **续播**：[startPositionMs] 由调用方（本地页，读 `local.progress`）给；
  /// * **上一集/下一集**：同目录的视频按 `episode_group.dart` 的规则归组，每项都带上
  ///   `streamUri`（= 自己的 `file:` URI）⇒ 子窗口能自己换集，不用回来找宿主；
  /// * **同名字幕**：归组里每一项都带自己的字幕路径，换集之后字幕不会丢。
  ///
  /// `engineId = -1`：本地文件在引擎里没有对应条目，`nowPlayingProgressProvider`
  /// 查不到就自然不显示引擎进度浮层（不是假装在下载）。
  Future<void> playLocal({
    required String showTitle,
    required List<LocalVideo> videos,
    required LocalVideo current,
    int? startPositionMs,
  }) async {
    state = state.copyWith(busy: true, clearFailure: true);
    try {
      // 换集时按省流量策略处理上一集（本地播不涉及引擎，但上一次可能是在线播的）。
      await _stopSeedingOnSwitch();
      // 本地播放没有"播放列表"（那份是 mikan 条目 id 的列表），先清掉，
      // 免得侧栏/播放列表 UI 拿上一次在线的列表去点（点了必然失败）。
      _playlist = null;

      final List<LocalVideo> ordered = List<LocalVideo>.of(videos)..sort(compareLocalVideos);
      final Map<String, LocalVideo> byPath = <String, LocalVideo>{
        for (final LocalVideo video in ordered) video.path: video,
      };
      final EpisodeGrouping? grouped = groupEpisodes(
        localEpisodeEntries(ordered),
        current.path,
      );
      final EpisodeGrouping? group = _localGrouping(grouped, byPath);
      final int index = group?.currentIndex ?? 0;
      final Uri uri = Uri.parse(localFileUriText(current.path));
      final int? resumeMs = (startPositionMs != null && startPositionMs > 0) ? startPositionMs : null;

      await ref.read(playerPortProvider).open(
        PlayerRequest(
          streamUrl: uri,
          title: current.title,
          engineId: -1,
          fileIndex: index,
          subtitlePath: current.subtitlePath,
          startAt: resumeMs == null ? null : Duration(milliseconds: resumeMs),
        ),
        episodeGroup: group,
      );
      state = PlaybackUiState(
        nowPlaying: NowPlaying(
          title: (showTitle.trim().isEmpty ? current.title : showTitle.trim()),
          engineId: -1,
          fileIndex: index,
          isLocal: true,
        ),
      );
    } catch (error, stackTrace) {
      state = state.copyWith(
        busy: false,
        failure: describeFailure(error, stackTrace: stackTrace),
      );
    }
  }

  /// 本地归组 → 播放器那份（**path 与 streamUri 都换成 `file:` URI**）。
  ///
  /// 为什么两者都要换：子窗口换集时它自己按 `streamUri` 开盘，而之后由 `_currentPath`
  /// 反查"现在放的是分组里的第几项"（自动下一集就这么找）。`_currentPath` 是它开盘用的
  /// 那个字符串 —— 只换 `streamUri` 不换 `path`，两边就永远对不上，自动下一集会一直
  /// 停在同一集。归组本身仍旧按**真实路径**算（目录/指纹规则是按真实路径写的）。
  EpisodeGrouping? _localGrouping(EpisodeGrouping? raw, Map<String, LocalVideo> byPath) {
    if (raw == null) return null;
    final List<EpisodeEntry> entries = <EpisodeEntry>[];
    for (final EpisodeEntry entry in raw.entries) {
      final Uri uri = Uri.parse(localFileUriText(entry.path));
      entries.add(
        EpisodeEntry(
          title: entry.title,
          path: uri.toString(),
          streamUri: uri,
          episode: entry.episode,
          subtitlePath: byPath[entry.path]?.subtitlePath ?? entry.subtitlePath,
        ),
      );
    }
    return EpisodeGrouping(entries, raw.currentIndex);
  }

  /// 排障 / 截图专用（`--play=<url>`）：把一条**不经过引擎**的 URL 当成本次点播投出去。
  ///
  /// 为什么要有这条：`main.dart` 的 `--play` 原来只调 `playerWindow.open()`，
  /// **不写 `nowPlaying`** —— 于是主窗口那些「正在播放」的 UI（状态条那颗按钮 /
  /// 2026-10-12 第十七轮搬到侧栏左下角的那一行）在探针里永远不出现，真机截图拍不到。
  /// 这里照 [playItem] 的写法补上 `nowPlaying`。
  ///
  /// `engineId = -1` 是**故意的**：它只被 `nowPlayingProgressProvider` 用来去引擎里
  /// 找进度，引擎里必然没有 -1 这条 ⇒ 没有进度浮层，正是探针要的（不是真实点播）。
  Future<void> debugPlayUrl(String url, {String? title}) async {
    final String label = (title ?? '').trim().isEmpty ? url : title!.trim();
    // 本地路径（`--play=F:\a.mkv` 这种排障用法）同样要转 `file:` URI：
    // `Uri.parse` 会把它当成 scheme=`f` 的 URI，播放器那边就变成"打不开"。
    final Uri uri = File(url).existsSync() ? Uri.parse(localFileUriText(url)) : Uri.parse(url);
    await ref.read(playerPortProvider).open(
          PlayerRequest(streamUrl: uri, title: label, engineId: -1, fileIndex: 0),
        );
    state = PlaybackUiState(nowPlaying: NowPlaying(title: label, engineId: -1, fileIndex: 0));
  }

  /// 宿主播放列表 → 播放器那份 `EpisodeGrouping`（`path` = 条目 id）。
  ///
  /// [episode] 一起带过去：播放器的列表要显示**真实集号**（用户 2026-10-11：
  /// 「播放列表太小了看不到集数了」）。用下标当集号会在缺集时撒谎。
  EpisodeGrouping _groupingOf(Playlist list) => EpisodeGrouping(
    <EpisodeEntry>[
      for (final SourceItemView item in list.items)
        EpisodeEntry(title: item.displayTitle, path: item.id, episode: episodeOf(item)),
    ],
    list.currentIndex,
  );

  /// 「同名同压制组」的播放列表：[batch]（这一批结果）+ **整部番的剧集清单**。
  ///
  /// 为什么要多这一步（用户 2026-10-11 第五次报障，原话）：
  /// > 而且不会有前几集，我点第8集就没有765等。
  /// 只按这一批搜索结果归组时，列表里只有**这一批里出现过**的集号 —— 从「今日更新」
  /// 点第 8 集就只有 8/9/10。整部番那一份来自 mikan 的番剧页
  /// （`/Home/Bangumi/<id>`，见 `HostDataPort.seriesEpisodes`），拿不到就退回旧行为。
  ///
  /// [original] 是**原始条目**（基准，不能拿补过详情的副本当基准）；
  /// [playable] 是补过磁力/详情的副本（bangumiId 在它身上）。
  Future<Playlist?> _playlistFor(
    SourceItemView original,
    SourceItemView playable,
    List<SourceItemView> batch,
  ) async {
    final List<SourceItemView> candidates = mergeCandidates(<Iterable<SourceItemView>>[
      batch,
      await _seriesEpisodes(playable, original),
    ]);
    if (candidates.isEmpty) return null;
    return playlistFor(candidates, original);
  }

  /// 取整部番的剧集清单；任何失败都当"没有"（列表少几集不该让播放失败）。
  Future<List<SourceItemView>> _seriesEpisodes(
    SourceItemView playable,
    SourceItemView original,
  ) async {
    final HostDataPort port = ref.read(hostDataPortProvider);
    // 补过详情的那份通常带 bangumiId；原始条目兜底（番剧页直接点进来的情况）。
    for (final SourceItemView candidate in <SourceItemView>[playable, original]) {
      try {
        final List<SourceItemView> all = await port.seriesEpisodes(candidate);
        if (all.isNotEmpty) return all;
      } catch (_) {
        // 端口契约说不抛；装配没接上（组件测试）时会抛，这里静默降级。
      }
    }
    return const <SourceItemView>[];
  }

  /// 播放窗口里点了播放列表的某一项（子窗口只能报 id，见 `kMethodEpisodeSelect`）。
  ///
  /// 命中当前列表 → 走与点播**完全同一条**链路（补磁力 → 加种 → 起播）；
  /// 没命中（列表已被换掉/条目没了）返回 false，调用方据此提示"重新找源"。
  ///
  /// ⚠️ 第三十八轮：这条链路上**每一步都可能要等**（补磁力最多几秒、`addMagnet` 等元数据
  /// 最长两分钟），而用户是在**播放窗口**里点的 —— 所以除返回值之外，还要把"没切成"
  /// 的原因推回那扇窗（`kMethodSwitchFailed`），否则他看到的是一颗毫无反应的按钮。
  /// "正在切"那一半在子窗口本地做（`PlayerSurface._beginEpisodeSwitch`）。
  Future<bool> playPlaylistEntry(String itemId) async {
    final Playlist? list = _playlist;
    if (list == null) {
      _notifySwitchFailed(
        title: '',
        failure: const DsFailure(
          '这次的播放列表已经失效（可能刚换了番）',
          hint: '回主窗口重新找一集播放；这条列表是上一次点播算的',
        ),
      );
      return false;
    }
    SourceItemView? picked;
    int index = -1;
    for (int i = 0; i < list.items.length; i++) {
      if (list.items[i].id == itemId) {
        picked = list.items[i];
        index = i;
      }
    }
    final SourceItemView? target = picked;
    if (target == null) {
      _notifySwitchFailed(
        title: '',
        failure: const DsFailure(
          '这一条已经不在这次的播放列表里了',
          hint: '可能刚换了一批结果；回主窗口重新找一集，或点列表里别的一条',
        ),
      );
      return false;
    }
    final List<SourceItemView> rest = index + 1 < list.items.length
        ? list.items.sublist(index + 1)
        : const <SourceItemView>[];
    await playItem(target, upNext: rest, playlist: list.items);
    // `playItem` 把失败吞进了状态里（同一份失败主窗口的横幅也在显示）——
    // 这里再往播放窗口推一份，因为用户人还在那扇窗里。
    if (state.failure case final DsFailure failure) {
      _notifySwitchFailed(title: target.displayTitle, failure: failure);
    }
    return true;
  }

  /// 把「这一集没切过去」的原因推给播放窗口（第三十八轮，尽力而为、绝不抛）。
  ///
  /// 服务没接通（内嵌播放 / 组件测试）时静默降级：那时主窗口的失败横幅就是唯一提示。
  void _notifySwitchFailed({required String title, required DsFailure failure}) {
    try {
      unawaited(
        ref.read(playerWindowServiceProvider).notifyEpisodeSwitchFailed(
              title: title,
              message: failure.message,
              hint: failure.hint,
            ),
      );
    } catch (_) {
      // 推不动不影响任何播放逻辑（用户还看得到主窗口的横幅）。
    }
  }

  /// 补全磁力（宿主数据层接通时才有意义）。
  ///
  /// 宿主数据层没接通（组件测试）时 `ensurePlayable` 抛错：那条线上本来也不可能
  /// 真的起播，这里静默退回原条目，让后面的错误信息保持具体。
  Future<SourceItemView> _ensurePlayable(SourceItemView item) async {
    try {
      return await ref.read(hostDataPortProvider).ensurePlayable(item);
    } catch (_) {
      return item;
    }
  }

  /// 播放**已经下好**的 torrent 文件（「已完成」页的播放按钮）。
  ///
  /// 不由队列解析：torrent 已在引擎里，直接拿 `streamUrl` 交给播放器。
  ///
  /// [startPositionMs] = 「观看记录」页点「继续播放」时带上一次看到哪儿（第四十二轮
  /// UX #2）。**必须由宿主显式给**，不能指望播放器自己记：子窗口那份续播记忆按
  /// **串流 URL** 存（`ShikiiN` 的 `settings.loadResume(item.path)`），而引擎给的 URL
  /// 每次带**新 token** —— 同一个文件两次点播的 URL 不同，那份记忆必然 miss。
  /// 宿主这份记录是按"哪一集"记的，这才是可靠的那一份。
  Future<void> playTorrentFile({
    required EngineTorrentView torrent,
    required EngineFileView file,
    String? showTitle,
    String? showTitleEn,
    String? coverUrl,
    String? coverReferer,
    String? mikanBangumiId,
    int? startPositionMs,
  }) async {
    state = state.copyWith(busy: true, clearFailure: true);
    // 已完成页点播不属于任何搜索批次：旧的播放列表跟着失效（否则点了别的番还会
    // 显示上一部番的集数）。
    _playlist = null;
    try {
      await _stopSeedingOnSwitch();
      // 已完成页点播：这一份可能被"播放结束停做种"或重启收尾暂停过，先让它跑起来。
      await _ensureEngineRunning(torrent.id);
      final Uri? url =
          ref.read(enginePortProvider).streamUrl(torrent.id, file.index);
      if (url == null) throw _engineNotConnected;
      final EpisodeGrouping? torrentGroup = episodeGroupingFor(
        torrent: torrent,
        fileIndex: file.index,
        engine: ref.read(enginePortProvider),
      );
      // 起点：调用方显式给的优先（「观看记录」页的「继续播放」/ 重启恢复行）；
      // 没给就按**引擎坐标**（infoHash + 文件序号）从观看记录里查 —— 「已完成」页的
      // 播放按钮走的正是"没给"这条路，它以前永远从 0 开始（用户 2026-10-18：
      // 「继续观看回不到上一次的观看位置」）。
      final int? startMs = (startPositionMs != null && startPositionMs > 0)
          ? startPositionMs
          : resumePositionForFile(
              ref.read(watchHistoryProvider),
              infoHash: torrent.infoHash,
              fileIndex: file.index,
            );
      await ref.read(playerPortProvider).open(
            PlayerRequest(
              streamUrl: url,
              title: torrent.name,
              engineId: torrent.id,
              fileIndex: file.index,
              // 续播：起点交给播放器（`startAt` 一路到 shikiin 的 `player.open`，
              // 它 open 完会 seek 过去）。null = 从头。
              startAt: startMs == null ? null : Duration(milliseconds: startMs),
            ),
            episodeGroup: torrentGroup,
          );
      _ensureSubscribed();
      // 观看记录（第二十七轮）：已完成页点播没有 mikan 条目，键就落在番名/种子名上。
      final WatchMeta watch = buildWatchMeta(
        title: (showTitle ?? '').trim().isEmpty ? torrent.name : showTitle!.trim(),
        titleEn: showTitleEn,
        coverUrl: coverUrl,
        coverReferer: coverReferer,
        mikanBangumiId: mikanBangumiId,
        episode: _episodeOfFile(torrent, file),
        infoHash: torrent.infoHash,
      );
      state = PlaybackUiState(
        nowPlaying: NowPlaying(
          title: torrent.name,
          engineId: torrent.id,
          fileIndex: file.index,
          watch: watch,
          watchByUrl: _watchByUrlForGroup(
            show: watch,
            torrent: torrent,
            group: torrentGroup,
            currentUrl: url,
            currentFileIndex: file.index,
          ),
        ),
      );
      // 快照位置 = 这次起播用的起点（从观看记录续播时就是上次看到的位置）。
      _positionMs = startMs ?? 0;
      await _saveSnapshotNow();
      unawaited(_recordWatchStart(watch, engineId: torrent.id, fileIndex: file.index));
      await _recordRecent(
        title: torrent.name,
        engineId: torrent.id,
        fileIndex: file.index,
      );
    } catch (error, stackTrace) {
      state = state.copyWith(
        busy: false,
        failure: describeFailure(error, stackTrace: stackTrace),
      );
    }
  }

  /// 记一笔「继续观看」（spec §7.4 渲染图的横排数据源）。
  Future<void> _recordRecent({
    required String title,
    required int engineId,
    required int fileIndex,
    String? sourceItemId,
  }) async {
    try {
      await ref.read(recentPlayedProvider.notifier).record(
            title: title,
            engineId: engineId,
            fileIndex: fileIndex,
            sourceItemId: sourceItemId,
          );
    } catch (_) {
      // 记录失败不影响播放。
    }
  }

  /// 条目里带的 mikan 番剧 id（详情页补全时 core 写在 `extra['bangumiId']`）。
  String? _bangumiIdOf(SourceItemView item) {
    final Object? raw = item.extra['bangumiId'];
    final String value = (raw ?? '').toString().trim();
    return value.isEmpty ? null : value;
  }

  /// 已完成页点播：用文件名推集数（推不出就 null —— 不编）。
  ///
  /// 为什么用文件名而不是 `file.index`：同一个 torrent 里可能有多个视频，
  /// index 是引擎给的序号、不是集号；文件名里的 `- 03` / `[03]` 才是。
  int? _episodeOfFile(EngineTorrentView torrent, EngineFileView file) {
    final String stem = p.basenameWithoutExtension(file.path);
    return episodeNumberFromTitle(stem.isEmpty ? torrent.name : stem);
  }

  /// 一组剧集（同一个 torrent 的各文件）→ `串流 URL → (观看记录元数据, 文件序号)`。
  ///
  /// 只给**带 `streamUri` 的条目**建映射：那正是子窗口能自己开盘、因而宿主不知情的那些
  /// （见 `NowPlaying.watchByUrl` 的说明）。[currentUrl] 那一项**强制用开播时算好的
  /// [show]**：同一条记录从写入到进度更新必须是同一个键 —— 分组的集号来自文件名解析，
  /// 与开播时的 `episodeNumber(条目)` 可能差一档，混用就会多出一条记录。
  Map<String, ({WatchMeta watch, int? fileIndex})> _watchByUrlForGroup({
    required WatchMeta show,
    required EngineTorrentView? torrent,
    required EpisodeGrouping? group,
    required Uri? currentUrl,
    int? currentFileIndex,
  }) {
    final Map<String, ({WatchMeta watch, int? fileIndex})> out =
        <String, ({WatchMeta watch, int? fileIndex})>{};
    for (final EpisodeEntry entry in group?.entries ?? const <EpisodeEntry>[]) {
      final Uri? uri = entry.streamUri;
      if (uri == null) continue;
      out[uri.toString()] = (
        watch: buildWatchMeta(
          title: show.title,
          titleEn: show.titleEn,
          coverUrl: show.coverUrl,
          coverReferer: show.coverReferer,
          mikanBangumiId: show.mikanBangumiId,
          // 字幕组沿用开播那一条（同一个 torrent 里各集同组）。
          group: show.group,
          episode: entry.episode,
          episodeLabel: entry.title.trim().isEmpty ? null : entry.title.trim(),
          infoHash: torrent?.infoHash ?? show.infoHash,
        ),
        fileIndex: _fileIndexOfUrl(torrent, uri),
      );
    }
    if (currentUrl != null) {
      out[currentUrl.toString()] = (watch: show, fileIndex: currentFileIndex);
    }
    return out;
  }

  /// 这个串流地址是 torrent 里的第几个文件（找不到就 null，不猜）。
  int? _fileIndexOfUrl(EngineTorrentView? torrent, Uri url) {
    if (torrent == null) return null;
    final EnginePort engine = ref.read(enginePortProvider);
    for (final EngineFileView f in torrent.files) {
      if (engine.streamUrl(torrent.id, f.index)?.toString() == url.toString()) return f.index;
    }
    return null;
  }

  /// 开播就写一条观看记录（第二十七轮；同集覆盖，时间刷新）。
  Future<void> _recordWatchStart(
    WatchMeta watch, {
    required int engineId,
    required int fileIndex,
  }) async {
    try {
      await ref.read(watchHistoryProvider.notifier).recordStart(
            title: watch.title,
            titleEn: watch.titleEn,
            coverUrl: watch.coverUrl,
            coverReferer: watch.coverReferer,
            mikanBangumiId: watch.mikanBangumiId,
            group: watch.group,
            episode: watch.episode,
            episodeLabel: watch.episodeLabel,
            engineId: engineId,
            fileIndex: fileIndex,
            infoHash: watch.infoHash,
            sourceItemId: watch.sourceItemId,
          );
    } catch (_) {
      // 记不上账不该影响播放。
    }
  }

  /// 子窗口报上来的播放进度（`kMethodWatchProgress`，第二十七轮）。
  ///
  /// 做两件事：把进度写进那条观看记录；进度到 [kWatchFinishedRatio] 以上时**自动打勾**
  /// 「已看过」（下载全部会跳过它）。`recordWatchProgress` 关掉时两件都不做 ——
  /// 用户要的是"只记时间不记进度"。
  ///
  /// ⚠️ **进度归到哪一集**要看子窗口报的 `path`：同一个 torrent 里的其它集是子窗口
  /// **自己**开盘的（`episodeGroupingFor` 给每项都填了 `streamUri`），宿主并不知道换了集
  /// —— 不按 `path` 归位的话，第 2 集的进度会写进第 1 集的记录、还会在第 1 集上打勾。
  /// 找不到映射（老版本子窗口 / 本地文件）就退回"当前这一条"，与旧行为一致。
  Future<void> onWatchProgress(Object? raw) async {
    final ({int positionMs, int durationMs, String? path})? progress =
        decodeWatchProgress(raw);
    if (progress == null) return;
    final NowPlaying? current = state.nowPlaying;
    // 本地文件：进度记到 `local.progress`（键 = 真实路径），**不写观看记录**
    // —— 观看记录那条链要番剧 id / infoHash，本地文件两样都没有（见 spec §4）。
    if (current != null && current.isLocal) {
      try {
        await ref.read(localLibraryProvider.notifier).recordProgress(
              progress.path ?? '',
              positionMs: progress.positionMs,
              durationMs: progress.durationMs,
            );
      } catch (_) {
        // 记不上进度不该影响播放（与观看记录同一口径）。
      }
      return;
    }
    WatchMeta? watch = current?.watch;
    // 子窗口自己换集时（同一个 torrent 里的其它文件），进度要归到**它真正在放的那一集**；
    // 顺便把那一集的记录补上（开播时宿主并不知道它会换集）。
    int? fileIndex = current?.fileIndex;
    final String? path = progress.path;
    if (path != null && current != null) {
      final ({WatchMeta watch, int? fileIndex})? mapped = current.watchByUrl[path];
      if (mapped != null) {
        watch = mapped.watch;
        fileIndex = mapped.fileIndex ?? fileIndex;
      }
    }
    if (watch == null) return;
    final AppSettings settings = ref.read(settingsProvider);
    if (!settings.recordWatchProgress) return;
    try {
      final WatchHistoryController history = ref.read(watchHistoryProvider.notifier);
      if (!ref.read(watchHistoryProvider).any((WatchRecord r) => r.id == watch!.recordId)) {
        // 这一集还没有记录（子窗口自己换过来的）：先补一条，否则观看记录里永远只有第 1 集。
        await history.recordStart(
          title: watch.title,
          titleEn: watch.titleEn,
          coverUrl: watch.coverUrl,
          coverReferer: watch.coverReferer,
          mikanBangumiId: watch.mikanBangumiId,
          group: watch.group,
          episode: watch.episode,
          episodeLabel: watch.episodeLabel,
          engineId: current?.engineId,
          fileIndex: fileIndex,
          infoHash: watch.infoHash,
          sourceItemId: watch.sourceItemId,
        );
      }
      await history.recordProgress(
        id: watch.recordId,
        positionMs: progress.positionMs,
        durationMs: progress.durationMs,
      );
      if (progress.durationMs > 0 &&
          progress.positionMs >= progress.durationMs * kWatchFinishedRatio) {
        await ref.read(watchedMarksProvider.notifier).mark(<String>[watch.watchedKey]);
      }
    } catch (_) {
      // 子窗口每 5 秒报一条，一条失败不该往上抛（下一跳会补上）。
    }
    // 「上次播放」快照：位置跟着进度走，但**节流写盘**（见 [kSnapshotWriteInterval]）。
    // 放在 `recordWatchProgress` 开关之后：用户关掉"记录播放进度"就是不记，别绕过去。
    _positionMs = progress.positionMs;
    await _maybeSaveSnapshot(watch: watch, fileIndex: fileIndex);
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 「上次播放」快照：关掉程序之后，侧栏那行「继续播放」还能回来
  //
  // 用户 2026-10-17：「关闭程序后继续观看就没了，会影响有时候的体验」。
  // 旧实现 `nowPlaying` 只在内存 → 重启后那行整行不渲染。现在：
  // 开播 / 进度（节流）/ 收起窗口时写快照，`stop()` 清空；重启时 `build()` 读回
  // `state.restored`，点那一行走 [resumeRestored]（按 infoHash 回引擎找 torrent）。
  // ───────────────────────────────────────────────────────────────────────────

  /// 从当前 `nowPlaying` 造一条快照。
  ///
  /// [watch] / [fileIndex] 给"子窗口自己换集"的情况（进度里带着真正在放的那一集）；
  /// 不传就用 `nowPlaying` 自己的。**没有 infoHash 就不落盘**：重启后找不到 torrent 的
  /// 快照只会让侧栏出现一条"点了必失败"的行 —— 宁可没有（那行保持现状不显示）。
  LastPlayback? _snapshotOfCurrent({
    WatchMeta? watch,
    int? fileIndex,
    int positionMs = 0,
  }) {
    final NowPlaying? current = state.nowPlaying;
    if (current == null) return null;
    final WatchMeta? meta = watch ?? current.watch;
    final String hash = (meta?.infoHash ?? '').trim();
    if (hash.isEmpty) return null;
    // 子窗口自己换到同一 torrent 的其它文件时，mapped watch 与 `nowPlaying.watch`
    // **不是同一个实例**，那一集的标题只存在于 `episodeLabel` 里；`nowPlaying.title`
    // 还是最开始那一集 —— 拿它显示会让"继续播放"写着第 1 集、实际续的是第 2 集。
    final bool switchedFile = watch != null && !identical(watch, current.watch);
    final String mappedTitle = (watch?.episodeLabel ?? '').trim();
    return LastPlayback(
      title: switchedFile && mappedTitle.isNotEmpty ? mappedTitle : current.title,
      showTitle: meta?.title,
      titleEn: meta?.titleEn,
      coverUrl: meta?.coverUrl,
      coverReferer: meta?.coverReferer,
      mikanBangumiId: meta?.mikanBangumiId,
      infoHash: hash,
      fileIndex: fileIndex ?? current.fileIndex,
      startPositionMs: positionMs <= 0 ? 0 : positionMs,
      savedAt: DateTime.now(),
    );
  }

  /// 立即写快照（**不节流**）：给"用户明确动作"用（开播 / 收起窗口）。
  ///
  /// 写盘失败只吞掉：记不住"上次播放"不该影响正在进行的播放（与观看记录同一口径）。
  Future<void> _saveSnapshotNow({
    WatchMeta? watch,
    int? fileIndex,
    int? positionMs,
  }) async {
    final LastPlayback? snapshot = _snapshotOfCurrent(
      watch: watch,
      fileIndex: fileIndex,
      positionMs: positionMs ?? _positionMs,
    );
    if (snapshot == null) return;
    try {
      await ref.read(lastPlaybackProvider.notifier).save(snapshot);
      _snapshotSavedAt = DateTime.now();
    } catch (_) {
      // 写盘失败不影响播放；下一次进度/收起还会再试。
    }
  }

  /// 进度上报里的节流写盘（[kSnapshotWriteInterval]）。
  Future<void> _maybeSaveSnapshot({WatchMeta? watch, int? fileIndex}) async {
    final DateTime? last = _snapshotSavedAt;
    if (last != null && DateTime.now().difference(last) < kSnapshotWriteInterval) {
      return;
    }
    await _saveSnapshotNow(watch: watch, fileIndex: fileIndex);
  }

  /// 播放完成 → 自动下一集（可关）。
  Future<void> playNext() async {
    final NowPlaying? current = state.nowPlaying;
    if (current == null || current.upNext.isEmpty) return;
    final SourceItemView next = current.upNext.first;
    await playItem(next,
        upNext: current.upNext.sublist(1, current.upNext.length));
  }

  /// 播放窗口**收起/彻底关闭**时调用（用户关掉播放器 = 这一集看完了）。
  ///
  /// 全套收尾，缺一不可（用户 2026-10-11：「为什么队列里总是有东西」）：
  /// 1. 队列：正在播的那条任务按「留记录但收尾」结算（下完 → 已完成，没下完 → 已暂停）；
  /// 2. 引擎：边车那一份不再后台跑（`settleAfterPlayback` 里按省流量策略 `pause`）。
  ///
  /// **不清 `nowPlaying`**：播放窗口只是收起来了，状态栏那颗「继续播放」还要能把它唤回来
  /// （见 [reopenPlayerWindow]），清了就变成"重新找源"了。
  Future<void> onPlayerWindowHidden() async {
    final NowPlaying? current = state.nowPlaying;
    if (current == null) return;
    try {
      await ref.read(queuePortProvider).settleAfterPlayback(current.engineId);
    } catch (_) {
      // 队列没接通/引擎没起都不该影响关窗本身；下次播放会重新入队。
    }
    await _maybeStopSeeding(current.engineId);
    // 收起/关窗 = 这一集先看到这儿：**强制**写一次快照（节流只约束 `onWatchProgress`，
    // 这是用户明确动作）。不清 `nowPlaying`（还要能唤回），也不清快照（重启后要能继续）。
    await _saveSnapshotNow(positionMs: _positionMs);
  }

  /// 停止播放（并按策略停止做种）。
  Future<void> stop() async {
    final NowPlaying? current = state.nowPlaying;
    _playlist = null; // 停了就不是"在播这一组"了
    try {
      await ref.read(playerPortProvider).stop();
    } catch (_) {
      // 播放器未接通时忽略：下面照样清状态、照样停做种。
    }
    if (current != null) await _maybeStopSeeding(current.engineId);
    // 用户主动停止 = 这一集不再继续看：快照一起清掉（否则重启后侧栏又冒出来一行）。
    _positionMs = 0;
    _snapshotSavedAt = null;
    try {
      await ref.read(lastPlaybackProvider.notifier).clear();
    } catch (_) {
      // 清不掉也不阻塞停止；下次开播会覆盖它。
    }
    state = const PlaybackUiState();
  }

  /// 暂停弹出播放窗口里的播放（**不关窗**：播放面必须常驻，契约 §5）。
  ///
  /// 与 [stop] 的区别：状态栏那颗暂停按钮要「停下但留住窗口」，所以只发暂停、
  /// 不动做种策略、不清 `nowPlaying`（窗口还在，用户点继续就能接着看）。
  Future<void> pauseWindow() async {
    try {
      await ref.read(playerPortProvider).playOrPause();
    } catch (_) {
      // 播放窗口没开/已关：忽略。
    }
    state = state.copyWith(playing: false);
  }

  /// 重新唤回（或首次打开）播放窗口并继续播当前这一集。
  ///
  /// 用户在状态栏点「继续播放」时走这里：`nowPlaying` 还在（关窗不清状态），
  /// 串流地址由引擎按 `engineId/fileIndex` 重新给出（边车还在跑，地址照旧可播）。
  Future<void> reopenPlayerWindow() async {
    final NowPlaying? current = state.nowPlaying;
    if (current == null) return;
    // 第四十二轮 UX #9：整个身体再包一层 —— `_ensureEngineRunning` / 拿 torrent
    // 这两步也会抛（引擎刚挂、边车重启中），而它们原来在下面那个 try **外面**：
    // 异常会从这里冒到调用方（侧栏那句 `unawaited(...)`），于是"点了没反应"。
    // 这一层让本方法**全域**：任何失败都变成 `state.failure`，调用方只管读它。
    try {
      await _reopenPlayerWindowInner(current);
    } catch (error, stackTrace) {
      state = state.copyWith(
        failure: describeFailure(error, stackTrace: stackTrace),
      );
    }
  }

  Future<void> _reopenPlayerWindowInner(NowPlaying current) async {
    // 关窗时按省流量策略把 torrent 停过（`settleAfterPlayback`）：再打开必须让它接着跑，
    // 否则没下完的那一集会在暂停状态下边播边卡。
    await _ensureEngineRunning(current.engineId);
    final Uri? url =
        ref.read(enginePortProvider).streamUrl(current.engineId, current.fileIndex);
    if (url == null) {
      state = state.copyWith(
        failure: describeFailure(_engineNotConnected),
      );
      return;
    }
    final EngineTorrentView? torrent =
        await _torrentById(ref.read(enginePortProvider), current.engineId);
    final EpisodeGrouping? torrentGroup = torrent == null
        ? null
        : episodeGroupingFor(
            torrent: torrent,
            fileIndex: current.fileIndex,
            engine: ref.read(enginePortProvider),
          );
    try {
      // 续播（用户 2026-10-18：「发现bug继续观看回不到上一次的观看位置」）：
      // 「唤回」语义就是**接着看**，起点必须由宿主显式给 —— 子窗口自己那份按
      // 串流 URL 记的续播（`SettingsController.resumeKey` = md5(URL|size)）不一定命中
      // （URL 上挂着边车 token；边车重启/换端口就是另一个键），而宿主这边的
      // `_positionMs` 与观看记录同源，是可靠的那一份。
      final int? resumeMs = _positionMs > 0 ? _positionMs : null;
      await ref.read(playerPortProvider).open(
            PlayerRequest(
              streamUrl: url,
              title: current.title,
              engineId: current.engineId,
              fileIndex: current.fileIndex,
              startAt: resumeMs == null ? null : Duration(milliseconds: resumeMs),
            ),
            episodeGroup: torrentGroup,
          );
      _ensureSubscribed();
      // 唤回时引擎给的串流地址带的是**新 token**：观看记录的归位表（URL → 哪一集）
      // 必须跟着重算，否则子窗口在里面切到同种子的另一集时，`watchByUrl[新URL]`
      // 查不到 → 进度又记回当前这一条（第二十七轮复核指出的可疑点，这里直接修掉）。
      state = state.copyWith(
        clearFailure: true,
        nowPlaying: current.copyWith(
          watchByUrl: _watchByUrlForGroup(
            show: current.watch ?? buildWatchMeta(title: current.title),
            torrent: torrent,
            group: torrentGroup,
            currentUrl: url,
            currentFileIndex: current.fileIndex,
          ),
        ),
      );
    } catch (error, stackTrace) {
      state = state.copyWith(
        failure: describeFailure(error, stackTrace: stackTrace),
      );
    }
  }

  /// 点侧栏「继续播放」那行（**重启后**：只有 `restored`、没有 `nowPlaying` 时）：
  /// 拿快照里的 infoHash 回引擎找 torrent，找到就从快照的位置接着播。
  ///
  /// 为什么按 infoHash 找而不是 `engineId`：`engineId` 是引擎进程内的编号，
  /// 重启边车/重启宿主都会变 —— 与「观看记录」页 `_play` 同一个教训、同一套做法。
  ///
  /// 不静默：找不到 torrent/文件时把原因写进 `state.failure`，并**保留** `restored`
  /// （不许把用户的上次记录无声吞掉；行还在、失败横幅说清为什么）。
  Future<void> resumeRestored() async {
    final LastPlayback? snapshot = state.restored;
    if (snapshot == null) return;
    // 已经有在播的东西时，侧栏那行走的是"唤回"那条路；这里兜底一下，别把在播的顶掉。
    if (state.nowPlaying != null) {
      await reopenPlayerWindow();
      return;
    }
    state = state.copyWith(busy: true, clearFailure: true);
    try {
      final List<EngineTorrentView> torrents = await _listForResume();
      EngineTorrentView? torrent;
      for (final EngineTorrentView candidate in torrents) {
        if (candidate.infoHash == snapshot.infoHash) {
          torrent = candidate;
          break;
        }
      }
      // 按 `file.index` 找，而不是拿 `files[fileIndex]` 当下标：串流地址里的序号是
      // 引擎的 `index`（一般与下标一致，但这里不赌"一致"）。
      EngineFileView? file;
      for (final EngineFileView candidate in torrent?.files ?? const <EngineFileView>[]) {
        if (candidate.index == snapshot.fileIndex) {
          file = candidate;
          break;
        }
      }
      final EngineTorrentView? foundTorrent = torrent;
      final EngineFileView? foundFile = file;
      if (foundTorrent == null || foundFile == null) {
        state = state.copyWith(
          busy: false,
          failure: const DsFailure(
            '上次看的种子已经不在引擎里了，没法从上次的位置接着播',
            hint: '可能被移除、换过种子，或边车这次是全新会话（重启前的任务没恢复）。'
                '到「已完成」或「正在追」重新点一集；右键侧栏那行「继续播放」可以忘掉它',
          ),
        );
        return;
      }
      // `playTorrentFile` 内部会先 `_ensureEngineRunning`（resume 那条 torrent）再取流，
      // 所以这里不重复调；（它失败时会自己写 `state.failure`，并保留 `restored`）。
      await playTorrentFile(
        torrent: foundTorrent,
        file: foundFile,
        showTitle: snapshot.showTitle ?? snapshot.title,
        showTitleEn: snapshot.titleEn,
        coverUrl: snapshot.coverUrl,
        coverReferer: snapshot.coverReferer,
        mikanBangumiId: snapshot.mikanBangumiId,
        startPositionMs: snapshot.startPositionMs,
      );
    } catch (error, stackTrace) {
      // 重试窗口过了边车还没接上：给一条"等一下再点"的可行动文案，
      // 而不是把 `_notConnected` 那条（面向"边车没运行"的）原样丢给用户。
      if (error is PortUnavailableException && error.message.contains('未连接')) {
        state = state.copyWith(
          busy: false,
          failure: const DsFailure(
            '边车还没连上，暂时没法恢复上次的播放',
            hint: '引擎可能还在启动（冷启动约 1–3 秒）：等一下就绪后再点一次「继续播放」；'
                '一直连不上就到「设置 → 引擎」点「启动 / 重连引擎」',
          ),
        );
        return;
      }
      state = state.copyWith(
        busy: false,
        failure: describeFailure(error, stackTrace: stackTrace),
      );
    }
  }

  /// 取引擎 torrent 列表；**重启后边车可能还在启动**，给一小段重试窗口。
  ///
  /// 为什么：`main.dart` 拉起边车是 `unawaited` 的（冷启动约 1–3.5s），而用户很可能
  /// 一看到「继续播放」那行就点 —— 第一次就弹"引擎未连接"会让人以为这个功能坏了。
  /// 只在「引擎还没接上」（`PortUnavailableException`）时重试，最多约 3 秒；
  /// 其它错误（鉴权/超时/HTTP 5xx）立刻原样抛出，不拖时间。
  Future<List<EngineTorrentView>> _listForResume() async {
    const int attempts = 6;
    const Duration interval = Duration(milliseconds: 500);
    for (int attempt = 0; ; attempt++) {
      try {
        return await ref.read(enginePortProvider).list();
      } on PortUnavailableException catch (error, stackTrace) {
        if (attempt + 1 >= attempts || !ref.mounted) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        await Future<void>.delayed(interval);
      }
    }
  }

  /// 忘掉「上次播放」快照（侧栏那行「继续播放」右键）。
  ///
  /// 为什么需要这个出口：恢复失败时 `restored` 是**故意保留**的（不许无声吞掉用户的上次
  /// 记录），但那时用户也得有办法把这条"点了总失败"的行清掉 —— 否则每次启动都冒出来。
  Future<void> forgetRestored() async {
    if (state.restored == null) return;
    try {
      await ref.read(lastPlaybackProvider.notifier).clear();
    } catch (_) {
      // 清不掉也要让界面先别显示它（内存态是这次会话的真相；下次启动若还在，再清一次）。
    }
    state = state.copyWith(clearRestored: true, clearFailure: true);
  }

  /// 解析可播目标：先试 core 的队列（入队 + 预取），再退化到直接加种。
  ///
  /// [preheatBatch] = 预热素材（第三十八轮，整批；core 按档位挑"当前集之后最近的 N 集"）。
  Future<PlayTarget> _prepare(
    SourceItemView item,
    List<SourceItemView> upNext, {
    List<SourceItemView> preheatBatch = const <SourceItemView>[],
  }) async {
    final EnginePort engine = ref.read(enginePortProvider);
    try {
      final QueueJobView job = await ref
          .read(queuePortProvider)
          .enqueuePlayNow(item, upNext: upNext, preheat: preheatBatch);
      final int? engineId = job.engineId;
      final int? fileIndex = job.fileIndex;
      if (engineId != null && fileIndex != null) {
        final Uri? url = engine.streamUrl(engineId, fileIndex);
        if (url == null) throw _engineNotConnected;
        return PlayTarget(
          engineId: engineId,
          fileIndex: fileIndex,
          streamUrl: url,
          // 归组要整份文件清单：队列这条路只有 id，引擎侧再取一次（取不到就算了）。
          torrent: await _torrentById(engine, engineId),
        );
      }
      // 队列已经收下了任务但还没给出文件索引（元数据未就绪）：用引擎侧再查一次。
    } on PortUnavailableException {
      // core 的 QueueManager 未注入 → 走直连路径（下面）。
    }

    final String? magnet = item.magnet;
    final String? torrentUrl = item.torrentUrl;
    if (magnet == null || magnet.trim().isEmpty) {
      throw PortUnavailableException(
        magnet == null && (torrentUrl == null || torrentUrl.trim().isEmpty)
            ? '这条结果既没有磁力链也没有 .torrent 直链，无法播放'
            : '这条结果只有 .torrent 直链：需要 core 的下载队列（当前未接通）才能取回种子',
        hint: '换一条带磁力链（magnet）的结果；或等 core 的 sources/subs 接通后重试',
      );
    }
    final EngineTorrentView torrent = await engine.addMagnet(
      magnet.trim(),
      name: item.displayTitle,
    );
    final EngineFileView? video = torrent.playableFile;
    if (video == null) {
      throw const PortUnavailableException(
        '该种子还没有识别出视频文件',
        hint: '元数据可能仍在获取（磁力链首连较慢）；稍等后到队列页确认文件列表再试',
      );
    }
    final Uri? url = engine.streamUrl(torrent.id, video.index);
    if (url == null) throw _engineNotConnected;
    return PlayTarget(
      engineId: torrent.id,
      fileIndex: video.index,
      streamUrl: url,
      subtitlePath: _subtitlePathOf(torrent, video),
      torrent: torrent,
    );
  }

  /// 引擎侧按 id 取 torrent 视图；引擎未连接 / 还没有这条就返回 null
  /// （归组是"锦上添花"，取不到只意味着播放器不显示上一集/下一集按钮）。
  Future<EngineTorrentView?> _torrentById(EnginePort engine, int id) async {
    try {
      for (final EngineTorrentView t in await engine.list()) {
        if (t.id == id) return t;
      }
    } catch (_) {
      // 引擎未连接/查询失败：不影响起播。
    }
    return null;
  }

  /// 同目录且**已下完**的外挂字幕才交给 mpv（没下完的路径不存在，给了反而报错）。
  String? _subtitlePathOf(EngineTorrentView torrent, EngineFileView video) {
    final String videoDir = p.dirname(video.path.replaceAll('\\', '/'));
    for (final EngineFileView sub in torrent.subtitleFiles) {
      if (!sub.complete) continue;
      final String subDir = p.dirname(sub.path.replaceAll('\\', '/'));
      if (subDir != videoDir) continue;
      if (torrent.outputFolder.isEmpty) continue;
      return p.join(torrent.outputFolder, sub.path);
    }
    return null;
  }

  Future<void> _onSignal(PlaybackSignal signal) async {
    if (!ref.mounted) return;
    switch (signal) {
      case PlaybackPlayingChanged(:final bool playing):
        state = state.copyWith(playing: playing);
      case PlaybackCompleted():
        final AppSettings settings = ref.read(settingsProvider);
        final NowPlaying? current = state.nowPlaying;
        if (settings.autoPlayNext && current != null && current.upNext.isNotEmpty) {
          await playNext();
        } else if (current != null) {
          await _maybeStopSeeding(current.engineId);
        }
      case PlaybackFailure(:final String message):
        state = state.copyWith(
          failure: DsFailure(
            '播放器报错：$message',
            hint: '常见原因：串流 URL 已失效（引擎重启过）、token 不匹配、'
                '或该分片还没下载到。可到“正在播放”页重试。',
          ),
        );
      case PlaybackPosition():
        break; // 进度由内嵌播放器自带的控制栏展示，宿主不重复渲染
    }
  }

  /// 省流量策略：切集/播完不再做种。
  Future<void> _stopSeedingOnSwitch() async {
    final NowPlaying? current = state.nowPlaying;
    if (current == null) return;
    await _maybeStopSeeding(current.engineId);
  }

  Future<void> _maybeStopSeeding(int engineId) async {
    if (!ref.read(settingsProvider).bandwidth.stopSeedingAfterPlayback) return;
    try {
      await ref.read(enginePortProvider).pause(engineId);
    } catch (_) {
      // 引擎未连接/已移除：忽略（这不是用户要处理的错误）。
    }
  }

  /// 起播前确保引擎那一份是**在跑**的（可能被省流量策略或重启收尾暂停过）。
  ///
  /// 只 resume，不做别的：引擎未连接/任务已移除时静默忽略，后面的取流地址与播放器
  /// 打开照旧会给出真实错误。
  Future<void> _ensureEngineRunning(int engineId) async {
    try {
      await ref.read(enginePortProvider).resume(engineId);
    } catch (_) {
      // 忽略：真正的问题会在取 streamUrl / 打开播放窗口时暴露。
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 起播后的「补全集」
  //
  // 用户原话：「播放列表里的视频不全，加逻辑，播放视频后，使用正则方式加载其他全集。」
  // 做法：拿正在播的那一条的标题切出关键字，去同一个源翻页搜索，把其它集并进播放列表，
  // 再把新的组推给**已经开着**的播放子窗口（不重开窗、不动当前播放）。
  // ───────────────────────────────────────────────────────────────────────────

  /// 列表明显不全时，按关键字补全集；补到了就换列表并把新组推给播放窗口。
  ///
  /// 为什么只在"明显不全"时动手：源站有请求间隔限制，每次起播都搜一下会把源站当成
  /// 扫描对象，而大多数时候 mikan 番剧页已经给全了（判据见
  /// [seriesPlaylistLooksIncomplete]，那里写了"为什么是这个判据"）。
  ///
  /// 这个方法**永不抛**，也**不改当前播放**：补全集只是"锦上添花"。
  Future<void> _backfillSeries({
    required SourceItemView original,
    required List<SourceItemView> batch,
    required Playlist? current,
    required int engineId,
    required int fileIndex,
  }) async {
    if (!seriesPlaylistLooksIncomplete(current, batch)) return;
    try {
      final SeriesLoadResult result = await loadSeriesPlaylist(
        source: ref.read(sourcePortProvider),
        base: original,
        batch: batch,
        current: current,
      );
      if (!ref.mounted) return;
      final Playlist? next = result.playlist;
      // 没补到（loader 在原列表没变时回传的就是 `current` 本身）：什么都不做。
      if (next == null || next.items.length <= (current?.items.length ?? 0)) return;
      // 起播上下文已经变了（用户换了集 / 停了 / 关了窗）：这份结果属于上一集，
      // 盖回去会让播放窗口的列表跟着串片。判据用 `engineId/fileIndex`（正在播的那条
      // 流的身份），不用标题 —— `_ensurePlayable` 补过详情的标题可能与原始条目不
      // 完全一样，拿标题比会把正常结果也丢掉。
      final NowPlaying? now = state.nowPlaying;
      if (now == null || now.engineId != engineId || now.fileIndex != fileIndex) return;
      _playlist = next;
      _pushSeriesGroup(next);
    } catch (_) {
      // 补全集是锦上添花：任何意外都不该影响正在进行的播放。
    }
  }

  /// 把新的组推给**已经开着**的播放子窗口。
  ///
  /// 子窗口是独立 isolate，只能靠 `kMethodArgs` 推值：`episodeGroupProvider` 一变，
  /// 播放面右侧的播放列表就重建（`pushArgs` 自己做了"同值不推"去重）。
  /// 服务没接通（内嵌播放 / 组件测试）时静默降级 —— 列表状态已经在本控制器里更新了，
  /// 下次开窗会带着新的组过去。
  void _pushSeriesGroup(Playlist list) {
    try {
      unawaited(ref.read(playerWindowServiceProvider).pushArgs(
            episodeGroup: encodeEpisodeGroup(
              _groupingOf(list),
              autoNext: ref.read(settingsProvider).autoPlayNext,
            ),
          ));
    } catch (_) {
      // 推环境失败不影响播放（`pushArgs` 内部也吞了通道异常，这里只是兜底）。
    }
  }
}

const PortUnavailableException _engineNotConnected = PortUnavailableException(
  '引擎未连接：拿不到串流地址，无法起播',
  hint: '到「设置 → 引擎」确认 rqbit-engine.exe 路径与下载目录，点「启动 / 重连引擎」',
);

final NotifierProvider<PlaybackController, PlaybackUiState> playbackProvider =
    NotifierProvider<PlaybackController, PlaybackUiState>(
        PlaybackController.new);

/// 当前播放集对应的引擎进度（浮层数据源）。没有匹配时返回 null。
final Provider<EngineProgressSnapshot?> nowPlayingProgressProvider =
    Provider<EngineProgressSnapshot?>((Ref ref) {
  final NowPlaying? current = ref.watch(playbackProvider).nowPlaying;
  if (current == null) return null;
  final EngineTorrentView? torrent =
      ref.watch(torrentByIdProvider(current.engineId));
  if (torrent == null) return null;
  EngineFileView? file;
  for (final EngineFileView f in torrent.files) {
    if (f.index == current.fileIndex) file = f;
  }
  return EngineProgressSnapshot(torrent: torrent, file: file);
});

/// 播放浮层用的只读快照。
@immutable
class EngineProgressSnapshot {
  final EngineTorrentView torrent;
  final EngineFileView? file;
  const EngineProgressSnapshot({required this.torrent, this.file});
}

/// 当前集所在的那一组剧集（决策 B31「在哪播的在哪搜」）。
///
/// 网流场景（宿主唯一的投递方式）下没有真实文件夹，所以按**引擎的 torrent 文件清单**
/// 归组：同一个 torrent 里的视频文件就是同一部番的各集，每集有自己的 per-file
/// 串流 URL（`streamUrl(id, fileIndex)`）。归组规则与「集号解析」在
/// `domain/episode_group.dart` 里（有单测，含用户给的真实番剧命名）。
///
/// 返回 null = 没有组信息（单集 / torrent 还没拿到文件清单 / 引擎未连接），
/// 播放器会**隐藏**上一集/下一集按钮。
final Provider<EpisodeGrouping?> currentEpisodeGroupProvider =
    Provider<EpisodeGrouping?>((Ref ref) {
  final NowPlaying? current = ref.watch(playbackProvider).nowPlaying;
  if (current == null) return null;
  final EngineTorrentView? torrent =
      ref.watch(torrentByIdProvider(current.engineId));
  if (torrent == null) return null;
  return episodeGroupingFor(
    torrent: torrent,
    fileIndex: current.fileIndex,
    engine: ref.watch(enginePortProvider),
  );
});

/// 按 torrent 的文件清单归组（[currentEpisodeGroupProvider] 与播放投递共用一份逻辑）。
///
/// 投递时**不能**读 `currentEpisodeGroupProvider`：那一刻 `nowPlaying` 还是上一集
/// （`playItem` 先 open 再写状态），分组会算错当前集。所以投递用刚解析出来的
/// `engineId/fileIndex` 直接算，见 [PlaybackController.playItem]。
EpisodeGrouping? episodeGroupingFor({
  required EngineTorrentView torrent,
  required int fileIndex,
  required EnginePort engine,
}) {
  final List<EpisodeEntry> entries = <EpisodeEntry>[];
  for (final EngineFileView f in torrent.files) {
    if (!f.isVideo) continue;
    final Uri? url = engine.streamUrl(torrent.id, f.index);
    entries.add(EpisodeEntry(
      // 标题取文件名（去掉扩展名），播放器列表里显示这一条。
      title: p.basenameWithoutExtension(f.path),
      // 网流：path 存 URL 文本（与 MediaItem.path 语义一致），streamUri 存完整 URL。
      path: url?.toString() ?? '${torrent.id}/files/${f.index}',
      streamUri: url,
      // 集号**必须在这里就解析好**（从文件名），不能留给 `groupEpisodes` 去猜：
      // 它拿 `e.path` 解析，而这里的 path 是**串流 URL**
      //（`…/torrents/3/files/0/stream?token=…`）⇒ basename 是 `stream?token=…`，
      // 一个数字都没有 ⇒ 每一集都被丢掉 ⇒ 整组返回 null ⇒ 合并种子
      //（一个 torrent 里好几集）连「上一集 / 下一集 / 播放列表」都不显示。
      // 第十三轮实测复现：`groupEpisodes` 在这个形状下返回 null。
      // 传了集号之后 `groupEpisodes` 走 explicitMode：判据变成「同一个 torrent」，
      // 正是它文档里写的调用契约。
      episode: parseEpisodeNumber(p.basename(f.path)),
    ));
  }
  if (entries.isEmpty) return null;

  // 当前集在候选里的 key：优先用它自己的串流 URL（引擎给的就是这个）。
  final Uri? currentUrl = engine.streamUrl(torrent.id, fileIndex);
  final String currentKey =
      currentUrl?.toString() ?? '${torrent.id}/files/$fileIndex';
  return groupEpisodes(entries, currentKey);
}
