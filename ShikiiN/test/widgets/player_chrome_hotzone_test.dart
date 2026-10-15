/// 播放器 chrome（标题栏 / 控制栏）的**鼠标热区与显隐规则**。
///
/// 用户 2026-10-12 第十四轮原话：
/// > 「修改播放器逻辑，鼠标移动到标题栏/控制栏时才会显现」
///
/// 用户 **2026-10-13 第二十六轮**原话（本轮把规则讲全了）：
/// > 「播放器标题栏控制栏逻辑优化，鼠标在热区内就会保持显现，移走后淡出。
/// >  播放器逻辑优化，鼠标不动时才隐藏。」
///
/// 澄清后（一轮问答，用户选「整条栏 + 更大容差」+「任意移动都重新计时，停住 2 秒才淡出」）
/// 钉住这几条语义（⚠️ 延时在**第二十七轮**从 2 秒收到 **1 秒**，下面正文写的是收到之后的口径）：
/// 1. 鼠标落进**顶部标题栏热区**（栏高 + [kChromeHotZoneSlack]）或**底部控制栏热区**
///    → 两条栏立即显现，并把 1 秒隐藏计时**重新开始**（指针压在栏上/贴着栏游走不会淡出）；
/// 2. 在画面中间移动鼠标 → **不显示**它们（第十四轮的语义不变），但把 1 秒计时**重新开始**
///    —— 这就是"鼠标不动时才隐藏"：人还在窗口里动，两条栏不该在他动的时候自己淡掉；
/// 3. 鼠标移出窗口 → 排定 1 秒后淡出（**不是**立刻消失）；
/// 4. 尺寸判据失真（未布局 / `Size.zero`）→ 什么都不做，绝不误唤醒。
///
/// ⚠️ **为什么只验到纯函数这一层（`playerChromeHotZoneHit` / `playerChromeMoveEffect`），
/// 没有 `PlayerSurface` 的 widget 级用例**：
/// 让 `PlayerSurface` 真的 build 出 chrome，需要 `playerProvider` 注入一个可用的
/// `PlayerController`；而 `lib/controllers/player_controller.dart` 里 `player` 是
/// **写死的** `final Player player = Player(configuration: …)`、`video` 是
/// `late final VideoController video = VideoController(player)` —— 没有任何注入缝。
/// 假实现只能 `implements PlayerController`，但它一被 build 读到 `controller.video`
/// （`VideoStage` → `Video(controller: …)`）就要 media_kit_video 的原生纹理，
/// 也就是**在测试里起引擎/解码器**，与这条用例的约束（不联网、不起引擎/播放器）冲突；
/// 而 `PlayerSurface.build` 拿不到注入实例时会直接退化成空态占位面，
/// 那种"能跑但什么都没验"的绿是假通过，宁可不写。
/// 所以：本需求的核心规则钉在**热区判定 + 位置效果**这两个纯函数上（它们正是
/// `onHover` / `onExit` 唯一调用的一对函数），widget 层只留一次"结果 → 状态"的
/// switch（`_PlayerSurfaceState._applyChromeEffect`）。
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/theme_tokens.dart';
import 'package:shikiin/widgets/player_surface.dart';

/// 播放器自绘标题栏的真实高度（`TitleBar` 里读的就是这个常量）。
const double _topH = ThemeTokens.titleBarHeight;

/// 控制栏 token 高度（`ControlBar` 里 `SizedBox(height: t.controlHeight)`）。
///
/// 用 `final` 而不是 `const`：Dart 的常量表达式不允许对常量对象做属性访问
/// （`ThemeTokens.fallback.controlHeight` 不是 const 表达式），但仍从这里读，
/// 宿主一旦调大 token，用例的期望值跟着走。
final double _bottomH = ThemeTokens.fallback.controlHeight;

/// 一个常见的弹出播放窗口尺寸（真机 462×260 一档）。
const double _winWidth = 462;
const Size _win = Size(_winWidth, 260);

/// 默认参数下问一次"这一点命中热区吗"。
bool _hit(Offset p, {Size size = _win, double slack = kChromeHotZoneSlack}) =>
    playerChromeHotZoneHit(p, size,
        topHeight: _topH, bottomHeight: _bottomH, slack: slack);

