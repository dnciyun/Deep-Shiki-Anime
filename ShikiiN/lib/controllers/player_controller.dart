import 'dart:async';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../models/audio_fx.dart';
import '../models/debug_mpv_vf.dart';
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
    // 只有真的要从中间开始才等：从头播（绝大多数开播）不该为此多拖一拍。
    final Duration? target =
        (startAt != null && startAt > Duration.zero) ? startAt : null;
    // ⚠️ 必须**先订阅**「这次的文件真的加载起来了」再 `player.open`：
    // media_kit 的 `open()` 只是把 `loadlist` 命令交给 mpv（`real.dart` 实测），
    // 并不等文件 load 完；紧随其后的 `seek` 会撞上"还没有文件"→ mpv 返回
    // `error running command _command(seek, …)` 并**丢掉这次 seek**，画面从 0 开始。
    // 真机日志 2026-10-18 17:22:20 就是这个（用户报「点的继续播放不生效」）。
    // `duration` 流是 broadcast（无重放），所以只能提前订阅；`open()` 内部
    // 会先 `stop(open: true)`（把 duration 推成 0）再载入新文件，因此一定会有
    // 「0 → 新值」的顺序，不会漏。
    final Future<bool>? ready =
        target == null ? null : waitUntilMediaReady(player.stream.duration);
    await player.open(Media(item.path));
    // 调试开关（见 models/debug_mpv_vf.dart）：只有设了 DSANIMA_MPV_VF 才下发，
    // 且用 `set` 而不是 `add` —— 每次 open 都下发也不会把滤镜叠加成一串。
    await applyNvVsr();
    // 音效（audio-pack）：与 VSR 同一时刻下发；没装包/没开 = 清空 af（原声）。
    await applyAudioFx();
    if (target == null) return;
    // 等不到（直播没有时长、或者超时）也**照试一次**：seek 失败只记日志，
    // 绝不让"开播"本身失败。
    if (ready != null) await ready;
    try {
      await player.seek(target);
    } catch (e, st) {
      diag.warn('player', 'resume seek failed（这次从 0 开始）', e, st);
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

  /// 本播放器用的 NV-VSR 滤镜串（内置默认，可被环境变量/目录 txt 调试覆盖）。
  String get nvVsrSpec => debugMpvVf(fileText: debugMpvVfFile());

  /// 运行时探测结果：滤镜被 libmpv 拒了（`vf` 回读里没有它）→ 以后不再试、菜单也不显示。
  bool _nvVsrUnsupported = false;

  /// VSR 可用 = 有滤镜串、且没被运行时判定为不支持。
  bool get nvVsrAvailable => nvVsrSpec.isNotEmpty && !_nvVsrUnsupported;

  /// VSR 当前是否开着。**不可用时恒为 false**（菜单据此不显示）。
  bool get nvVsrEnabled => nvVsrAvailable && _nvVsrEnabled;
  bool _nvVsrEnabled = true;

  /// 开关落盘回调（由宿主接 Hive；不注入 = 不持久化，只在本次会话有效）。
  void Function(bool enabled)? onNvVsrChanged;

  /// 用存下来的值初始化（不触发落盘/下发）。
  void seedNvVsrEnabled(bool enabled) => _nvVsrEnabled = enabled;

  /// 开/关 VSR：改内存值 → 落盘 → 立刻下发（用户点右键菜单时）。
  Future<void> setNvVsrEnabled(bool enabled) async {
    if (!nvVsrAvailable) return;
    _nvVsrEnabled = enabled;
    onNvVsrChanged?.call(enabled);
    await applyNvVsr();
  }

  /// 按当前开关状态把 `vf` 链下发一次（开播后 / 用户切换后都走这里）。
  ///
  /// 判定依据都写进 `[debug-vf]` 日志：`mpv-version`（dll 是不是带 NVIDIA 模式的构建）、
  /// `vf-now`（滤镜到底在不在链上）、`hwdec-current`、以及滤镜之后的输出尺寸。
  Future<void> applyNvVsr() async {
    final String spec = nvVsrSpec;
    if (spec.isEmpty || _nvVsrUnsupported) return;
    final bool on = _nvVsrEnabled;
    final int code = await runMpvCommand(nvVsrVfCommand(spec, enabled: on));
    // ⚠️ 只看 `set` 的返回码不够：media_kit 的 command() 不把 mpv 的「命令失败」
    // 当成异常，`set=0` 也可能是假的。回读 `vf` 才知道这条滤镜到底在不在链上。
    final String vfNow = await readMpvProperty('vf');
    final String version = await readMpvProperty('mpv-version');
    final String context = await readMpvProperty('current-gpu-context');
    final String hwdec = await readMpvProperty('hwdec-current');
    final String pixelFormat = await readMpvProperty('video-params/pixelformat');
    final String width = await readMpvProperty('video-params/w');
    final String height = await readMpvProperty('video-params/h');
    diag.info(
      'debug-vf',
      'enabled=$on vf="$spec" set=$code vf-now="$vfNow" mpv-version="$version" '
      'gpu-context="$context" hwdec="$hwdec" pixelformat="$pixelFormat" size=${width}x$height',
    );
    // 开着却没进链 = 这份 libmpv 不认这条滤镜（老版本）。关掉它是预期行为，不算失败。
    if (on && !vfNow.contains('d3d11vpp')) {
      _nvVsrUnsupported = true;
      diag.warn(
        'debug-vf',
        '本机的 libmpv 不接受 NV-VSR 滤镜（vf-now="$vfNow"，mpv-version="$version"）：'
        '右键菜单会隐藏这一项；要让 VSR 生效，需要随程序带带 NVIDIA 模式的 libmpv。',
      );
    }
    // 滤镜之后/渲染目标的分辨率：判断「VSR 到底有没有把帧放大」的唯一硬证据。
    // `video-params` 是解码尺寸（filter 之前），`video-out-params` 才是 vf 链输出。
    if (on) unawaited(_logNvVsrAfterReconfigure());
  }

  /// 等 VO 重新配置后补记一次「滤镜之后的尺寸」。
  ///
  /// 为什么要延迟：`set vf` 之后 mpv 要等下一帧才重建滤镜链与输出参数，紧接着读
  /// 拿到的还是旧值。400ms 足够一次 VO reconfig，又不会明显拖慢开播（不 await）。
  Future<void> _logNvVsrAfterReconfigure() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final String outW = await readMpvProperty('video-out-params/w');
    final String outH = await readMpvProperty('video-out-params/h');
    final String osdW = await readMpvProperty('osd-dimensions/w');
    final String osdH = await readMpvProperty('osd-dimensions/h');
    final String vfNow = await readMpvProperty('vf');
    diag.info(
      'debug-vf',
      'after-reconfig vf-now="$vfNow" out-params=${outW}x$outH osd=${osdW}x$osdH',
    );
  }

  // ── 音效（audio-pack 扩展包）────────────────────────────────────────────────
  //
  // 与 NV-VSR 同一套口径：包只给**有界数值**，链在这里拼（`audioFxActiveSpec`），
  // 下发后回读 `af`。探针实测（2026-10-19）：`set af` 对写错的滤镜**也返回成功**，
  // 真正的失败在滤镜初始化（`Audio filter initialized failed`，等于完全没声音），
  // 所以那条日志由 bootstrap 转给 [disableAudioFxOnFailure] 兜底回退原声。

  List<AudioFxPreset> _audioPresets = const <AudioFxPreset>[];
  List<AudioFxPreset> get audioPresets => _audioPresets;

  AudioFxState _audioFxState = const AudioFxState();
  AudioFxState get audioFxState => _audioFxState;

  /// 有包才有这一项（右键菜单据此不显示）。
  bool get audioFxAvailable => _audioPresets.isNotEmpty;

  /// 当前生效的档（没选/包被卸 = null）。
  AudioFxPreset? get audioFxPreset {
    for (final AudioFxPreset preset in _audioPresets) {
      if (preset.id == _audioFxState.presetId) return preset;
    }
    return null;
  }

  /// 状态落盘回调（由宿主接 KV；不注入 = 不持久化，只在本次会话有效）。
  void Function(AudioFxState state)? onAudioFxChanged;

  /// 宿主扫到包之后灌进来（播放面每次 build 都会调；清单没变则直接返回）。
  void seedAudioFxPresets(List<AudioFxPreset> presets) {
    if (_samePresetIds(presets, _audioPresets)) return;
    _audioPresets = List<AudioFxPreset>.unmodifiable(presets);
    // 包被卸了：档位跟着失效，不静默继续用旧链（右键菜单也会整项消失）。
    if (_audioFxState.presetId != null && audioFxPreset == null) {
      _audioFxState = _audioFxState.copyWith(enabled: false, clearPreset: true);
      onAudioFxChanged?.call(_audioFxState);
      unawaited(applyAudioFx());
      return;
    }
    if (_audioFxState.enabled) unawaited(applyAudioFx());
  }

  /// 用存下来的状态初始化（不触发落盘/下发）。
  void seedAudioFxState(AudioFxState state) => _audioFxState = state;

  /// 开/关音效总开关；没有选档时开 = 用第一档。
  Future<void> setAudioFxEnabled(bool enabled) async {
    if (!audioFxAvailable) return;
    if (enabled && _audioFxState.presetId == null) {
      _audioFxState =
          _audioFxState.copyWith(enabled: true, presetId: _audioPresets.first.id);
    } else {
      _audioFxState = _audioFxState.copyWith(enabled: enabled);
    }
    _persistAudioFx();
    await applyAudioFx();
  }

  /// 选一档（`null` = 回原声，等同关总开关）。
  Future<void> setAudioFxPresetId(String? id) async {
    _audioFxState = id == null
        ? _audioFxState.copyWith(enabled: false, clearPreset: true)
        : _audioFxState.copyWith(enabled: true, presetId: id);
    _persistAudioFx();
    await applyAudioFx();
  }

  Future<void> setAudioFxCompression(int level) async {
    _audioFxState = _audioFxState.copyWith(compression: level.clamp(0, 3));
    _persistAudioFx();
    if (_audioFxState.enabled) await applyAudioFx();
  }

  Future<void> setAudioFxLoudness(int level) async {
    _audioFxState = _audioFxState.copyWith(loudness: level.clamp(0, 3));
    _persistAudioFx();
    if (_audioFxState.enabled) await applyAudioFx();
  }

  /// 按当前状态把 `af` 链下发一次（开播后 / 用户切档后都走这里）。
  Future<void> applyAudioFx() async {
    final String spec =
        audioFxActiveSpec(presets: _audioPresets, state: _audioFxState);
    final int code = await runMpvCommand(audioFxFiltersCommand(spec));
    // 回读：只能证明「设上了」，不能证明初始化成功（见本段开头的探针结论）。
    final String afNow = await readMpvProperty('af');
    diag.info(
      'debug-af',
      'enabled=${_audioFxState.enabled} preset=${_audioFxState.presetId} '
      'compression=${_audioFxState.compression} loudness=${_audioFxState.loudness} '
      'set=$code af-now="$afNow"',
    );
    if (spec.isNotEmpty && !afNow.contains('lavfi')) {
      await disableAudioFxOnFailure('af 回读里没有 lavfi（af-now="$afNow"）');
    }
  }

  /// 链初始化失败：关掉音效、清空 `af`、落盘，并留一行原因（绝不静默）。
  Future<void> disableAudioFxOnFailure(String reason) async {
    if (!_audioFxState.enabled) return;
    _audioFxState = _audioFxState.copyWith(enabled: false);
    _persistAudioFx();
    diag.warn('audio-fx', '音效链初始化失败，已回退原声：$reason');
    await runMpvCommand(audioFxFiltersCommand(''));
  }

  void _persistAudioFx() => onAudioFxChanged?.call(_audioFxState);

  bool _samePresetIds(List<AudioFxPreset> a, List<AudioFxPreset> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
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

/// 等「这一次」的媒体真的加载起来：`duration` 第一次大于 0 就算到了。
///
/// 为什么单拎出来：它守的是「续播 seek 太早被 mpv 丢掉」这条（[PlayerController.open]
/// 的注释里有真机日志证据），而 `Player.stream.duration` 是 broadcast、没有重放，
/// 只能**在 open 之前**订阅 —— 这层顺序在真实播放器上没法在单测里复现，
/// 所以把判据做成纯函数，用一条可控的流来钉（`test/controllers/media_ready_test.dart`）。
///
/// 返回 false = 超时（直播没有时长 / 这个文件一直没载起来）。调用方**仍然**应该
/// 试一次 seek：seek 失败最多是"从 0 开始"，不该把开播本身拖成失败。
Future<bool> waitUntilMediaReady(
  Stream<Duration> durations, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  try {
    await durations.firstWhere((Duration d) => d > Duration.zero).timeout(timeout);
    return true;
  } catch (_) {
    return false;
  }
}
