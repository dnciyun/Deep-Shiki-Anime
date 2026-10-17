/// 第五十三轮「默认只按主题色」的守卫（用户 2026-10-18「默认还是按主题的色不要加其他颜色」）。
///
/// 第五十二轮的 12 色相层保留为**语义标识**（页面 / 源 / 标签 / 星期的映射表不漂移），
/// 但取色一律落回本套外观的主题强调色。这个文件钉三件事：
/// 1. 12 个色相在 8 套外观里取到的颜色**完全相同**（不会偷偷加回彩色）；
/// 2. 主题强调色的文字档 [DsTokens.accentInk] 在 3 个承载面、3 个 12% 淡底与
///    页面洗色顶上都 ≥4.5:1（页面里所有彩色文字都取它）；
/// 3. 色条 / 色块 / 洗色这些**结构**仍然存在（淡底不是底色、洗色落回 base、描边半透明）。
library;

import 'package:dsanima/state/providers.dart' show ShellTab;
import 'package:dsanima/theme/tokens.dart';
import 'package:dsanima/ui/widgets/hues.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('色相不再决定颜色：8 套外观 × 12 色相取到的全是主题强调色', () {
    for (final DsAppearance a in DsAppearance.values) {
      final DsTokens t = a.tokens;
      for (final DsHue h in DsHue.values) {
        expect(t.hueInk(h), t.accentInk, reason: '${a.code}/${h.name} 的文字色');
        expect(t.hueFill(h), t.accent, reason: '${a.code}/${h.name} 的填充色');
        expect(t.hueSoft(h), t.accentSoftOn(t.raised), reason: '${a.code}/${h.name} 的淡底');
        expect(t.hueSoftOn(h, t.base), t.accentSoftOn(t.base));
        expect(t.hueOnFill(h), t.onAccent, reason: '${a.code}/${h.name} 的实底前景');
        expect(
          t.hueLine(h),
          t.accent.withValues(alpha: t.isDark ? 0.55 : 0.45),
          reason: '${a.code}/${h.name} 的 1px 描边',
        );
        expect(t.hueWash(h).colors, t.accentWash.colors, reason: '${a.code}/${h.name} 的洗色');
      }
    }
  });

  test('强调色文字档：8 套外观 × 7 面全部 ≥4.5:1', () {
    final List<String> bad = <String>[];
    for (final DsAppearance a in DsAppearance.values) {
      final DsTokens t = a.tokens;
      for (final (String faceName, Color face) in <(String, Color)>[
        ('base', t.base),
        ('raised', t.raised),
        ('sunken', t.sunken),
        ('soft-base', t.accentSoftOn(t.base)),
        ('soft-raised', t.accentSoftOn(t.raised)),
        ('soft-sunken', t.accentSoftOn(t.sunken)),
        ('wash', t.accentWashTop),
      ]) {
        final double ratio = dsContrastRatio(t.accentInk, face);
        if (ratio < 4.5) {
          bad.add('${a.code}/accentInk-on-$faceName = ${ratio.toStringAsFixed(2)}');
        }
      }
    }
    expect(bad, isEmpty);
  });

  test('强调色文字档仍是「主题色的文字版」：朝正文色压暗，不是另一种颜色', () {
    for (final DsAppearance a in DsAppearance.values) {
      final DsTokens t = a.tokens;
      final double accentL = dsRelativeLuminance(t.accent);
      final double inkL = dsRelativeLuminance(t.accentInk);
      final double textL = dsRelativeLuminance(t.text);
      // accentInk 落在 accent 与 text 之间（浅色系更暗，深色系 accent 本身够亮、
      // 与 accent 相等）。
      final double lo = textL < accentL ? textL : accentL;
      final double hi = textL < accentL ? accentL : textL;
      expect(inkL, greaterThanOrEqualTo(lo - 1e-9), reason: '${a.code} accentInk 跑出 accent..text');
      expect(inkL, lessThanOrEqualTo(hi + 1e-9), reason: '${a.code} accentInk 跑出 accent..text');
    }
  });

  test('色条 / 色块 / 洗色结构还在（只是同色）', () {
    for (final DsTokens t in <DsTokens>[DsTokens.whiteOrange, DsTokens.blackMono]) {
      expect(t.hueSoft(DsHue.orange), isNot(t.base), reason: '淡底不能和页面底色一样');
      expect(t.hueSoft(DsHue.orange), isNot(t.raised), reason: '淡底不能和凸起面一样');
      final LinearGradient wash = t.hueWash(DsHue.violet);
      expect(wash.colors.last, t.base, reason: '洗色必须落回页面底色');
      expect(wash.colors.first, isNot(t.base), reason: '洗色顶部必须带色');
      final Color line = t.hueLine(DsHue.cyan);
      expect(line.a, greaterThan(0));
      expect(line.a, lessThan(1));
      // 实底上的小图标（主按钮 / 选中色块）≥3:1（WCAG 1.4.11）。
      final double iconRatio = dsContrastRatio(t.hueOnFill(DsHue.blue), t.hueFill(DsHue.blue));
      expect(iconRatio, greaterThanOrEqualTo(3.0));
    }
  });

  test('标识映射仍然稳定（页面 / 源 / 标签 / 星期不漂移）', () {
    final Set<DsHue> tabs = <DsHue>{
      for (final ShellTab tab in ShellTab.values) hueOfTab(tab),
    };
    expect(tabs, hasLength(ShellTab.values.length), reason: '每个目的地必须有自己的标识');
    expect(hueOfTab(ShellTab.home), DsHue.orange);
    expect(hueOfSource('dmhy'), hueOfSource('dmhy-batch'));
    expect(hueOfSource('mikan'), DsHue.orange);
    expect(hueOfSource(null), DsHue.slate);
    expect(hueOfTag('奇幻'), DsHue.violet);
    expect(hueOfTag('某个没收录的标签'), hueOfTag('某个没收录的标签'));
    expect(<DsHue>{for (int i = 0; i < 7; i++) hueOfWeekday(i)}, hasLength(7));
    expect(hueOfWeekday(7), hueOfWeekday(0), reason: '越界必须绕回');
  });
}
