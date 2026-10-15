/// 主页轮播 + 「封面大小 / 轮播封面 / 轮播大小」三个设置在主页上的**几何落点**（决策 F14/F23/F24）。
///
/// 与 `home_page_test.dart` 的分工：那边验行为（圆点、文字块、没有「换一批」…），
/// 这边验**尺寸与形状**——真机上肉眼能看出来的那几条。
library;

import 'package:dsanima/domain/bangumi.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/theme/tokens.dart';
import 'package:dsanima/ui/home_page.dart';
import 'package:dsanima/ui/library_detail_page.dart';
import 'package:dsanima/ui/widgets/cover.dart';
import 'package:dsanima/ui/widgets/ds_carousel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'carousel_gestures.dart';
import 'home_page_test.dart' as h;

BangumiSubject _sub(int id, String title) => BangumiSubject(
  id: id,
  name: 'Name $id',
  nameCn: title,
  date: '2014-07-06',
  score: 8.0,
  eps: 12,
  coverUrl: 'https://lain.bgm.tv/r/400/pic/cover/l/x/$id.jpg',
);

h.FakeRecommendPort _five() => h.FakeRecommendPort(<BangumiSubject>[
  for (int i = 1; i <= 5; i++) _sub(i, '推荐番 $i'),
]);

void main() {
  testWidgets('默认（横版·中）：主卡 552×360、轮播块高 428 —— 第三十二轮后「中」= 旧「大」',
      (WidgetTester tester) async {
    h.sizeTo(tester, const Size(1600, 1000));
    await tester.pumpWidget(
      h.harness(const HomePage(), recommend: _five(), carouselAutoPlay: false),
    );
    await tester.pumpAndSettle();

    final Rect block = tester.getRect(find.byType(DsCarousel));
    expect(block.height, 428);
    // 主卡 = 三张里最后画的那张（`_Block` 的 Stack 顺序：左邻卡 → 右邻卡 → 主卡）。
    final List<Rect> cards = <Rect>[
      for (int i = 0; i < 3; i++) tester.getRect(find.descendant(of: find.byType(DsCarousel), matching: find.byType(DsCover)).at(i)),
    ];
    final Rect main = cards.reduce(
      (Rect a, Rect b) => a.width >= b.width ? a : b,
    );
    expect(main.width, 552, reason: '中档系数 1.2 ⇒ 460×1.2');
    expect(main.height, 360);
  });

  testWidgets('轮播封面 = 竖版 · 轮播大小 = 大：主卡 468×665、整块 737，且没有 BoxFit.contain',
      (WidgetTester tester) async {
    h.sizeTo(tester, const Size(1600, 1200));
    await tester.pumpWidget(
      h.harness(
        const HomePage(),
        recommend: _five(),
        carouselAutoPlay: false,
        carouselShape: DsCarouselShape.portrait,
        carouselSize: DsCarouselSize.l,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.getRect(find.byType(DsCarousel)).height, 737);
    final Rect main = <Rect>[
      for (int i = 0; i < 3; i++) tester.getRect(find.descendant(of: find.byType(DsCarousel), matching: find.byType(DsCover)).at(i)),
    ].reduce((Rect a, Rect b) => a.width >= b.width ? a : b);
    expect(main.width, 468, reason: '大档系数 1.5 ⇒ 312×1.5');
    expect(main.height, 665);
    // 竖版 = 看完整封面；**禁止**用 contain（会在框里留底色边，规范 §3.3）。
    for (final Image img in tester.widgetList<Image>(find.byType(Image))) {
      expect(img.fit, isNot(BoxFit.contain));
    }
  });

  testWidgets('点半露的邻卡 → 切到那一张，而不是拿番名直接搜索（第三十二轮）',
      (WidgetTester tester) async {
    h.sizeTo(tester, const Size(1600, 1000));
    await tester.pumpWidget(
      h.harness(const HomePage(), recommend: _five(), carouselAutoPlay: false),
    );
    await tester.pumpAndSettle();
    expect(find.text('推荐番 1'), findsOneWidget, reason: '文字块只画当前项');

    await tapCarouselNeighbour(
      tester,
      right: true,
      geometry: DsCarouselGeometry.forShape(
        DsCarouselShape.landscape,
        DsCarouselSize.m,
      ),
    );
    await tester.pumpAndSettle();

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(HomePage)),
    );
    expect(container.read(navProvider), ShellTab.home, reason: '点邻卡不许跳到搜索页');
    expect(container.read(searchProvider).keyword, isNot('推荐番 2'), reason: '也不许把那部番名丢进搜索');
    expect(find.text('推荐番 2'), findsOneWidget, reason: '文字块换成第 2 部 = 真的切过去了');
    expect(find.text('推荐番 1'), findsNothing);
  });

  testWidgets('点主卡本体 → 动漫库详情（第三十三轮的落点；邻卡仍然是切页）',
      (WidgetTester tester) async {
    h.sizeTo(tester, const Size(1600, 1000));
    await tester.pumpWidget(
      h.harness(const HomePage(), recommend: _five(), carouselAutoPlay: false),
    );
    await tester.pumpAndSettle();

    // push 详情页之后主页变成 offstage（Finder 默认跳过 offstage），容器先拿。
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(HomePage)),
    );

    // 主卡 = 三张里最大的那张 DsCover；点它的中心（那里一定没被邻卡压住）。
    final List<Rect> cards = <Rect>[
      for (int i = 0; i < 3; i++) tester.getRect(find.descendant(of: find.byType(DsCarousel), matching: find.byType(DsCover)).at(i)),
    ];
    final Rect main = cards.reduce((Rect a, Rect b) => a.width >= b.width ? a : b);
    await tester.tapAt(main.center);
    await tester.pumpAndSettle();
    // ⚠️ 第三十三轮：主卡不再"直接拿番名去搜种子"，而是打开动漫库详情
    //（用户：「点今日推荐也会跳到这里面」）。邻卡的行为一个字没动（上一条用例钉着）。
    expect(find.byType(LibraryDetailPage), findsOneWidget);
    expect(container.read(navProvider), ShellTab.home, reason: '主卡不再跳搜索页');
    expect(container.read(searchProvider).keyword, isNot('推荐番 1'));
  });

  testWidgets('封面大小三档 → 网格卡宽/列数（决策 F23，内容宽 1096 与 1168）', (WidgetTester tester) async {
    // 纯函数层面的口径（真机宽度怎么算都在这里钉住）。
    expect(homeCardWidthFor(1096, DsCoverSize.s.maxWidth), 172);
    expect(homeCardWidthFor(1096, DsCoverSize.m.maxWidth), 208);
    expect(homeCardWidthFor(1096, DsCoverSize.l.maxWidth), 250);
    expect(homeGridColumns(1096, 172), 5);
    expect(homeGridColumns(1096, 208), 4);
    expect(homeGridColumns(1096, 250), 4);
    // 更宽的窗口：内容宽 1168（= spec §3.2 里的「内宽 1132」，扣掉左右各 18 的 padding）。
    expect(homeGridColumns(1168, 172), 6);
    expect(homeGridColumns(1168, 208), 5);
    expect(homeGridColumns(1168, 250), 4);
    // 不传 cap = 中档（旧调用形式不炸）。
    expect(homeCardWidthFor(1096), homeCardWidthFor(1096, 208));
  });

  testWidgets('设置「封面大小 = 大」真的作用到网格（卡更宽、封面更高）', (WidgetTester tester) async {
    h.sizeTo(tester, const Size(1600, 1200));
    await tester.pumpWidget(
      h.harness(const HomePage(), coverSize: DsCoverSize.l),
    );
    await tester.pumpAndSettle();

    final SliverGridDelegateWithFixedCrossAxisCount delegate =
        (tester.widget<SliverGrid>(find.byType(SliverGrid)).gridDelegate)
            as SliverGridDelegateWithFixedCrossAxisCount;
    final double coverH = delegate.mainAxisExtent! - kHomeCardTextHeight;
    expect(coverH, closeTo(250 / kPosterAspect, 1.0), reason: '大档封面 = 250 ÷ 0.705');
  });

  testWidgets('推荐区头没有分隔线（决策 F16：页面间分隔线改由 24 间距分区）', (WidgetTester tester) async {
    h.sizeTo(tester, const Size(1600, 1000));
    await tester.pumpWidget(
      h.harness(const HomePage(), recommend: _five(), carouselAutoPlay: false),
    );
    await tester.pumpAndSettle();

    // 「今日推荐」标题所在的那棵子树里不许有 bottom border。
    final Iterable<Container> containers = tester.widgetList<Container>(
      find.ancestor(
        of: find.text('今日推荐'),
        matching: find.byType(Container),
      ),
    );
    for (final Container c in containers) {
      final Decoration? d = c.decoration;
      if (d is BoxDecoration && d.border is Border) {
        expect((d.border! as Border).bottom.width, 0);
      }
    }
  });

  testWidgets('封面缺失（灰框）时角标点还在（决策 F17）', (WidgetTester tester) async {
    h.sizeTo(tester, const Size(1400, 1000));
    await tester.pumpWidget(
      h.harness(
        const HomePage(),
        schedule: h.FakeSchedulePort(h.fixtureSchedule()),
        recommend: _five(),
        carouselAutoPlay: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('badge-today')), findsOneWidget);
    final Tooltip tip = tester.widget<Tooltip>(
      find.ancestor(
        of: find.byKey(const Key('badge-today')),
        matching: find.byType(Tooltip),
      ),
    );
    expect(tip.message, '今日更新');
  });

  testWidgets('窄窗（700px 内容宽 ≈516）不溢出：列数 ≥1、轮播不横向溢出', (WidgetTester tester) async {
    h.sizeTo(tester, const Size(700, 900));
    await tester.pumpWidget(
      h.harness(
        const HomePage(),
        recommend: _five(),
        carouselAutoPlay: false,
        carouselShape: DsCarouselShape.portrait,
        carouselSize: DsCarouselSize.l,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: 'RenderFlex overflow 会以异常形式暴露');
    expect(homeGridColumns(516, DsCoverSize.m.maxWidth), greaterThanOrEqualTo(1));
  });
}
