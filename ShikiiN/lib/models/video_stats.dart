/// 视频数据浮层的一帧快照（已格式化为显示字符串，缺项为 '—'）。
class VideoStats {
  final String fps; // 输出帧率（解码/滤镜链输出，estimated-vf-fps；不反映 GPU 着色器负载）
  final String renderedFps; // 实际帧率（输出帧率扣掉丢帧率，由调用方按时间窗算出）
  final String sourceFps; // 源（容器）帧率
  final String displayFps; // 显示器刷新率
  final String resolution;
  final String videoBitrate;
  final String droppedFrames;
  final String videoCodec;
  final String pixelFormat;
  final String hwdec;
  final String avSync; // 音画同步偏差
  final String speed; // 播放速度
  final String audioCodec;
  final String audioBitrate;
  final String sampleRate;
  final String audioChannels;

  const VideoStats({
    required this.fps,
    required this.renderedFps,
    required this.sourceFps,
    required this.displayFps,
    required this.resolution,
    required this.videoBitrate,
    required this.droppedFrames,
    required this.videoCodec,
    required this.pixelFormat,
    required this.hwdec,
    required this.avSync,
    required this.speed,
    required this.audioCodec,
    required this.audioBitrate,
    required this.sampleRate,
    required this.audioChannels,
  });

  static const String _ph = '—';

  static String _s(String? v) => (v == null || v.trim().isEmpty) ? _ph : v.trim();

  static String _res(String? w, String? h) {
    final ws = w?.trim(), hs = h?.trim();
    if (ws == null || ws.isEmpty || hs == null || hs.isEmpty) return _ph;
    return '$ws×$hs';
  }

  /// 帧率类：圆整到 2 位小数（如 23.976023 → 23.98）。
  static String _fps(String? v) {
    final d = double.tryParse(v?.trim() ?? '');
    if (d == null || d <= 0) return _ph;
    return d.toStringAsFixed(2);
  }

  static String _bitrateMbps(String? bps) {
    final v = double.tryParse(bps?.trim() ?? '');
    if (v == null || v <= 0) return _ph;
    return '${(v / 1e6).toStringAsFixed(1)} Mbps';
  }

  static String _bitrateKbps(String? bps) {
    final v = double.tryParse(bps?.trim() ?? '');
    if (v == null || v <= 0) return _ph;
    return '${(v / 1000).toStringAsFixed(0)} kbps';
  }

  /// 音画同步：秒 → 毫秒整数（可正可负）。
  static String _avsync(String? v) {
    final d = double.tryParse(v?.trim() ?? '');
    if (d == null) return _ph;
    return '${(d * 1000).round()} ms';
  }

  static String _speed(String? v) {
    final d = double.tryParse(v?.trim() ?? '');
    if (d == null || d <= 0) return _ph;
    return '${d.toStringAsFixed(2)}x';
  }

  static String _khz(String? hz) {
    final v = double.tryParse(hz?.trim() ?? '');
    if (v == null || v <= 0) return _ph;
    return '${(v / 1000).toStringAsFixed(1)} kHz';
  }

  /// 从 mpv 属性名→值的 map 构造（值可能为 null/空，统一回退占位）。
  /// [renderedFps] 是「实际帧率」——需跨两次采样按丢帧率算，由调用方传入。
  factory VideoStats.fromProps(Map<String, String?> p, {String renderedFps = _ph}) => VideoStats(
        fps: _fps(p['estimated-vf-fps']),
        renderedFps: renderedFps,
        sourceFps: _fps(p['container-fps']),
        displayFps: _fps(p['display-fps']),
        resolution: _res(p['width'], p['height']),
        videoBitrate: _bitrateMbps(p['video-bitrate']),
        droppedFrames: _s(p['frame-drop-count']),
        videoCodec: _s(p['video-codec']),
        pixelFormat: _s(p['video-params/pixelformat']),
        hwdec: _s(p['hwdec-current']),
        avSync: _avsync(p['avsync']),
        speed: _speed(p['speed']),
        audioCodec: _s(p['audio-codec-name']),
        audioBitrate: _bitrateKbps(p['audio-bitrate']),
        sampleRate: _khz(p['audio-params/samplerate']),
        audioChannels: _s(p['audio-params/channels']),
      );

  /// 浮层按 (标签, 值) 顺序渲染。
  List<(String, String)> get rows => [
        ('源帧率', sourceFps),
        ('输出帧率', fps),
        ('实际帧率', renderedFps),
        ('显示刷新', displayFps),
        ('音画同步', avSync),
        ('播放速度', speed),
        ('分辨率', resolution),
        ('视频码率', videoBitrate),
        ('丢帧', droppedFrames),
        ('视频编码', videoCodec),
        ('像素格式', pixelFormat),
        ('硬解', hwdec),
        ('音频编码', audioCodec),
        ('音频码率', audioBitrate),
        ('采样率', sampleRate),
        ('声道', audioChannels),
      ];
}
