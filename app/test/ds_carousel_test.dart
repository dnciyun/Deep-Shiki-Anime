/// 轮播组件测试（规范 §9.2：圆点/拖拽/键盘/自动播放/四个暂停条件/减少动画；
/// F29 邻卡点击切页；**F31「点谁谁长大」**的切换动画）。
///
/// ⚠️ 纪律：自动播放是常驻循环，涉及它的用例**一律用精确 `pump(interval)`**，
/// 不许 `pumpAndSettle`（那会一直等到超时）。其余用例可以用 `pumpAndSettle`。
///
/// ⚠️ 第三十二轮（F31）换掉了 `PageView`，所以这个组件**没有 `PageController` 了**：
/// 断言一律落在**看得见的东西**上 —— 屏幕上在画哪几张卡（[_visible]）、谁坐在中间（[_mainItem]）、
/// 每张的矩形与透明度（[_cardRect] / [_opacityOf]）。这比读一个内部页码更接近"用户看到的是什么"，
/// 也正是上一版看不出来的那件事（旧实现切换途中同时挂两页 = 6 张卡、同一部两份）。
library;

import 'package:dsanima/theme/tokens.dart';
import 'package:dsanima/ui/widgets/ds_carousel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'carousel_gestures.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 测试替身：一张卡
// ─────────────────────────────────────────────────────────────────────────────

/// 一张卡。**单独一个类型**是有意的：`find.byType(_Card)` 就是"屏幕上现在有几张卡"，
/// 而它带着自己的项号 ⇒ "同一部出现两份"这类退化一眼就能测出来。
class _Card extends StatelessWidget {
  const _Card(this.index, {this.onTap});

  final int index;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    key: Key('card-$index'),
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: ColoredBox(color: DsTokens.whiteInk.sunken),
  );
}

/// 「元素有没有被重建」用的卡：每 `initState` 一次发一个号。
///
/// 第三十三轮「轮播切换时会闪烁」的**成因之一**就是卡片被整批重建 —— `DsCover` 是新 state
/// 时先闪一帧「无封面」。这条不变量只能这么测：序号变了 = 重建了。
int _liveSerial = 0;

class _LiveCard extends StatefulWidget {
  const _LiveCard(this.index);

  final int index;

  @override
  State<_LiveCard> createState() => _LiveCardState();
}

class _LiveCardState extends State<_LiveCard> {
  late final int serial = ++_liveSerial;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: DsTokens.whiteInk.sunken,
  );
}

