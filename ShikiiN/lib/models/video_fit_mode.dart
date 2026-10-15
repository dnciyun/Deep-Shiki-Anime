/// 画面适配模式 → mpv 属性。切换前应把上一模式属性复位再套新模式，避免 panscan 残留。
enum VideoFitMode {
  keepAspect,
  cover,
  stretch;

  Map<String, String> toMpvProperties() => switch (this) {
        VideoFitMode.keepAspect => {'keepaspect': 'yes', 'panscan': '0.0'},
        VideoFitMode.cover => {'keepaspect': 'yes', 'panscan': '1.0'},
        VideoFitMode.stretch => {'keepaspect': 'no', 'panscan': '0.0'},
      };

  String get label => switch (this) {
        VideoFitMode.keepAspect => '保持比例',
        VideoFitMode.cover => '填充裁切',
        VideoFitMode.stretch => '拉伸',
      };
}
