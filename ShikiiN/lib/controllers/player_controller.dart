import 'dart:async';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../models/media_item.dart';
import '../models/track.dart' as app;
import '../models/video_fit_mode.dart';
import '../models/subtitle_style.dart';
import '../models/video_stats.dart';
import '../infra/diagnostics/diag.dart';

/// 封装 media_kit Player，暴露内置播放器需要的播放/轨道/超分接线（契约 §2）。
///
/// 已按契约删除：画面调节/滤镜、均衡器、A-B 循环、章节、字幕延迟、截图与抓帧、
/// 音量增强、倍速、拖动预览（scrubTo）、音频设备、关闭字幕（改用
/// `setSubtitleTrackById(null)`）。
class PlayerController {
  // logLevel: warn → libmpv emits fatal/error/warn to Player.stream.log, the
  // most valuable pre-crash signal (default is error-only). Routed by mpv_log_bridge.
  final Player player = Player(
    configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
  );

  /// 提前创建并长期持有的视频输出控制器。必须在任何 open() 之前就存在，
  /// 否则首个视频的纹理初始化滞后，会出现「有声无画」。
  late final VideoController video = VideoController(player);

  /// Cached reference to the native mpv backend (Windows/Linux/macOS/iOS/Android).
  /// Cast is safe: on all supported platforms, player.platform is NativePlayer.
  NativePlayer get _native => player.platform! as NativePlayer;

  /// 当前播放媒体的标识（与续播 key 一致；勿用 media_kit 规范化后的 uri）。
  String? _currentPath;
  String? get currentPath => _currentPath;

  /// 当前媒体是否已有带尺寸的视频轨（纯音频/未加载 → false）。
  bool get hasVideo =>
      (player.state.width ?? 0) > 0 && (player.state.height ?? 0) > 0;

  Future<void> open(MediaItem item, {Duration? startAt}) async {
    _currentPath = item.path;
    await player.open(Media(item.path));
    if (startAt != null && startAt > Duration.zero) {
      await player.seek(startAt);
    }
  }

  /// 等「下一次」视频输出重配置完成（首个带有效尺寸的 videoParams）。
  /// 返回 true=已就绪；false=超时或无视频轨（纯音频）。
  ///
  /// 用途：换片后超分等依赖 GPU 渲染上下文的命令，必须等新文件的 VO 重建完成再
  /// 下发，否则与重建竞争会触发 libmpv 原生崩溃。videoParams 是无重放的 broadcast
  /// 流，故须在 [open] 之前调用本方法订阅、open 之后再 await，才不会漏掉重配置事件。
  Future<bool> nextVideoReconfig(
      {Duration timeout = const Duration(seconds: 8)}) {
    final completer = Completer<bool>();
    Timer? timer;
    late final StreamSubscription<VideoParams> sub;
    void finish(bool ready) {
      if (completer.isCompleted) return;
      timer?.cancel();
      sub.cancel();
      completer.complete(ready);
    }

    sub = player.stream.videoParams.listen(
      (vp) {
        if ((vp.w ?? 0) > 0 && (vp.h ?? 0) > 0) finish(true);
      },
      onError: (_) => finish(false),
    );
    timer = Timer(timeout, () => finish(false));
    return completer.future;
  }

  Future<void> playOrPause() => player.playOrPause();
  Future<void> play() => player.play();
  Future<void> pause() => player.pause();

  Future<void> seekBy(Duration delta) async {
    final target = player.state.position + delta;
    await player.seek(target < Duration.zero ? Duration.zero : target);
  }

  Future<void> seekTo(Duration position) => player.seek(position);

  /// 相对关键帧 seek：快且画面跟随（mpv `seek <n> relative+keyframes`）。
  /// 用于长按连续快进退（契约 §6）——精确 absolute seek 每 tick 一发会卡顿
  /// 且画面不刷新，故保留这条既有路径。
  Future<void> seekRelative(double seconds) async {
    try {
      await _native.command(['seek', seconds.toString(), 'relative+keyframes']);
    } catch (e, st) {
      diag.warn('player', 'seekRelative failed', e, st);
    }
  }

  Future<void> setVolume(double v) async {
    try {
      await player.setVolume(v.clamp(0, 100));
    } catch (e, st) {
      diag.warn('player', 'setVolume failed', e, st);
    }
  }