Widget _harness({
  int count = 5,
  bool autoPlay = false,
  Duration interval = const Duration(seconds: 6),
  DsCarouselGeometry? geometry,
  ValueChanged<int>? onIndexChanged,
  bool disableAnimations = false,
  // 主卡那套"内容自己的"点击（在主页就是"拿番名去搜索"）。
  // 邻卡必须**不**触发它 —— 邻卡被点 = 切到那一张（F29）。
  ValueChanged<int>? onItemTap,
  double width = 1096,
  // 第三十三轮：换成"带实例序号的卡"（测元素有没有被重建）。
  bool liveCards = false,
}) {
  return MaterialApp(
    theme: ThemeData(extensions: <ThemeExtension<dynamic>>[DsTokens.whiteInk]),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: DsCarousel(
              itemCount: count,
              geometry:
                  geometry ??
                  DsCarouselGeometry.forShape(
                    DsCarouselShape.landscape,
                    DsCarouselSize.m,
                  ),
              autoPlay: autoPlay,
              interval: interval,
              onIndexChanged: onIndexChanged,
              itemBuilder: (BuildContext context, int i) => liveCards
                  ? _LiveCard(i)
                  : _Card(i, onTap: onItemTap == null ? null : () => onItemTap(i)),
              captionBuilder: (BuildContext context, int i) =>
                  Text('第 $i 部', key: Key('caption-$i')),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 屏幕上每张"活卡"的（项号 → 实例号）。
///
/// 只在**项号唯一**的用例里用（项数 ≤ 3 时同一部会合理地出现在两个格子上，那时会撞键）。
Map<int, int> _liveSerials(WidgetTester tester) {
  final Finder cards = find.descendant(
    of: find.byType(DsCarousel),
    matching: find.byType(_LiveCard),
  );
  final List<_LiveCard> widgets = tester.widgetList<_LiveCard>(cards).toList();
  return <int, int>{
    for (int i = 0; i < widgets.length; i++)
      widgets[i].index: tester.state<_LiveCardState>(cards.at(i)).serial,
  };
}

/// 屏幕上正在画的那几张卡（顺序 = 绘制顺序，远的在前、最后一张画在最上层）。
List<int> _visible(WidgetTester tester) => tester
    .widgetList<_Card>(
      find.descendant(of: find.byType(DsCarousel), matching: find.byType(_Card)),
    )
    .map((_Card c) => c.index)
    .toList();

Rect _cardRect(WidgetTester tester, int index) =>
    tester.getRect(find.byKey(Key('card-$index')));

/// 卡片的尺寸/位置都要 `closeTo`：卡片是用 `Transform.translate` 摆的（位移 374.4 这类
/// 值本身就不精确），`getRect` 拿到的是变换后的角点 —— 差个 1e-13 就会让 `==` 判不等
/// （打印出来一模一样，只有断言知道）。精确相等只在纯函数那一层断言。
void _expectSize(WidgetTester tester, int index, double w, double h, {String? reason}) {
  final Rect r = _cardRect(tester, index);
  expect(r.width, closeTo(w, 0.01), reason: reason);
  expect(r.height, closeTo(h, 0.01), reason: reason);
}

double _opacityOf(WidgetTester tester, int index) => tester
    .widget<Opacity>(
      find
          .ancestor(
            of: find.byKey(Key('card-$index')),
            matching: find.byType(Opacity),
          )
          .first,
    )
    .opacity;

/// 现在**坐在中间**的那一项（= 那张最大的卡）。落定时无歧义，用它断言"当前是第几部"。
int _mainItem(WidgetTester tester) {
  final List<int> shown = _visible(tester);
  int best = shown.first;
  for (final int i in shown) {
    if (_cardRect(tester, i).width > _cardRect(tester, best).width) best = i;
  }
  return best;
}

/// 轮播块的水平中点（主卡位中心）。
double _midX(WidgetTester tester) =>
    tester.getRect(find.byType(DsCarousel)).center.dx;

void _sizeTo(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 横版·中（默认档）：主卡 552×360、邻卡 264×283、压边 33.6 ⇒ 一格 374.4。
final DsCarouselGeometry _landscapeM = DsCarouselGeometry.forShape(
  DsCarouselShape.landscape,
  DsCarouselSize.m,
);

void main() {
  testWidgets('圆点数量 = 条目数，且每颗都带 key', (WidgetTester tester) async {
    await tester.pumpWidget(_harness(count: 5));
    for (int i = 0; i < 5; i++) {
      expect(find.byKey(Key('carousel-dot-$i')), findsOneWidget);
    }
    expect(find.byKey(const Key('carousel-dot-5')), findsNothing);
  });

  // ── 静止：位置/尺寸/透明度严格来自几何 ───────────────────────────────────────
  testWidgets('静止：主卡 552×360 居中，两侧邻卡 ±374.4 / 264×283 / 0.72 与 0.45', (
    WidgetTester tester,
  ) async {
    _sizeTo(tester, const Size(1200, 900));
    await tester.pumpWidget(_harness());

    final double mid = _midX(tester);
    expect(_visible(tester), <int>[4, 1, 0], reason: '远的先画：左邻卡 → 右邻卡 → 主卡（画在最上层）');

    _expectSize(tester, 0, 552, 360);
    expect(_cardRect(tester, 0).center.dx, closeTo(mid, 0.01));
    _expectSize(tester, 4, 264, 283);
    _expectSize(tester, 1, 264, 283);
    expect(
      _cardRect(tester, 0).center.dx - _cardRect(tester, 4).center.dx,
      closeTo(374.4, 0.01),
    );
    expect(
      _cardRect(tester, 1).center.dx - _cardRect(tester, 0).center.dx,
      closeTo(374.4, 0.01),
    );
    expect(
      _cardRect(tester, 0).center.dy,
      closeTo(_cardRect(tester, 4).center.dy, 0.01),
      reason: '邻卡竖直居中（与主卡同一中线）',
    );
    expect(_opacityOf(tester, 0), 1);
    expect(_opacityOf(tester, 4), 0.72);
    expect(_opacityOf(tester, 1), 0.45);
    expect(tester.getRect(find.byType(DsCarousel)).height, 428);
  });

  testWidgets('点第 3 颗圆点 → 切到第 3 项并回调索引 2（走最短方向，不倒着穿过去）', (
    WidgetTester tester,
  ) async {
    final List<int> seen = <int>[];
    await tester.pumpWidget(_harness(onIndexChanged: seen.add));

    await tester.tap(find.byKey(const Key('carousel-dot-2')));
    await tester.pump();
    // 逐帧 40ms 推完这 320ms：`onIndexChanged` 要跨过半格才报一次，而 `pumpAndSettle`
    // 默认 100ms 一帧 —— 会直接跳过中间那一项，就看不见它"走了哪条路"了。
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    // 0 → 2 只经过 1（若走"绕回去"的长路会依次报 4、3、2）。
    expect(seen, <int>[1, 2]);
    expect(_mainItem(tester), 2);
    expect(find.byKey(const Key('caption-2')), findsOneWidget);
  });

  // ── 拖拽（自己算：跟手 1:1，一格 = carouselSlotOffset 像素）───────────────────
  testWidgets('拖满一格 → 正好下一张（甩动的速度不能让它多翻一张）', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1200, 900));
    await tester.pumpWidget(_harness());

    await tester.timedDrag(
      find.byType(DsCarousel),
      const Offset(-374.4, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();
    expect(_mainItem(tester), 1);
    expect(find.byKey(const Key('caption-1')), findsOneWidget);
  });

  testWidgets('拖不到一半、慢慢松手 → 弹回原处', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1200, 900));
    await tester.pumpWidget(_harness());

    await tester.timedDrag(
      find.byType(DsCarousel),
      const Offset(-112, 0), // 0.3 格；2.7 秒走完 ⇒ 约 41 px/s，远低于甩动阈值
      const Duration(milliseconds: 2700),
    );
    await tester.pumpAndSettle();
    expect(_mainItem(tester), 0);
    expect(find.byKey(const Key('caption-0')), findsOneWidget);
  });

  testWidgets('拖一点点但**甩**一下 → 也算翻一张（甩动阈值 400 px/s）', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1200, 900));
    await tester.pumpWidget(_harness());

    await tester.fling(find.byType(DsCarousel), const Offset(-112, 0), 1200);
    await tester.pumpAndSettle();
    expect(_mainItem(tester), 1);
  });

  testWidgets('拖到一半：卡片**跟手 1:1**（手指走半格 = 卡片正好走半格）', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1200, 900));
    await tester.pumpWidget(_harness());

    final double mid = _midX(tester);
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(DsCarousel)),
    );
    await gesture.moveBy(const Offset(-187.2, 0)); // 半格
    await tester.pump();

    expect(
      _cardRect(tester, 1).center.dx,
      closeTo(mid + 187.2, 0.5),
      reason: '右邻卡走了半格（手指走多少它走多少）',
    );
    expect(_cardRect(tester, 0).center.dx, closeTo(mid - 187.2, 0.5));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_mainItem(tester), 1, reason: '过半就翻一张');
  });

  // ── 自动播放 ───────────────────────────────────────────────────────────────
  testWidgets('自动播放：每 6 秒前进一张（精确 pump，不用 pumpAndSettle）', (
    WidgetTester tester,
  ) async {
    _sizeTo(tester, const Size(1200, 900));
    await tester.pumpWidget(_harness(count: 3, autoPlay: true));

    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_mainItem(tester), 1, reason: '6 秒后应前进一张');

    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_mainItem(tester), 2);

    // 走到末尾要绕回第 0 张（不能卡住）。
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_mainItem(tester), 0);
  });

  testWidgets('autoPlay: false → 什么都不发生', (WidgetTester tester) async {
    await tester.pumpWidget(_harness(autoPlay: false));

    await tester.pump(const Duration(seconds: 7));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_mainItem(tester), 0);
    expect(find.byKey(const Key('caption-0')), findsOneWidget);
  });

  testWidgets('悬停暂停：指针在轮播区内时不前进，移开后恢复', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness(autoPlay: true));

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: tester.getCenter(find.byType(DsCarousel)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 7));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_mainItem(tester), 0, reason: '悬停时必须暂停');

    await mouse.moveTo(const Offset(4, 4)); // 移出轮播区
    await tester.pump();
    await tester.pump(const Duration(seconds: 7));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_mainItem(tester), 1, reason: '移开后应恢复自动播放');
    await mouse.removePointer();
  });

  testWidgets('「减少动画」：切换不做过渡，但依然生效', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1200, 900));
    await tester.pumpWidget(_harness(disableAnimations: true));

    await tester.tap(find.byKey(const Key('carousel-dot-3')));
    await tester.pump();

    expect(_mainItem(tester), 3);
    _expectSize(tester, 3, 552, 360, reason: '一帧就位，不经过中间尺寸');
  });

  // ── F29：邻卡 = 切页热区 ────────────────────────────────────────────────────
  testWidgets('点右侧半露的邻卡 → 切到后面那一张（不是直接搜索）', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1200, 900));
    final List<int> itemTaps = <int>[];
    await tester.pumpWidget(_harness(onItemTap: itemTaps.add));

    await tapCarouselNeighbour(tester, right: true, geometry: _landscapeM);
    await tester.pumpAndSettle();

    expect(_mainItem(tester), 1, reason: '切到后面那一张');
    expect(itemTaps, isEmpty, reason: '邻卡那套点击（主页 = 拿番名去搜索）绝不能再被触发');
    expect(find.byKey(const Key('caption-1')), findsOneWidget, reason: '文字块跟着切到第 2 部');
  });

  testWidgets('点左侧半露的邻卡 → 切回上一张（第 0 项时绕到最后一张）', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1200, 900));
    final List<int> itemTaps = <int>[];
    await tester.pumpWidget(_harness(onItemTap: itemTaps.add));

    await tapCarouselNeighbour(tester, right: false, geometry: _landscapeM);
    await tester.pumpAndSettle();

    expect(_mainItem(tester), 4, reason: '第 0 项的左侧邻卡 = 最后一张（绕回）');
    expect(itemTaps, isEmpty);
  });

  testWidgets('主卡自己的点击照旧生效（F29 只改了邻卡）', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1200, 900));
    final List<int> itemTaps = <int>[];
    await tester.pumpWidget(_harness(onItemTap: itemTaps.add));

    await tester.tapAt(tester.getCenter(find.byKey(const Key('card-0'))));
    await tester.pumpAndSettle();
    expect(itemTaps, <int>[0]);
    expect(_mainItem(tester), 0, reason: '点主卡不切页');
  });

  // ── F31：「点谁谁长大」───────────────────────────────────────────────────────
  testWidgets('F31：切换途中最多 4 张卡，且同一部**不会**出现两份（旧实现中途是 6 张、同一部两份）', (
    WidgetTester tester,
  ) async {
    _sizeTo(tester, const Size(1200, 900));
    await tester.pumpWidget(_harness());

    await tapCarouselNeighbour(tester, right: true, geometry: _landscapeM);
    await tester.pump();
    for (int ms = 0; ms <= 320; ms += 40) {
      final List<int> shown = _visible(tester);
      expect(
        shown.length,
        lessThanOrEqualTo(4),
        reason: 't=${ms}ms：最多 4 张（主卡 + 两侧邻卡 + 正在进出的一张）',
      );
      expect(
        shown.toSet().length,
        shown.length,
        reason: 't=${ms}ms：同一部不能出现两份 —— $shown',
      );
      await tester.pump(const Duration(milliseconds: 40));
    }
    await tester.pumpAndSettle();
    expect(_mainItem(tester), 1);
    expect(_visible(tester), <int>[0, 2, 1], reason: '落定：左邻卡 0 / 右邻卡 2 / 主卡 1');
  });

  testWidgets('F31「点谁谁长大」：被点的邻卡在长大、旧主卡在缩小，位移与尺寸一起插值', (
    WidgetTester tester,
  ) async {
    _sizeTo(tester, const Size(1200, 900));
    await tester.pumpWidget(_harness());

    final double mid = _midX(tester);
    _expectSize(tester, 1, 264, 283, reason: '点之前它是右邻卡');
    expect(_cardRect(tester, 1).center.dx, closeTo(mid + 374.4, 0.01));

    await tapCarouselNeighbour(tester, right: true, geometry: _landscapeM);
    await tester.pump();

    // 逐帧：被点的那张**只往大走**、旧主卡**只往小走**，两张同时向左/右让位。
    double lastClicked = _cardRect(tester, 1).width;
    double lastOldMain = _cardRect(tester, 0).width;
    double lastClickedX = _cardRect(tester, 1).center.dx;
    expect(lastClicked, closeTo(264, 0.01));
    expect(lastOldMain, closeTo(552, 0.01));
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 60));
      final double clicked = _cardRect(tester, 1).width;
      final double oldMain = _cardRect(tester, 0).width;
      final double clickedX = _cardRect(tester, 1).center.dx;
      expect(clicked, greaterThan(lastClicked), reason: '第 ${i + 1} 帧：被点的还在长大');
      expect(oldMain, lessThan(lastOldMain), reason: '第 ${i + 1} 帧：旧主卡还在缩小');
      expect(clickedX, lessThan(lastClickedX), reason: '第 ${i + 1} 帧：它在往中间走');
      lastClicked = clicked;
      lastOldMain = oldMain;
      lastClickedX = clickedX;
    }
    // 中途（约过半）：被点的那张已经比邻卡大得多、且画在最上层（"走到前面来"）。
    expect(lastClicked, greaterThan(320));
    expect(_visible(tester).last, 1, reason: '被点的那张画在最上层');

    await tester.pumpAndSettle();
    _expectSize(tester, 1, 552, 360, reason: '落定时它就是主卡（同一张卡长大，不是新来的一张）');
    expect(_cardRect(tester, 1).center.dx, closeTo(mid, 0.01));
    _expectSize(tester, 0, 264, 283, reason: '旧主卡退成左邻卡');
    expect(_cardRect(tester, 0).center.dx, closeTo(mid - 374.4, 0.01));
  });

  testWidgets('F31：被顶出去的那张继续向外滑并淡出，落定时不再在树里', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1200, 900));
    await tester.pumpWidget(_harness());

    expect(_opacityOf(tester, 4), 0.72, reason: '它本来是左邻卡');
    await tapCarouselNeighbour(tester, right: true, geometry: _landscapeM);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(_visible(tester), contains(4), reason: '它还在画（正在往外走）');
    expect(_opacityOf(tester, 4), lessThan(0.72), reason: '一边往外走一边淡出');
    expect(_opacityOf(tester, 4), greaterThan(0));
    expect(
      _cardRect(tester, 4).center.dx,
      lessThan(_midX(tester) - 374.4),
      reason: '已经越过左邻卡位，继续往左',
    );

    await tester.pumpAndSettle();
    expect(find.byKey(const Key('card-4')), findsNothing, reason: '完全淡出后不画（也不该挡点击）');
  });

  testWidgets('F32：切换全程卡片元素**不重建**（重建 = 封面重新解析 = 闪一帧）', (
    WidgetTester tester,
  ) async {
    _sizeTo(tester, const Size(1200, 900));
    await tester.pumpWidget(_harness(liveCards: true, count: 5));

    Map<int, int> previous = _liveSerials(tester);
    expect(previous, hasLength(3), reason: '静止：左邻卡 / 主卡 / 右邻卡');

    await tapCarouselNeighbour(tester, right: true, geometry: _landscapeM);
    await tester.pump();
    for (int ms = 0; ms <= 320; ms += 40) {
      final Map<int, int> now = _liveSerials(tester);
      for (final MapEntry<int, int> card in now.entries) {
        if (!previous.containsKey(card.key)) continue; // 刚进窗口的那张（本来就是新元素）
        expect(
          card.value,
          previous[card.key],
          reason: 't=${ms}ms：第 ${card.key} 部的卡被重建了 '
              '（改前一次切换整批重建 4 遍，每遍都会闪一帧「无封面」）',
        );
      }
      previous = now;
      await tester.pump(const Duration(milliseconds: 40));
    }

    await tester.pumpAndSettle();
    // 落定：第 1 部坐中间（这一局用的是 `_LiveCard`，`_mainItem` 那套 helper 找的是 `_Card`）。
    expect(
      tester
          .getRect(
            find.byWidgetPredicate(
              (Widget w) => w is _LiveCard && w.index == 1,
            ),
          )
          .width,
      closeTo(552, 0.01),
    );
    // 落定这一步（改前会把位置折回 `[0, itemCount)`，格号一变四张卡的 key 全换）也不许重建。
    for (final MapEntry<int, int> card in _liveSerials(tester).entries) {
      if (previous.containsKey(card.key)) {
        expect(card.value, previous[card.key], reason: '落定又重建了一次');
      }
    }
  });

  testWidgets('文字块跟着卡片一起过渡（不再在 t≈160ms 中途"啪"地换掉）', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1200, 900));
    await tester.pumpWidget(_harness());
    expect(find.byKey(const Key('caption-0')), findsOneWidget);

    await tapCarouselNeighbour(tester, right: true, geometry: _landscapeM);
    await tester.pump();
    // `_index` 是**过半**才翻的（t≈160ms），所以交叉过渡从那里才开始 —— 采 240ms 这一帧。
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pump(const Duration(milliseconds: 80));

    // 中途：新旧两个文字块**同时**在（交叉过渡），而不是一刀切换掉。
    expect(find.byKey(const Key('caption-0')), findsOneWidget);
    expect(find.byKey(const Key('caption-1')), findsOneWidget);
    final double fadingOut = tester
        .widget<FadeTransition>(
          find
              .ancestor(
                of: find.byKey(const Key('caption-0')),
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity
        .value;
    expect(fadingOut, lessThan(1));
    expect(fadingOut, greaterThan(0));

    await tester.pumpAndSettle();
    expect(find.byKey(const Key('caption-0')), findsNothing, reason: '过渡结束后旧的必须收掉');
    expect(find.byKey(const Key('caption-1')), findsOneWidget);
  });

  // ── 圆点居中 / 最宽档 / 空态 ────────────────────────────────────────────────
  testWidgets('圆点在中间：这一组圆点的中点 = 主卡中点（原来贴右）', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1200, 900));
    await tester.pumpWidget(_harness(count: 5));

    final Rect block = tester.getRect(find.byType(DsCarousel));
    final Rect first = tester.getRect(find.byKey(const Key('carousel-dot-0')));
    final Rect last = tester.getRect(find.byKey(const Key('carousel-dot-4')));

    expect(
      (first.left + last.right) / 2,
      closeTo(_cardRect(tester, 0).center.dx, 0.5),
      reason: '圆点居中（每颗左边那 6px 是间距垫，5 颗对称，中点仍与主卡对齐）',
    );
    expect(
      block.right - last.right,
      greaterThan(200),
      reason: '贴右时最后一颗就在块的最右边（这条防回潮）',
    );
  });

  testWidgets('最宽那档（横版·大 1.5，整块 1266 > 可用 1060）不 overflow，邻卡照旧能点', (
    WidgetTester tester,
  ) async {
    _sizeTo(tester, const Size(1200, 900));
    await tester.pumpWidget(
      _harness(
        width: 1060,
        geometry: DsCarouselGeometry.forShape(
          DsCarouselShape.landscape,
          DsCarouselSize.l,
        ),
      ),
    );

    expect(tester.takeException(), isNull, reason: '越界的只是邻卡（Clip.none），不许 RenderFlex/Debug overflow');
    final Rect block = tester.getRect(find.byType(DsCarousel));
    final Rect card = _cardRect(tester, 0);
    expect(card.width, 690, reason: '主卡仍是几何值');
    expect(card.left, greaterThanOrEqualTo(block.left));
    expect(card.right, lessThanOrEqualTo(block.right));

    await tapCarouselNeighbour(
      tester,
      right: true,
      geometry: DsCarouselGeometry.forShape(
        DsCarouselShape.landscape,
        DsCarouselSize.l,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('caption-1')), findsOneWidget);
  });

  testWidgets('条目数为 0 时不崩（空态由调用方负责）', (WidgetTester tester) async {
    await tester.pumpWidget(_harness(count: 0));
    expect(find.byType(DsCarousel), findsOneWidget);
    expect(find.byType(_Card), findsNothing);
  });

  // ── 第三十四轮：两侧羽化（用户：「他都跑到侧边栏了才消失掉」）──────────────────
  testWidgets('两侧羽化：卡片被钉在轮播块里，且**到块边缘之前**就淡到 0（不再被外层视口一刀切）', (
    WidgetTester tester,
  ) async {
    // 1280 窗宽下的真实内容宽：1280 − 侧栏 184 − 主页左右内边距 18×2 = 1060。
    // 用户当前那一档是横版·大 1.5（主卡 690、邻卡 330、一格 468）—— 邻卡位就已经越过块。
    _sizeTo(tester, const Size(1400, 1000));
    final DsCarouselGeometry g = DsCarouselGeometry.forShape(
      DsCarouselShape.landscape,
      DsCarouselSize.l,
    );
    await tester.pumpWidget(_harness(width: 1060, geometry: g));

    final Rect block = tester.getRect(find.byType(DsCarousel));

    // ① 每一张卡都在裁剪盒里 —— 无论外层是滚动视口还是别的什么，都不可能再画到侧边栏上。
    for (final int i in _visible(tester)) {
      expect(
        find.ancestor(
          of: find.byKey(Key('card-$i')),
          matching: find.byKey(dsCarouselClipKey),
        ),
        findsOneWidget,
        reason: '第 $i 张卡必须在 $dsCarouselClipKey 这层裁剪里',
      );
    }
    final Rect clip = tester.getRect(find.byKey(dsCarouselClipKey));
    expect(clip.left, closeTo(block.left, 0.01), reason: '裁剪盒左右就是轮播块自己');
    expect(clip.right, closeTo(block.right, 0.01), reason: '（不是外层视口那条"侧边栏线"）');
    expect(clip.height, g.main.height, reason: '只裁卡片那一条，文字块与圆点照旧');

    // ② 卡片**确实**越出块（这就是用户看到"跑到侧边栏"的原因）—— 但羽化带在块内侧就归零了。
    final Rect right = _cardRect(tester, 1);
    expect(
      right.right,
      greaterThan(block.right),
      reason: '右邻卡右缘越过块右缘（大档一格 468，邻卡位就已经出去了）',
    );
    final LinearGradient mask = carouselEdgeMask(block.width, g)!;
    expect(
      find.byKey(dsCarouselEdgeMaskKey),
      findsOneWidget,
      reason: '块够宽 ⇒ 必须挂上羽化层',
    );
    final double half = block.width / 2;
    final DsCarouselEdgeBands bands = carouselEdgeBands(block.width, g)!;
    expect(
      half - bands.outer,
      closeTo(kCarouselEdgeMargin, 0.01),
      reason: '淡出在块边缘**内侧**结束（留 $kCarouselEdgeMargin px 全透明空档）',
    );
    // 四段 stop 与四条色一一对应，且**第一段就是"边缘内侧 margin 处"** ——
    // 再往外（还没有到第一个 stop 的地方）由 `TileMode.clamp` 保持全透明。
    // 第三十四轮那一版把 `0` 当成第一段斜坡的起点，于是整个左半块都是渐变（见下一条 ③）。
    expect(mask.stops!.length, mask.colors.length, reason: '四段 stop 对四条色');
    expect(
      mask.stops!.first,
      closeTo(kCarouselEdgeMargin / block.width, 0.001),
      reason: '最外侧 $kCarouselEdgeMargin px 必须完全透明',
    );
    expect(
      bands.inner,
      greaterThanOrEqualTo(g.main.width / 2 - 0.01),
      reason: '羽化起点 ≥ 主卡半宽，否则窄窗口下主卡自己会发虚',
    );
    expect(
      carouselEdgeAlpha(block.width, g, half - 0.5),
      0,
      reason: '块边缘那一点必须完全透明（是化干净的，不是被切掉的）',
    );
    // ③ **主卡整张不透明** —— 第三十五轮用户报的「轮播整个变透明了点」就钉在这儿。
    expect(
      carouselEdgeAlpha(block.width, g, _cardRect(tester, 0).left - block.center.dx),
      1,
      reason: '主卡左缘必须 alpha=1（上一版这里只有 0.21）',
    );
    expect(
      carouselEdgeAlpha(block.width, g, _cardRect(tester, 0).right - block.center.dx),
      1,
      reason: '主卡右缘必须 alpha=1',
    );
    // ④ 滑出去的那张站进羽化带，而且**最靠内的一半还是实心的** ⇒
    //    不是"到线上一刀切"，也不是"整块邻卡都糊掉"。
    final double mainHalf = g.main.width / 2;
    final double rightOuter = right.right - block.center.dx;
    expect(
      bands.inner,
      greaterThan(mainHalf),
      reason: '邻卡贴着主卡那一段必须保持实心（alpha 1）',
    );
    expect(rightOuter, greaterThan(bands.inner), reason: '右邻卡的外侧落在羽化带里');
    expect(
      carouselEdgeAlpha(block.width, g, mainHalf),
      1,
      reason: '邻卡最内侧（贴着主卡的那条边）是实心的',
    );
    final double rampMid = (bands.inner + bands.outer) / 2;
    expect(carouselEdgeAlpha(block.width, g, rampMid), closeTo(0.5, 0.02), reason: '斜坡中点约一半');
    expect(
      carouselEdgeAlpha(block.width, g, rightOuter),
      0,
      reason: '邻卡真正的外缘已经透明（块外那部分本来就被裁掉）',
    );
  });

  testWidgets('羽化带：窗口够宽时静止观感与改前**一模一样**（邻卡不被提前压暗）', (
    WidgetTester tester,
  ) async {
    // 1600 窗（内容宽 1380）：静止时右邻卡占 242.4…506.4，而羽化从 650 才开始。
    _sizeTo(tester, const Size(1700, 1000));
    await tester.pumpWidget(_harness(width: 1380));

    final Rect neighbour = _cardRect(tester, 1);
    expect(
      carouselEdgeAlpha(1380, _landscapeM, neighbour.right - _midX(tester)),
      1,
      reason: '右邻卡整个落在羽化带里侧 ⇒ 蒙版不压暗它，透明度仍是几何给的 0.45',
    );
    expect(_opacityOf(tester, 1), 0.45);
    expect(_opacityOf(tester, 4), 0.72);
    _expectSize(tester, 0, 552, 360, reason: '主卡几何不变');
  });

  test('羽化函数：块放不下主卡时返回 null（窄窗照旧，不拿主卡去换邻卡）', () {
    final DsCarouselGeometry big = DsCarouselGeometry.forShape(
      DsCarouselShape.landscape,
      DsCarouselSize.l,
    );
    // 大档主卡 690：块 740 只比主卡宽 50（< 2×28）⇒ 不羽化。
    expect(carouselEdgeMask(740, big), isNull);
    expect(carouselEdgeBands(740, big), isNull);
    expect(carouselEdgeMask(520, _landscapeM), isNull, reason: '520 < 552 的组装测试那档');
    expect(carouselEdgeMask(0, big), isNull);
    // 不羽化时蒙版恒为 1（卡片原样画出来）。
    expect(carouselEdgeAlpha(740, big, 370), 1);
  });

  test('羽化函数：四处边界 + **主卡整张恒为 alpha 1**（第三十五轮回归）', () {
    final DsCarouselGeometry big = DsCarouselGeometry.forShape(
      DsCarouselShape.landscape,
      DsCarouselSize.l,
    );
    // 块 1060 / 大档：主卡外只剩 185px ⇒ 斜坡被"留一半实心"夹到 437.5→502，
    // 最外侧 28px 全透明（主卡半宽 345）。
    final DsCarouselEdgeBands bands = carouselEdgeBands(1060, big)!;
    const double half = 530;
    const double mainHalf = 345;
    expect(bands.outer, closeTo(half - kCarouselEdgeMargin, 0.01));
    expect(
      bands.inner,
      closeTo(mainHalf + (half - mainHalf) * kCarouselEdgeSolidShare, 0.01),
      reason: '主卡外那一条的一半必须留给邻卡当实心段',
    );
    expect(bands.inner, greaterThan(mainHalf), reason: '羽化带起点在主卡之外');
    expect(
      bands.outer - bands.inner,
      lessThan(690 * kCarouselEdgeFeather),
      reason: '斜坡被夹过之后比"主卡宽 × 系数"更窄（不然邻卡整块都糊了）',
    );

    final LinearGradient mask = carouselEdgeMask(1060, big)!;
    // 两端透明、中间不透明（`dstIn` 只看 alpha）；**四段 stop 必须递增**。
    expect(<double>[for (final Color c in mask.colors) c.a], <double>[0, 1, 1, 0]);
    expect(mask.stops!.length, 4);
    for (int i = 1; i < mask.stops!.length; i++) {
      expect(mask.stops![i], greaterThan(mask.stops![i - 1]), reason: '第 $i 段 stop 与上一段不递增');
    }
    expect(mask.stops!.first, closeTo(kCarouselEdgeMargin / 1060, 1e-6));
    expect(mask.stops!.last, closeTo(1 - kCarouselEdgeMargin / 1060, 1e-6));
    expect(
      mask.stops![1] * 1060,
      closeTo(half - bands.inner, 0.01),
      reason: '第二段 stop = 左侧开始不透明的地方（上一版这里是"左端斜坡的终点"）',
    );

    // alpha 曲线：最外侧 0、主卡内侧 1、斜坡在两者之间。
    expect(carouselEdgeAlpha(1060, big, 529), 0);
    expect(carouselEdgeAlpha(1060, big, bands.outer), 0);
    expect(carouselEdgeAlpha(1060, big, (bands.inner + bands.outer) / 2), closeTo(0.5, 0.01));
    expect(carouselEdgeAlpha(1060, big, bands.inner), 1);
    expect(carouselEdgeAlpha(1060, big, 0), 1);
    expect(carouselEdgeAlpha(1060, big, -bands.inner), 1, reason: '左右对称');
    expect(carouselEdgeAlpha(1060, big, mainHalf), 1, reason: '邻卡最内侧实心');

    // 中档在 1380 的块里：主卡外有 414px，斜坡按"主卡宽 × 系数"走，邻卡整个是实心的。
    final DsCarouselEdgeBands wide = carouselEdgeBands(1380, _landscapeM)!;
    expect(wide.outer - wide.inner, closeTo(552 * kCarouselEdgeFeather, 0.01));
    expect(carouselEdgeAlpha(1380, _landscapeM, 506.4), 1, reason: '静止时右邻卡外缘仍是 alpha 1');

    // ⚠️ 回归（用户：「轮播整个变透明了点」）：**任意宽度下主卡覆盖的每一点都是 alpha 1**。
    //    上一版这里是一条从边缘开始的斜坡，主卡左缘只有 0.21。
    for (final (double w, DsCarouselGeometry g) in <(double, DsCarouselGeometry)>[
      (1060, big),
      (1380, _landscapeM),
      (1600, _landscapeM),
      (900, _landscapeM),
      (620, DsCarouselGeometry.forShape(DsCarouselShape.portrait, DsCarouselSize.l)),
    ]) {
      for (int i = 0; i <= 20; i++) {
        final double dx = -g.main.width / 2 + g.main.width * i / 20;
        expect(
          carouselEdgeAlpha(w, g, dx),
          1,
          reason: '$w 宽 / 主卡 ${g.main.width} 下，距中线 $dx 的那一点被压暗了',
        );
      }
    }
  });

  // ── 卡片规格（纯函数）：拖拽跟手比例与动画落点同源 ───────────────────────────
  test('卡片规格：两端严格是主卡/邻卡，位移对格距线性，透明度线性归零', () {
    final DsCarouselCardSpec main = DsCarouselCardSpec.forOffset(_landscapeM, 0);
    expect(main.size, const Size(552, 360));
    expect(main.dx, 0);
    expect(main.opacity, 1);

    final DsCarouselCardSpec left = DsCarouselCardSpec.forOffset(_landscapeM, -1);
    expect(left.size, const Size(264, 283));
    expect(left.dx, closeTo(-374.4, 0.01));
    expect(left.opacity, 0.72);

    final DsCarouselCardSpec right = DsCarouselCardSpec.forOffset(_landscapeM, 1);
    expect(right.size, const Size(264, 283));
    expect(right.dx, closeTo(374.4, 0.01));
    expect(right.opacity, 0.45);

    // 一半：两张一样大（408×321.5），各在主卡位两侧半格处。
    final DsCarouselCardSpec half = DsCarouselCardSpec.forOffset(_landscapeM, 0.5);
    expect(half.size, const Size(408, 321.5));
    expect(half.dx, closeTo(187.2, 0.01));
    expect(half.opacity, closeTo(0.725, 0.0001), reason: '1 → 0.45 的一半 = 0.725');

    // 一格 = 邻卡位到主卡位的距离（拖拽换算与动画用的是同一个函数）。
    expect(carouselSlotOffset(_landscapeM), closeTo(374.4, 0.01));

    // 出画那一段：继续按同样步长外滑、透明度线性归零。
    final DsCarouselCardSpec out = DsCarouselCardSpec.forOffset(_landscapeM, -1.5);
    expect(out.dx, closeTo(-374.4 * 1.5, 0.01));
    expect(out.opacity, closeTo(0.36, 0.0001));
    expect(DsCarouselCardSpec.forOffset(_landscapeM, -2).opacity, 0);
  });
}
