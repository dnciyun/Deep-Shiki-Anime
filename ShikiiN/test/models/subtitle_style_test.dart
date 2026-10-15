import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/subtitle_style.dart';

void main() {
  test('默认值与 mpv 属性映射', () {
    const s = SubtitleStyle();
    final m = s.toMpvProperties();
    expect(m['sub-scale'], '1.0');
    expect(m['sub-pos'], '100');
    expect(m['sub-color'], '#FFFFFFFF');
    expect(m['sub-border-color'], '#FF000000');
    expect(m['sub-ass-override'], 'force'); // 默认覆盖，否则 ASS 字幕忽略自定义样式
    expect(m['sub-bold'], 'no');
  });

  test('overrideAss=true → force', () {
    const s = SubtitleStyle(overrideAss: true);
    expect(s.toMpvProperties()['sub-ass-override'], 'force');
  });

  test('字号/位置钳制', () {
    const big = SubtitleStyle(scale: 99, pos: 999);
    expect(big.scale, 10.0);
    expect(big.pos, 150);
    const small = SubtitleStyle(scale: -1, pos: -5);
    expect(small.scale, 0.1);
    expect(small.pos, 0);
  });

  test('copyWith 改字体与粗体', () {
    const s = SubtitleStyle();
    final s2 = s.copyWith(font: '思源黑体', bold: true);
    expect(s2.font, '思源黑体');
    expect(s2.bold, true);
    expect(s2.toMpvProperties()['sub-font'], '思源黑体');
    expect(s2.toMpvProperties()['sub-bold'], 'yes');
  });

  test('toMap/fromMap 往返', () {
    const s = SubtitleStyle(font: 'Arial', scale: 1.5, color: '#FFEEDDCC', overrideAss: true);
    final r = SubtitleStyle.fromMap(s.toMap());
    expect(r.font, 'Arial');
    expect(r.scale, 1.5);
    expect(r.color, '#FFEEDDCC');
    expect(r.overrideAss, true);
  });
}