  Future<void> nudgeVolume(double delta) => setVolume(player.state.volume + delta);
  Future<void> toggleMute() =>
      player.setVolume(player.state.volume == 0 ? 100 : 0);

  /// 当前激活的音轨 / 字幕轨 id（用于面板/菜单高亮）。
  int? get activeAudioId => int.tryParse(player.state.track.audio.id);
  int? get activeSubtitleId => int.tryParse(player.state.track.subtitle.id);

  /// 轨道列表（音/字幕）。
  List<app.TrackInfo> get audioTracks => player.state.tracks.audio
      .map((t) => app.TrackInfo(
            id: int.tryParse(t.id) ?? -1,
            kind: app.TrackKind.audio,
            label: _trackLabel(t),
          ))
      .toList();

  List<app.TrackInfo> get subtitleTracks => player.state.tracks.subtitle
      .map((t) => app.TrackInfo(
            id: int.tryParse(t.id) ?? -1,
            kind: app.TrackKind.subtitle,
            label: _trackLabel(t),
          ))
      .toList();

  /// 按 id 选音轨；[id] 为 null → 恢复自动选轨。
  Future<void> setAudioTrackById(int? id) async {
    if (id == null) {
      await player.setAudioTrack(AudioTrack.auto());
      return;
    }
    final t = player.state.tracks.audio.firstWhere(
      (e) => int.tryParse(e.id) == id,
      orElse: AudioTrack.auto,
    );
    await player.setAudioTrack(t);
  }

  /// 按 id 选字幕轨；[id] 为 null → 关闭字幕。
  Future<void> setSubtitleTrackById(int? id) async {
    if (id == null) {
      await player.setSubtitleTrack(SubtitleTrack.no());
      return;
    }
    final t = player.state.tracks.subtitle.firstWhere(
      (e) => int.tryParse(e.id) == id,
      orElse: SubtitleTrack.auto,
    );
    await player.setSubtitleTrack(t);
  }

  Future<void> cycleAudio() async {
    final tracks = player.state.tracks.audio;
    if (tracks.length < 2) return;
    final cur = player.state.track.audio;
    final idx = tracks.indexWhere((e) => e.id == cur.id);
    await player.setAudioTrack(tracks[(idx + 1) % tracks.length]);
  }

  Future<void> cycleSubtitle() async {
    final tracks = player.state.tracks.subtitle;
    if (tracks.length < 2) return;
    final cur = player.state.track.subtitle;
    final idx = tracks.indexWhere((e) => e.id == cur.id);
    await player.setSubtitleTrack(tracks[(idx + 1) % tracks.length]);
  }

  /// 外挂字幕。
  Future<void> addExternalSubtitle(String path) =>
      player.setSubtitleTrack(SubtitleTrack.uri(path));

  // ── Video fit ────────────────────────────────────────────────────────────────

  VideoFitMode _fit = VideoFitMode.keepAspect;
  VideoFitMode get fit => _fit;

  Future<void> setFitMode(VideoFitMode mode) async {
    _fit = mode;
    for (final e in mode.toMpvProperties().entries) {
      await _native.setProperty(e.key, e.value);
    }
  }

  // ── Subtitle style ───────────────────────────────────────────────────────────

  SubtitleStyle _subtitleStyle = const SubtitleStyle();
  SubtitleStyle get subtitleStyle => _subtitleStyle;

  Future<void> applySubtitleStyle(SubtitleStyle s) async {
    _subtitleStyle = s;
    Future<void> set(String k, String v) async {
      try {
        await _native.setProperty(k, v);
      } catch (e, st) {
        diag.warn('player', 'subtitle prop $k failed', e, st);
      }
    }

    for (final e in s.toMpvProperties().entries) {
      await set(e.key, e.value);
    }
    // 兼容旧 mpv 的覆盖属性名（新: sub-ass-override / 旧: ass-style-override）。
    final ov = s.overrideAss ? 'force' : 'no';
    await set('ass-style-override', ov);
    // ASS 字幕改样式后常需重新渲染：重选当前字幕轨触发刷新。
    try {
      final cur = player.state.track.subtitle;
      await player.setSubtitleTrack(cur);
    } catch (e, st) {
      diag.warn('player', 'subtitle re-select failed', e, st);
    }
  }

