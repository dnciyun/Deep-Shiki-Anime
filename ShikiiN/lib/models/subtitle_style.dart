// ignore_for_file: prefer_initializing_formals
import 'package:flutter/foundation.dart';

double _clampScale(num v) => v.toDouble().clamp(0.1, 10.0);
int _clampPos(num v) => v.clamp(0, 150).round();
double _clampNonNeg(num v) => v.toDouble().clamp(0.0, 20.0);

@immutable
class SubtitleStyle {
  final String font;
  final bool bold;
  final bool italic;
  final double _scale;
  final int _pos;
  final String color;
  final String borderColor;
  final double _borderSize;
  final String shadowColor;
  final double _shadowOffset;
  final String? backColor;
  final bool overrideAss;

  const SubtitleStyle({
    this.font = '',
    this.bold = false,
    this.italic = false,
    double scale = 1.0,
    int pos = 100,
    this.color = '#FFFFFFFF',
    this.borderColor = '#FF000000',
    double borderSize = 3.0,
    this.shadowColor = '#FF000000',
    double shadowOffset = 0.0,
    this.backColor,
    this.overrideAss = true, // 默认覆盖，否则 ASS/SSA 字幕忽略自定义样式
  })  : _scale = scale,
        _pos = pos,
        _borderSize = borderSize,
        _shadowOffset = shadowOffset;

  double get scale => _clampScale(_scale);
  int get pos => _clampPos(_pos);
  double get borderSize => _clampNonNeg(_borderSize);
  double get shadowOffset => _clampNonNeg(_shadowOffset);

  Map<String, String> toMpvProperties() => {
        if (font.isNotEmpty) 'sub-font': font,
        'sub-bold': bold ? 'yes' : 'no',
        'sub-italic': italic ? 'yes' : 'no',
        'sub-scale': scale.toStringAsFixed(1),
        'sub-pos': pos.toString(),
        'sub-color': color,
        'sub-border-color': borderColor,
        'sub-border-size': borderSize.toStringAsFixed(1),
        'sub-shadow-color': shadowColor,
        'sub-shadow-offset': shadowOffset.toStringAsFixed(1),
        'sub-back-color': backColor ?? '#00000000',
        'sub-ass-override': overrideAss ? 'force' : 'no',
      };

  SubtitleStyle copyWith({
    String? font,
    bool? bold,
    bool? italic,
    double? scale,
    int? pos,
    String? color,
    String? borderColor,
    double? borderSize,
    String? shadowColor,
    double? shadowOffset,
    Object? backColor = _noChange,
    bool? overrideAss,
  }) =>
      SubtitleStyle(
        font: font ?? this.font,
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        scale: scale ?? _scale,
        pos: pos ?? _pos,
        color: color ?? this.color,
        borderColor: borderColor ?? this.borderColor,
        borderSize: borderSize ?? _borderSize,
        shadowColor: shadowColor ?? this.shadowColor,
        shadowOffset: shadowOffset ?? _shadowOffset,
        backColor: backColor == _noChange ? this.backColor : backColor as String?,
        overrideAss: overrideAss ?? this.overrideAss,
      );

  Map<String, Object?> toMap() => {
        'font': font,
        'bold': bold,
        'italic': italic,
        'scale': _scale,
        'pos': _pos,
        'color': color,
        'borderColor': borderColor,
        'borderSize': _borderSize,
        'shadowColor': shadowColor,
        'shadowOffset': _shadowOffset,
        'backColor': backColor,
        'overrideAss': overrideAss,
      };

  factory SubtitleStyle.fromMap(Map? m) => SubtitleStyle(
        font: (m?['font'] as String?) ?? '',
        bold: (m?['bold'] as bool?) ?? false,
        italic: (m?['italic'] as bool?) ?? false,
        scale: (m?['scale'] as num?)?.toDouble() ?? 1.0,
        pos: (m?['pos'] as num?)?.toInt() ?? 100,
        color: (m?['color'] as String?) ?? '#FFFFFFFF',
        borderColor: (m?['borderColor'] as String?) ?? '#FF000000',
        borderSize: (m?['borderSize'] as num?)?.toDouble() ?? 3.0,
        shadowColor: (m?['shadowColor'] as String?) ?? '#FF000000',
        shadowOffset: (m?['shadowOffset'] as num?)?.toDouble() ?? 0.0,
        backColor: m?['backColor'] as String?,
        overrideAss: (m?['overrideAss'] as bool?) ?? true,
      );

  static const _noChange = Object();
}
