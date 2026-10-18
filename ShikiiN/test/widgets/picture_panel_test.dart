/// 「画面调节」滑杆面板：重置键 + 浮层不许给画面盖颜色（用户 2026-10-18 两个反馈）。
///
/// 这条用例存在的理由：
/// * 「滑杆那没有重置键」—— 重置必须是**一键回到包的默认值并立即生效**，而不是
///   "只改界面草稿"（那样画面不变，用户会以为按钮坏了）；
/// * 「打开滑杆面板时画面有层透明白色」—— 旧的遮罩铺的是 `tokens.base`
///   （浅色主题下是接近白的面色）28% 透明度。这里用"整层只允许出现面板自己那一个
///   有底色的盒子"来钉住它：谁再往浮层里加一层色，用例就会红。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/picture_menu.dart';
import 'package:shikiin/models/theme_tokens.dart';
import 'package:shikiin/widgets/picture_panel.dart';

/// 记录调用、能把值改回来的假菜单（真菜单在宿主里，接口只要求这些方法）。
class _FakeMenu implements PictureMenu {
  _FakeMenu({
    this.packName = '演示包',
    this.presets = const <PicturePresetInfo>[],
    this.params = const <PictureParamInfo>[
      PictureParamInfo(
        key: 'sharpen',
        label: '锐度',
        min: 0,
        max: 2,
        step: 0.05,
        defaultValue: 1,
        group: '锐度与线条',
      ),
      PictureParamInfo(
        key: 'line',
        label: '线条',
        min: 0,
        max: 1,
        step: 0.05,
        defaultValue: 0.45,
        group: '锐度与线条',
      ),
      PictureParamInfo(
        key: 'contrast',
        label: '对比度',
        min: 0.5,
        max: 1.5,
        step: 0.01,
        defaultValue: 1,
        group: '对比与饱和',
      ),
    ],
    Map<String, double>? initial,
  }) : _values = <String, double>{
          for (final PictureParamInfo p in params) p.key: p.defaultValue,
          ...?initial,
        };

  @override
  final List<PictureParamInfo> params;

  final Map<String, double> _values;

  /// 收到过哪些 `setValue`（顺序即调用顺序）。
  final List<(String, double)> setValueCalls = <(String, double)>[];

  /// `applyValues` 被调了几次（重置必须立刻生效 = 1 次）。
  int applyCount = 0;

  @override
  final String packName;

  @override
  final List<PicturePresetInfo> presets;

  @override
  String? get activePresetId => null;

  @override
  bool get isOff => false;

  @override
  double valueOf(String key) => _values[key] ?? 0;

  @override
  void setValue(String key, double value) {
    setValueCalls.add((key, value));
    _values[key] = value;
  }

  @override
  Future<void> applyValues() async {
    applyCount++;
  }

  @override
  Future<void> reload() async {}

  @override
  Future<void> selectPack(String packId, {String? presetId}) async {}

  @override
  Future<void> selectPreset(String? presetId) async {}

  @override
  Future<void> turnOff() async {}
}

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Stack(children: <Widget>[child])),
    );

