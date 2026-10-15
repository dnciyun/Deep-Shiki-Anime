/// 8 套外观 / 扁平几何 / 阴影语义 / 几何枚举的 token 层测试。
///
/// 规范（绑定权威）：`docs/specs/2026-10-14-dsanima-flat-theme.md`
/// §3（形状与密度）、§3.1–§3.3（封面比例 / 封面大小 / 轮播几何）、
/// §5（八套外观）、§7（悬浮层）、§12.1（测试期望）。
library;

import 'package:dsanima/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('8 套外观：code 往返 + 中文名 + 分组 + 明暗齐全', () {
    expect(DsAppearance.values, hasLength(8));
    for (final DsAppearance a in DsAppearance.values) {
      expect(DsAppearance.fromCode(a.code), a);
      expect(a.label, isNotEmpty);
      expect(a.tokens.accent, isNot(a.tokens.raised));
    }
    expect(DsAppearance.wOrange.family, DsAppearanceFamily.white);
    expect(DsAppearance.bNeon.family, DsAppearanceFamily.black);
    expect(DsAppearance.wInk.isDark, isFalse);
    expect(DsAppearance.bMono.isDark, isTrue);
  });

  test('旧值迁移：light→白黑、dark→黑白、A/C/B/空/乱码→白黑', () {
    expect(DsAppearance.fromCode('light'), DsAppearance.wInk);
    expect(DsAppearance.fromCode('dark'), DsAppearance.bMono);
    for (final String? old in <String?>['A', 'C', 'B', '', '乱码', null]) {
      expect(DsAppearance.fromCode(old), DsAppearance.wInk);
    }
  });

  test('色表逐字对照 spec §5.2（抽样 4 套 × base/line/accent/onAccent）', () {
    expect(DsTokens.whiteOrange.base, const Color(0xFFFBF8F5));
    expect(DsTokens.whiteOrange.accent, const Color(0xFFC2410C));
    expect(DsTokens.blackNeon.sunken, const Color(0xFF161C1A));
    expect(DsTokens.blackNeon.onAccent, const Color(0xFF04120B));
    expect(DsTokens.blackRed.line, const Color(0xFF2A2124));
    expect(DsTokens.blackMono.accent, const Color(0xFFFFFFFF));
  });

  test('扁平几何：12/8/999/6、控件高 40、工具条 44', () {
    const DsTokens t = DsTokens.whiteInk;
    expect(t.radiusCard, 12);
    expect(t.radiusControl, 8);
    expect(t.radiusPill, 999);
    expect(t.radiusBadge, 6);
    expect(t.controlHeight, 40);
    expect(t.barHeight, 44);
  });

  test('装饰：卡片 = raised + 1px line 且零阴影；凹槽 = sunken + 1px line', () {
    const DsTokens t = DsTokens.whiteInk;
    final BoxDecoration card = t.cardDecoration();
    expect(card.color, t.raised);
    expect(card.boxShadow ?? const <BoxShadow>[], isEmpty);
    expect((card.border! as Border).top.color, t.line);
    expect((card.border! as Border).top.width, 1);
    expect(t.inset().color, t.sunken);
  });

  test('阴影只剩 high 一档（枚举里也没有别的档位了）', () {
    const DsTokens t = DsTokens.whiteInk;
    expect(NeoShadowLevel.values, <NeoShadowLevel>[NeoShadowLevel.high]);
    expect(t.shadows(NeoShadowLevel.high), isNotEmpty);
    // 列表安全档仍然把模糊压到 ≤2px（决策 A31 的性能红线，保留在 high 上）。
    expect(
      t.shadows(NeoShadowLevel.high, listSafe: true).first.blurRadius,
      lessThanOrEqualTo(2),
    );
  });

  test('对比度：8 套 × 3 面全部 ≥4.5:1，且 onAccent/accent 达标', () {
    final List<({String name, Color fg, Color bg})> pairs = dsContrastPairs();
    expect(pairs, hasLength(8 * 3 * 4 + 8 + 8 * 3));
    final List<String> bad = <String>[
      for (final ({String name, Color fg, Color bg}) p in pairs)
        if (dsContrastRatio(p.fg, p.bg) < 4.5) '${p.name} = ${dsContrastRatio(p.fg, p.bg).toStringAsFixed(2)}',
    ];
    expect(bad, isEmpty);
  });

  test('封面/轮播几何枚举：往返 + 非法值回落 + 档位表（第三十二轮上移一档）', () {
    expect(DsCoverSize.fromCode('l').maxWidth, 250);
    expect(DsCoverSize.fromCode('乱码'), DsCoverSize.m);
    expect(DsCarouselShape.fromCode(null), DsCarouselShape.landscape);
    expect(DsCarouselSize.fromCode('x'), DsCarouselSize.m);
    // 档位系数：小 0.85 / 中 1.2（默认）/ 大 1.5 —— 第三十二轮「把轮播的大改成中，新增更大的」。
    expect(DsCarouselSize.fromCode(null).k, 1.2, reason: '默认档 = 中 = 1.2');
    expect(DsCarouselSize.fromCode('s').k, 0.85);
    expect(DsCarouselSize.fromCode('m').k, 1.2, reason: '中 = 1.2 = 第三十二轮之前的「大」');
    expect(DsCarouselSize.fromCode('l').k, 1.5, reason: '大 = 1.5 = 本轮新增的更大档');
    expect(DsCarouselSize.m.label, '中');
    expect(DsCarouselSize.l.label, '大');

    DsCarouselGeometry g(DsCarouselShape shape, DsCarouselSize size) =>
        DsCarouselGeometry.forShape(shape, size);
    const DsCarouselShape w = DsCarouselShape.landscape;
    const DsCarouselShape p = DsCarouselShape.portrait;
    // 表格 = 规范 §3.3：主卡 / 邻卡 / 整块高度（6 组，逐格钉住）。
    expect(g(w, DsCarouselSize.s).main, const Size(391, 255));
    expect(g(w, DsCarouselSize.s).neighbour, const Size(187, 201));
    expect(g(w, DsCarouselSize.s).blockHeight, 319);
    expect(g(w, DsCarouselSize.m).main, const Size(552, 360));
    expect(g(w, DsCarouselSize.m).neighbour, const Size(264, 283));
    expect(g(w, DsCarouselSize.m).blockHeight, 428);
    expect(g(w, DsCarouselSize.l).main, const Size(690, 450));
    expect(g(w, DsCarouselSize.l).neighbour, const Size(330, 354));
    expect(g(w, DsCarouselSize.l).blockHeight, 522);
    expect(g(p, DsCarouselSize.s).main, const Size(265, 377));
    expect(g(p, DsCarouselSize.s).neighbour, const Size(189, 268));
    expect(g(p, DsCarouselSize.s).blockHeight, 441);
    expect(g(p, DsCarouselSize.m).main, const Size(374, 532));
    expect(g(p, DsCarouselSize.m).neighbour, const Size(266, 378));
    expect(g(p, DsCarouselSize.m).blockHeight, 600);
    expect(g(p, DsCarouselSize.l).main, const Size(468, 665));
    expect(g(p, DsCarouselSize.l).neighbour, const Size(333, 473));
    expect(g(p, DsCarouselSize.l).blockHeight, 737);
  });
}