  // ── 原生命令（供 Anime4K / mpv 缩放器超分下发）─────────────────────────────
  /// 执行一条 libmpv 命令（如 change-list glsl-shaders set ...）。
  /// 返回 0=已下发，-1=抛异常被吞（调用方一般不关心）。
  Future<int> runMpvCommand(List<String> args) async {
    try {
      await _native.command(args);
      return 0;
    } catch (e, st) {
      diag.warn('player', 'mpv command ${args.isEmpty ? '?' : args.first} failed', e, st);
      return -1;
    }
  }

  /// 读一个 mpv 属性（超分诊断：记录硬解状态/像素格式，判断 LUMA 钩子是否被旁路）。
  /// 读不到返回空串：调用方按「未知」处理，绝不据此写任何 mpv 属性。
  Future<String> readMpvProperty(String name) async {
    try {
      return await _native.getProperty(name);
    } catch (e, st) {
      diag.warn('player', 'mpv get property $name failed', e, st);
      return '';
    }
  }

  // ── Stop ─────────────────────────────────────────────────────────────────────

  /// 停止并卸载当前媒体，回到空态覆盖层。
  Future<void> stop() async {
    _currentPath = null;
    await player.stop();
  }

  // ── 视频数据快照（Tab 浮层）────────────────────────────────────────────────
  // 「实际帧率」需跨两次采样按丢帧增量算，故保留上次采样的丢帧数与时刻。
  int? _lastDropCount;
  DateTime? _lastDropAt;

  /// 读取一组 mpv 属性构造 [VideoStats]；单项读取失败回退空串（fromProps 再转占位）。
  /// 「实际帧率」= 输出帧率 − 本采样窗内的丢帧率（GPU 着色器/超分卡顿时会下降）。
  Future<VideoStats> getStatsSnapshot() async {
    Future<String> read(String name) async {
      try {
        return await _native.getProperty(name);
      } catch (_) {
        return '';
      }
    }

    final estVfFps = await read('estimated-vf-fps');
    final containerFps = await read('container-fps');
    final dropStr = await read('frame-drop-count');

    return VideoStats.fromProps(
      {
        'estimated-vf-fps': estVfFps,
        'container-fps': containerFps,
        'display-fps': await read('display-fps'),
        'width': await read('width'),
        'height': await read('height'),
        'video-bitrate': await read('video-bitrate'),
        'frame-drop-count': dropStr,
        'video-codec': await read('video-codec'),
        'video-params/pixelformat': await read('video-params/pixelformat'),
        'hwdec-current': await read('hwdec-current'),
        'avsync': await read('avsync'),
        'speed': await read('speed'),
        'audio-codec-name': await read('audio-codec-name'),
        'audio-bitrate': await read('audio-bitrate'),
        'audio-params/samplerate': await read('audio-params/samplerate'),
        'audio-params/channels': await read('audio-params/channels'),
      },
      renderedFps: _computeRenderedFps(estVfFps, containerFps, dropStr),
    );
  }

  /// 实际帧率：以输出帧率为基准，扣掉本采样窗内的平均丢帧率，并钳到 [0, 基准]。
  /// 首次采样无上次数据 → 返回 '—'；文件切换导致丢帧计数回退 → 钳回基准。
  String _computeRenderedFps(String estVf, String container, String dropStr) {
    final now = DateTime.now();
    final drops = int.tryParse(dropStr.trim());
    final base = double.tryParse(estVf.trim()) ?? double.tryParse(container.trim());
    var result = '—';
    if (drops != null && base != null && base > 0 && _lastDropCount != null && _lastDropAt != null) {
      final dt = now.difference(_lastDropAt!).inMilliseconds / 1000.0;
      if (dt > 0) {
        final rate = (drops - _lastDropCount!) / dt;
        final actual = (base - rate).clamp(0.0, base);
        result = actual.toStringAsFixed(1);
      }
    }
    _lastDropCount = drops;
    _lastDropAt = now;
    return result;
  }

  // ─────────────────────────────────────────────────────────────────────────────

  String _trackLabel(dynamic t) {
    final title = (t.title as String?)?.trim();
    final lang = (t.language as String?)?.trim();
    if (title != null && title.isNotEmpty) return title;
    if (lang != null && lang.isNotEmpty) return lang;
    return '轨道 ${t.id}';
  }

  void dispose() {
    player.dispose();
  }
}