void main() {
  // 800×450 的测试面：面板固定在 right: 24 / top: 60，宽 320。
  const Size surface = Size(800, 450);

  testWidgets('重置：全部参数回默认值，并且立刻 apply 一次', (WidgetTester tester) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final _FakeMenu menu = _FakeMenu(
      initial: <String, double>{'sharpen': 0.2, 'contrast': 1.3},
    );
    await tester.pumpWidget(_host(PicturePanel(
      menu: menu,
      tokens: ThemeTokens.fallback,
      onClose: () {},
    )));

    await tester.tap(find.text(kPictureResetLabel));
    await tester.pump();

    // 每个参数都被写回了默认值（顺序 = 面板里的参数顺序）。
    expect(menu.setValueCalls, <(String, double)>[
      ('sharpen', 1.0),
      ('line', 0.45),
      ('contrast', 1.0),
    ]);
    expect(menu.applyCount, 1);

    // 滑杆本身也回到了默认值（草稿跟着重置，不是只改宿主）。
    final List<Slider> sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
    expect(sliders.map((Slider s) => s.value), <double>[1.0, 0.45, 1.0]);
  });

  testWidgets('重置会取消拖动留下的防抖，不会多 apply 一次', (WidgetTester tester) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final _FakeMenu menu = _FakeMenu();
    await tester.pumpWidget(_host(PicturePanel(
      menu: menu,
      tokens: ThemeTokens.fallback,
      onClose: () {},
    )));

    // 拖一下第一个滑杆：松手后应当排一次 220ms 的防抖 apply（还没到点）。
    await tester.drag(find.byType(Slider).first, const Offset(40, 0));
    await tester.pump(const Duration(milliseconds: 50));
    expect(menu.applyCount, 0, reason: '防抖还没到点');

    await tester.tap(find.text(kPictureResetLabel));
    await tester.pump();
    expect(menu.applyCount, 1, reason: '重置立刻 apply');

    // 防抖被取消：再等一段也不会冒出第二次 apply。
    await tester.pump(const Duration(milliseconds: 500));
    expect(menu.applyCount, 1);
  });

  testWidgets('矮窗口：面板收进画面、内容改成滚动（不裁掉底部滑杆）', (WidgetTester tester) async {
    // PiP 是 480×270，用户也可能把播放窗口拖得很小 —— 面板固定 320×570 会顶出去，
    // Stack 一裁，下面几组滑杆就再也够不到。
    const Size small = Size(300, 260);
    tester.view.physicalSize = small;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final List<PictureParamInfo> many = <PictureParamInfo>[
      for (int i = 0; i < 8; i++)
        PictureParamInfo(
          key: 'p$i',
          label: '参数$i',
          min: 0,
          max: 1,
          step: 0.05,
          defaultValue: 0.5,
          group: '锐度与线条',
        ),
    ];
    await tester.pumpWidget(_host(PicturePanelLayer(
      menu: _FakeMenu(params: many),
      tokens: ThemeTokens.fallback,
      onClose: () {},
    )));

    expect(tester.takeException(), isNull, reason: '矮窗口不许 RenderFlex 溢出');
    final Size panel = tester.getSize(find.byType(Container).last);
    // 高度被夹到"画面高度 - 顶部留白 - 底边留白"以内，宽度跟着窗口收。
    expect(panel.height, lessThanOrEqualTo(small.height - kPicturePanelTop - kPicturePanelMargin));
    expect(panel.width, lessThanOrEqualTo(small.width - kPicturePanelMargin * 2 + 0.01));
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });

  testWidgets('没有可调参数时不显示重置键', (WidgetTester tester) async {
    final _FakeMenu empty = _FakeMenu(params: const <PictureParamInfo>[]);
    await tester.pumpWidget(_host(PicturePanel(
      menu: empty,
      tokens: ThemeTokens.fallback,
      onClose: () {},
    )));
    expect(find.text(kPictureResetLabel), findsNothing);
  });

  testWidgets('浮层只允许面板自己那块底色：不许再有盖住画面的遮罩色', (WidgetTester tester) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    int closed = 0;
    await tester.pumpWidget(_host(PicturePanelLayer(
      menu: _FakeMenu(),
      tokens: ThemeTokens.fallback,
      onClose: () => closed++,
    )));

    // 浮层里**不许出现铺满画面的有色盒子**：旧实现的遮罩就是铺满 800×450 的
    // `Container(color: tokens.base.withValues(alpha: .28))`，即"一层透明白色"。
    for (final Element element
        in find.descendant(
          of: find.byType(PicturePanelLayer),
          matching: find.byType(Container),
        ).evaluate()) {
      final Size size = tester.getSize(find.byWidget(element.widget));
      expect(size.width, lessThan(surface.width), reason: '铺满宽度的有色盒子 = 遮罩');
    }
    // 也不许换成 ColoredBox / DecoratedBox 之类的整面涂色。
    expect(
      find.descendant(of: find.byType(PicturePanelLayer), matching: find.byType(ColoredBox)),
      findsNothing,
    );

    // 命中面是**透明**的：一个 opaque 的 GestureDetector，孩子是空白盒子（不涂色）。
    // （面板里的 InkWell 也是 opaque 的 GestureDetector，所以按"孩子是 SizedBox"区分。）
    final Finder tapCatcher = find.byWidgetPredicate(
      (Widget w) =>
          w is GestureDetector &&
          w.behavior == HitTestBehavior.opaque &&
          w.child is SizedBox,
    );
    expect(tapCatcher, findsOneWidget);
    expect(tester.getSize(tapCatcher), surface);

    // 命中面保持"透明但可点"：点面板外（左下方）应当关闭。
    await tester.tapAt(const Offset(120, 300));
    expect(closed, 1);

    // 点面板里面**不该**关闭（面板自己要接住事件）。
    await tester.tap(find.text(kPictureResetLabel));
    expect(closed, 1);
  });

  // 用户 2026-10-18：「调节滑杆面板里名字为什么叫画面调节 清晰」。
  // 回归点：面板第一行原本是 `'画面调节 · ${menu.packName}'`，而那个包的 name
  // 当时就叫「画面调节 · 清晰」（"清晰"其实是**预设**名），叠出来是
  // 「画面调节 · 画面调节 · 清晰」。现在：单包时只写「画面调节」，多包才补包名
  // （否则滑杆分不清是谁的）。
  group('面板标题', () {
    const PicturePresetInfo crisp =
        PicturePresetInfo(id: 'dsanima-picture-crisp/crisp', name: '清晰');
    const PicturePresetInfo other =
        PicturePresetInfo(id: 'someone-else/soft', name: '柔和');

    test('单包（哪怕包名叫「画面调节 · 清晰」）→ 只写「画面调节」', () {
      expect(
        picturePanelTitle(_FakeMenu(packName: '画面调节 · 清晰', presets: const <PicturePresetInfo>[crisp])),
        kPicturePanelTitle,
        reason: '用户看到的那行就是它：不该把包名/预设名拼进标题',
      );
      expect(
        picturePanelTitle(_FakeMenu(packName: '清晰增强', presets: const <PicturePresetInfo>[crisp])),
        kPicturePanelTitle,
      );
    });

    test('没有预设（只有滑杆）→ 也是「画面调节」', () {
      expect(picturePanelTitle(_FakeMenu()), kPicturePanelTitle);
    });

    test('装了多个包 → 补包名（不然分不清滑杆属于谁）', () {
      expect(
        picturePanelTitle(_FakeMenu(
          packName: '清晰增强',
          presets: const <PicturePresetInfo>[crisp, other],
        )),
        '画面调节 · 清晰增强',
      );
    });

    test('多包时包名自己带「画面调节」→ 不再叠第二次', () {
      expect(
        picturePanelTitle(_FakeMenu(
          packName: '画面调节 · 清晰',
          presets: const <PicturePresetInfo>[crisp, other],
        )),
        '画面调节 · 清晰',
      );
      expect(
        picturePanelTitle(_FakeMenu(
          packName: '   ',
          presets: const <PicturePresetInfo>[crisp, other],
        )),
        kPicturePanelTitle,
      );
    });

    testWidgets('面板第一行就是「画面调节」', (WidgetTester tester) async {
      await tester.pumpWidget(_host(PicturePanel(
        menu: _FakeMenu(
          packName: '画面调节 · 清晰',
          presets: const <PicturePresetInfo>[crisp],
        ),
        tokens: ThemeTokens.fallback,
        onClose: () {},
      )));
      expect(find.text(kPicturePanelTitle), findsOneWidget);
      expect(find.textContaining(' · 清晰'), findsNothing);
      expect(find.textContaining('画面调节 · 画面调节'), findsNothing);
    });
  });
}