/// 默认参数下问一次"指针在这里移动一下之后两条栏该做什么"。
PlayerChromeMoveEffect _move(
  Offset p, {
  Size size = _win,
  bool inWindow = true,
  bool overlayOpen = false,
  double slack = kChromeHotZoneSlack,
  bool revealCenter = false,
}) =>
    playerChromeMoveEffect(
      p,
      size,
      inWindow: inWindow,
      overlayOpen: overlayOpen,
      topHeight: _topH,
      bottomHeight: _bottomH,
      slack: slack,
      revealCenter: revealCenter,
    );

void main() {
  group('playerChromeHotZoneHit：上下热区的几何边界', () {
    test('容差常量的**值**被钉住：kChromeHotZoneSlack = 28', () {
      // ⚠️ 为什么单独钉一个常量：下面所有边界用例都用 `kChromeHotZoneSlack` 本身做期望，
      // 于是"把 28 悄悄改回 4"（用户这一轮要的正是"热区给大一点"）不会让任何用例变红 ——
      // 独立审查实测过：28 改回 4，全部用例照样绿。这条守住需求本身。
      expect(kChromeHotZoneSlack, 28, reason: '用户选的是「整条栏 + 更大容差」：4 → 28');
      // 顺带钉一个"这个窗口里中带仍然存在"的前提（容差再大也没把画面中间吃光）。
      expect(_topH + kChromeHotZoneSlack + 1,
          lessThan(_win.height - _bottomH - kChromeHotZoneSlack - 1));
    });

    test('顶部：热区内任意一点都命中（含 x 边界 0 / width）', () {
      expect(_hit(const Offset(0, 0)), isTrue);
      expect(_hit(const Offset(231, 12)), isTrue);
      expect(_hit(const Offset(_winWidth, _topH)), isTrue, reason: 'x = width 仍算在窗口内（闭区间）');
    });

    test('顶部：正好等于 topHeight 命中（`<=`，不是 `<`）', () {
      expect(
        playerChromeHotZoneHit(const Offset(200, _topH), _win,
            topHeight: _topH, bottomHeight: _bottomH, slack: 0),
        isTrue,
      );
    });

    test('顶部：slack=0 时超出 1px 就不命中；默认容差下仍算命中（容差的意义）', () {
      const Offset justBelowTop = Offset(200, _topH + 1);
      expect(
        playerChromeHotZoneHit(justBelowTop, _win,
            topHeight: _topH, bottomHeight: _bottomH, slack: 0),
        isFalse,
      );
      expect(_hit(justBelowTop), isTrue, reason: '默认 slack = $kChromeHotZoneSlack');
      // 容差之外（topHeight + slack + 1）无论如何都不算顶部热区。
      expect(_hit(Offset(200, _topH + kChromeHotZoneSlack + 1)), isFalse);
    });

    test('底部：与顶部对称（热区内命中、正好压线命中、差 1px 不命中）', () {
      expect(_hit(Offset(200, _win.height - 1)), isTrue);
      expect(_hit(Offset(200, _win.height)), isTrue, reason: 'y = height 是窗口下边界，仍算底部热区');
      expect(
        playerChromeHotZoneHit(Offset(200, _win.height - _bottomH), _win,
            topHeight: _topH, bottomHeight: _bottomH, slack: 0),
        isTrue,
      );
      expect(
        playerChromeHotZoneHit(Offset(200, _win.height - _bottomH - 1), _win,
            topHeight: _topH, bottomHeight: _bottomH, slack: 0),
        isFalse,
      );
      expect(
        playerChromeHotZoneHit(Offset(200, _win.height - _bottomH - 3), _win,
            topHeight: _topH, bottomHeight: _bottomH, slack: 0),
        isFalse,
        reason: 'slack=0 时必须失效（严格边界）',
      );
    });

    test('容差内贴着栏也算命中（第二十六轮："鼠标在热区内就会保持显现"）', () {
      // 栏的**下沿**（topHeight）之下、容差之内：用户心里"我还在栏上"。
      expect(_hit(Offset(200, _topH + 1)), isTrue);
      expect(_hit(Offset(200, _topH + kChromeHotZoneSlack)), isTrue, reason: '正好等于容差仍命中');
      // 底部控制栏**上沿**之上、容差之内：控制栏实际还带着 spacing/2 的上下内边距。
      final double controlTop = _win.height - _bottomH;
      expect(_hit(Offset(200, controlTop - 1)), isTrue);
      expect(_hit(Offset(200, controlTop - kChromeHotZoneSlack)), isTrue);
    });

    test('画面中间：逐像素扫一遍整条中带，一个点都不许命中（用户第十四轮要改掉的就是这里）', () {
      // 中带 = 顶部热区（含容差）之下、底部热区（含容差）之上。
      final double firstMid = _topH + kChromeHotZoneSlack + 1;
      final double lastMid = _win.height - _bottomH - kChromeHotZoneSlack - 1;
      expect(
        lastMid,
        greaterThan(firstMid),
        reason: '用例前提：这个窗口真有"中间带"（容差再大也没把中带挤没）',
      );
      for (double y = firstMid; y <= lastMid; y += 1) {
        expect(_hit(Offset(200, y)), isFalse, reason: 'y = $y 在画面中间，不该唤起两条栏');
      }
    });

    test('横向越界不命中（否则窗口外的正上方会被算成顶部热区）', () {
      expect(_hit(const Offset(-1, 10)), isFalse);
      expect(_hit(const Offset(-0.5, 10)), isFalse);
      expect(_hit(Offset(_win.width + 0.5, 10)), isFalse);
      expect(_hit(Offset(_win.width + 1, 10)), isFalse);
      // 纵向在底部热区、横向却在窗口外：同样不命中。
      expect(_hit(Offset(-1, _win.height - 2)), isFalse);
      expect(_hit(Offset(_win.width + 1, _win.height - 2)), isFalse);
    });

    test('负的 dy 命中顶部热区（指针从窗口上边缘外侧进来时的坐标）', () {
      expect(_hit(const Offset(200, -1)), isTrue);
      expect(_hit(const Offset(200, -50)), isTrue);
    });

    test('size 为 0 → 一律不命中（否则 dy >= 0 - bottomHeight 对任何点都成立）', () {
      const Size empty = Size.zero;
      expect(_hit(Offset.zero, size: empty), isFalse);
      expect(_hit(const Offset(10, 10), size: empty), isFalse);
      expect(_hit(const Offset(0, -5), size: empty), isFalse);
    });

    test('size.height == 0 / width == 0 / 负尺寸 → 一律不命中', () {
      const Size flat = Size(462, 0);
      expect(_hit(const Offset(10, 0), size: flat), isFalse);
      expect(_hit(const Offset(10, 100), size: flat), isFalse);
      const Size narrow = Size(0, 260);
      expect(_hit(const Offset(0, 0), size: narrow), isFalse);
      expect(_hit(const Offset(0, 259), size: narrow), isFalse);
      const Size broken = Size(-10, -10);
      expect(_hit(const Offset(-1, -1), size: broken), isFalse);
    });

    test('热区高度为 0 → 该侧退化成"只有压线那一条"（不会整条窗口都命中）', () {
      // 顶部热区高度 0、slack 0：只有 dy == 0 命中。
      expect(
        playerChromeHotZoneHit(const Offset(200, 0), _win,
            topHeight: 0, bottomHeight: 0, slack: 0),
        isTrue,
      );
      expect(
        playerChromeHotZoneHit(const Offset(200, 1), _win,
            topHeight: 0, bottomHeight: 0, slack: 0),
        isFalse,
      );
    });
  });

  group('playerChromeMoveEffect：指针在这里动一下，两条栏该做什么', () {
    test('在热区里 → reveal（立即显示并重新计时）', () {
      expect(_move(const Offset(220, 20)), PlayerChromeMoveEffect.reveal);
      expect(_move(Offset(220, _win.height - 6)), PlayerChromeMoveEffect.reveal);
    });

    test('容差内贴着两条栏 → 仍然 reveal（"鼠标在热区内就会保持显现"）', () {
      expect(_move(Offset(220, _topH + kChromeHotZoneSlack)), PlayerChromeMoveEffect.reveal);
      expect(
        _move(Offset(220, _win.height - _bottomH - kChromeHotZoneSlack)),
        PlayerChromeMoveEffect.reveal,
      );
    });

    test('在画面中间动 → restart（不显示，但重新计时 = "鼠标不动时才隐藏"）', () {
      expect(_move(const Offset(220, 130)), PlayerChromeMoveEffect.restart);
    });

    test('浮层（播放列表 / 设置）打开 → 画面中间也算 reveal（在列表里怎么动都续命）', () {
      expect(_move(const Offset(220, 130), overlayOpen: true), PlayerChromeMoveEffect.reveal);
    });

    test('移出窗口 → scheduleHide（1 秒后淡出，不是立刻消失）', () {
      expect(
        _move(const Offset(220, 130), inWindow: false),
        PlayerChromeMoveEffect.scheduleHide,
      );
      // 从热区移出窗口也一样：不是立刻消失，而是排定 1 秒。
      expect(
        _move(const Offset(220, 20), inWindow: false),
        PlayerChromeMoveEffect.scheduleHide,
      );
    });

    test('拿不到尺寸（未布局 / Size.zero）→ ignore（宁可不动也不误唤醒）', () {
      expect(_move(Offset.zero, size: Size.zero), PlayerChromeMoveEffect.ignore);
      expect(_move(const Offset(220, 20), size: Size.zero), PlayerChromeMoveEffect.ignore);
      // 尺寸失真时，就算指针在窗口外也什么都不做（判据不可信）。
      expect(
        _move(Offset.zero, size: Size.zero, inWindow: false),
        PlayerChromeMoveEffect.ignore,
      );
    });
  });

  group('playerChromeRevealHit：几何判定 + 浮层例外', () {
    test('浮层关着 → 与几何判定完全一致（画面中间不命中、两条栏命中）', () {
      bool reveal(Offset p) => playerChromeRevealHit(
            p,
            _win,
            overlayOpen: false,
            topHeight: _topH,
            bottomHeight: _bottomH,
          );
      expect(reveal(const Offset(220, 20)), isTrue);
      expect(reveal(const Offset(220, 130)), isFalse);
      expect(reveal(const Offset(220, 240)), isTrue);
    });

    test('浮层打开 → 画面正中间也算命中（列表里怎么动都续命）', () {
      expect(
        playerChromeRevealHit(
          const Offset(220, 130),
          _win,
          overlayOpen: true,
          topHeight: _topH,
          bottomHeight: _bottomH,
        ),
        isTrue,
      );
    });

    test('浮层打开 + 拿不到尺寸（Size.zero，widget 里 context.size 为空）→ 仍然命中', () {
      expect(
        playerChromeRevealHit(
          Offset.zero,
          Size.zero,
          overlayOpen: true,
          topHeight: _topH,
          bottomHeight: _bottomH,
        ),
        isTrue,
      );
      // 反过来：拿不到尺寸 + 没浮层 → 不命中（宁可不动也不误唤醒）。
      expect(
        playerChromeRevealHit(
          Offset.zero,
          Size.zero,
          overlayOpen: false,
          topHeight: _topH,
          bottomHeight: _bottomH,
        ),
        isFalse,
      );
    });
  });

  group('playerChromeShouldHide：1 秒计时跑到头了，这次该不该真隐藏', () {
    // 这一组守的是**独立审查抓到的那处缺陷**：`onHover` 只在指针移动时触发，
    // 「停在标题栏/控制栏上不动」期间一条 hover 都不会来、计时照样跑到头 ——
    // 只看"计时跑满"会把**还压在栏上的指针**判成"停住了"，两条栏在用户手底下淡出，
    // 而淡出的标题栏仍然可点（✕ / 最大化 / 拖拽区）、光标还变成 `none`。
    test('指针压在热区里 → 不隐藏（"鼠标在热区内就会保持显现"）', () {
      expect(
        playerChromeShouldHide(hasMedia: true, overlayOpen: false, pointerInHotZone: true),
        isFalse,
        reason: '停在标题栏/控制栏上不动超过 1 秒也不许淡出',
      );
    });

    test('指针不在热区（画面中间停住）→ 隐藏（"鼠标不动时才隐藏"）', () {
      expect(
        playerChromeShouldHide(hasMedia: true, overlayOpen: false, pointerInHotZone: false),
        isTrue,
      );
    });

    test('设置浮层开着 → 不隐藏（挂起语义）', () {
      expect(
        playerChromeShouldHide(hasMedia: true, overlayOpen: true, pointerInHotZone: false),
        isFalse,
      );
    });

    test('空态（没载入媒体）→ 不隐藏（chrome 常驻）', () {
      expect(
        playerChromeShouldHide(hasMedia: false, overlayOpen: false, pointerInHotZone: false),
        isFalse,
      );
    });
  });

  group('第二十七轮：宿主的「画面正中也唤起」开关（revealCenter）', () {
    test('关着（默认）→ 画面中间只续命不显示：第十四/二十六轮的语义不变', () {
      expect(_move(const Offset(220, 130)), PlayerChromeMoveEffect.restart);
      expect(_move(const Offset(220, 130), revealCenter: false), PlayerChromeMoveEffect.restart);
    });

    test('打开 → 窗口里**任何**位置动一下都 reveal（画面正中也不例外）', () {
      expect(_move(const Offset(220, 130), revealCenter: true), PlayerChromeMoveEffect.reveal);
      expect(_move(const Offset(60, 40), revealCenter: true), PlayerChromeMoveEffect.reveal);
      // 热区里当然还是 reveal（开关只是把范围放大，不改热区语义）。
      expect(_move(const Offset(220, 20), revealCenter: true), PlayerChromeMoveEffect.reveal);
    });

    test('打开也不改变"移出窗口"与"尺寸失真"两条：scheduleHide / ignore', () {
      expect(
        _move(const Offset(220, 130), inWindow: false, revealCenter: true),
        PlayerChromeMoveEffect.scheduleHide,
        reason: '指针已经不在窗口里了，不该因为开关而"显示"',
      );
      expect(
        _move(Offset.zero, size: Size.zero, revealCenter: true),
        PlayerChromeMoveEffect.ignore,
      );
    });
  });

  group('第二十七轮：两条栏的淡出延时（kChromeAutoHideMs）', () {
    test('常量本身被钉住：1000ms（用户「淡出时间减少一秒」，2 秒 → 1 秒）', () {
      // 为什么单钉一个常量：延时是"跑满一秒"这种**不可观测**的行为，
      // 期望值若也用同一个常量，改回 2000 时用例照样全绿（第二十六轮审查的教训）。
      expect(kChromeAutoHideMs, 1000);
    });
  });

  group('整条鼠标轨迹（判定 + 效果串起来）', () {
    /// 把一次指针轨迹喂成效果列表（`inWindow: false` = 移出窗口那一步）。
    List<PlayerChromeMoveEffect> trace(List<(Offset, bool)> moves) => <PlayerChromeMoveEffect>[
          for (final (Offset p, bool inWindow) in moves)
            _move(p, inWindow: inWindow),
        ];

    test('中间游走 → 进顶部热区 → 回中间继续动 → 移出窗口：中间只续命、热区才显示', () {
      final List<PlayerChromeMoveEffect> effects = trace(<(Offset, bool)>[
        // ① 鼠标在画面中间游走：**不显示**，但每一步都重新计时（用户第二十六轮）。
        (const Offset(200, 130), true),
        (const Offset(240, 140), true),
        (const Offset(220, 150), true),
        // ② 向上移进标题栏热区：显示。
        (const Offset(220, 20), true),
        (const Offset(200, 8), true),
        // ③ 移回画面中间：不显示，继续续命（不是"排定隐藏后就不管了"）。
        (const Offset(210, 120), true),
        (const Offset(230, 130), true),
        // ④ 鼠标移出窗口：这一步才开始倒数 1 秒。
        (const Offset(250, 160), false),
      ]);

      expect(effects, const <PlayerChromeMoveEffect>[
        PlayerChromeMoveEffect.restart,
        PlayerChromeMoveEffect.restart,
        PlayerChromeMoveEffect.restart,
        PlayerChromeMoveEffect.reveal,
        PlayerChromeMoveEffect.reveal,
        PlayerChromeMoveEffect.restart,
        PlayerChromeMoveEffect.restart,
        PlayerChromeMoveEffect.scheduleHide,
      ]);
    });

    test('贴着控制栏下沿来回磨 → 全程 reveal（栏不会在鼠标压着栏时淡出）', () {
      final List<PlayerChromeMoveEffect> effects = trace(<(Offset, bool)>[
        (Offset(120, _win.height - _bottomH - 2), true),
        (Offset(140, _win.height - _bottomH + 1), true),
        (Offset(160, _win.height - 4), true),
        (Offset(180, _win.height), true),
      ]);
      expect(
        effects,
        everyElement(PlayerChromeMoveEffect.reveal),
        reason: '指针一直压在/贴着控制栏：每一步都必须重新计时并保持显现',
      );
    });

    test('从底部控制栏滑出去（先到热区、再移出窗口）→ 先 reveal 后 scheduleHide', () {
      expect(
        trace(<(Offset, bool)>[
          (Offset(200, _win.height - 6), true),
          (Offset(200, _win.height - 6), false),
        ]),
        const <PlayerChromeMoveEffect>[
          PlayerChromeMoveEffect.reveal,
          PlayerChromeMoveEffect.scheduleHide,
        ],
      );
    });
  });
}
