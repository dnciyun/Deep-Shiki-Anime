/// 第五十二轮「整项目色彩系统」的单元测试（守卫新增的 [DsHue] 层）。
///
/// 规范：`docs/specs/2026-10-17-dsanima-color.md`。
///
/// 为什么单独一个文件：颜色对比度那条已经在 `widget_test.dart` 的
/// `dsContrastPairs()` 里统一守（第五十二轮把它扩到 8 套 × 12 色相 × 2 面）；
/// 这里只钉**色相语义本身**：12 色齐全、深浅两档都可用、淡底/洗色/实底前景
/// 三者自洽，以及「页面 / 源 / 标签 / 星期」的固定映射不漂移。
library;

import 'package:dsanima/state/providers.dart' show ShellTab;
import 'package:dsanima/theme/tokens.dart';
import 'package:dsanima/ui/widgets/hues.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('12 个标识色相齐全，且深浅两档外观的 ink / fill 都不相同', () {
    expect(DsHue.values, hasLength(12));
    final Set<Color> lightInks = <Color>{
      for (final DsHue h in DsHue.values) DsTokens.whiteOrange.hueInk(h),
    };
    final Set<Color> lightFills = <Color>{
      for (final DsHue h in DsHue.values) DsTokens.whiteOrange.hueFill(h),
    };
    final Set<Color> darkInks = <Color>{
      for (final DsHue h in DsHue.values) DsTokens.blackMono.hueInk(h),
    };
    expect(lightInks, hasLength(12), reason: '12 个色相的 ink 必须是 12 个不同颜色');
    expect(lightFills, hasLength(12), reason: '12 个色相的 fill 必须是 12 个不同颜色');
    expect(darkInks, hasLength(12), reason: '深色外观也必须是 12 个不同颜色');
  });

  test('淡底 / 洗色 / 描边都从 fill 派生，且洗色终点就是 base', () {
    const DsTokens t = DsTokens.whiteOrange;
    for (final DsHue h in DsHue.values) {
      // 淡底：比 base 更深（叠了颜色），但绝不是 fill 本身。
      expect(t.hueSoft(h), isNot(t.hueFill(h)), reason: '${h.name} 淡底不能是实色');
      expect(t.hueSoft(h), isNot(t.base), reason: '${h.name} 淡底不能和 base 一样');
      // 页面洗色：从 tinted base 渐变回 base（外壳铺在内容区背后）。
      final LinearGradient wash = t.hueWash(h);
      expect(wash.colors.last, t.base, reason: '${h.name} 洗色必须落回页面底色');
      expect(wash.colors.first, isNot(t.base), reason: '${h.name} 洗色顶部必须带色');
      // 1px 彩色描边：不是全透明，也不是实色（悬停用，克制）。
      final Color line = t.hueLine(h);
      expect(line.a, greaterThan(0));
      expect(line.a, lessThan(1));
    }
  });

  test('实底前景色（色块里的图标）在 12 个色相上都 ≥3:1', () {
    for (final DsTokens t in <DsTokens>[DsTokens.whiteOrange, DsTokens.blackMono]) {
      for (final DsHue h in DsHue.values) {
        final double ratio = dsContrastRatio(t.hueOnFill(h), t.hueFill(h));
        expect(ratio, greaterThanOrEqualTo(3.0),
            reason: '${t.isDark ? 'dark' : 'light'}/${h.name} 实底图标对比度只有 '
                '${ratio.toStringAsFixed(2)}:1');
      }
    }
  });

  test('页面色相：8 个目的地各不相同（侧栏一眼按颜色认页）', () {
    final Set<DsHue> hues = <DsHue>{
      for (final ShellTab tab in ShellTab.values) hueOfTab(tab),
    };
    expect(hues, hasLength(ShellTab.values.length), reason: '每个目的地必须有自己的颜色');
    expect(hueOfTab(ShellTab.home), DsHue.orange);
    expect(hueOfTab(ShellTab.queue), DsHue.blue);
    expect(hueOfTab(ShellTab.settings), DsHue.slate);
  });

  test('种子源色相：按前缀归组（dmhy 与 dmhy-batch 同色、未知源回落灰）', () {
    expect(hueOfSource('dmhy'), hueOfSource('dmhy-batch'));
    expect(hueOfSource('mikan'), isNot(hueOfSource('dmhy')));
    expect(hueOfSource('mikan'), DsHue.orange);
    expect(hueOfSource(null), DsHue.slate);
    expect(hueOfSource('没见过的源'), DsHue.slate);
  });

  test('标签色相：收录词固定、未收录词稳定（同一标签每次同色）', () {
    expect(hueOfTag('奇幻'), DsHue.violet);
    expect(hueOfTag('恋爱'), DsHue.pink);
    expect(hueOfTag('机战'), DsHue.blue);
    final DsHue first = hueOfTag('某个没收录的标签');
    expect(hueOfTag('某个没收录的标签'), first, reason: '同一标签必须稳定同色');
    expect(DsHue.values, contains(hueOfTag('某个没收录的标签')));
  });

  test('星期色环：周一到周日 7 个不同色相，循环取模不出界', () {
    final Set<DsHue> ring = <DsHue>{for (int i = 0; i < 7; i++) hueOfWeekday(i)};
    expect(ring, hasLength(7));
    expect(hueOfWeekday(7), hueOfWeekday(0), reason: '越界必须绕回（防负下标/越界）');
  });
}
