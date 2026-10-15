/// 播放窗口落点单测。
///
/// 用户 2026-10-12（第七轮）：「点开播放后为什么会取消主窗口的最大化，还有播放器
/// 应该在中心位置出现。」—— 于是默认落点回到**工作区正中**，而且**不再动主窗口**。
///
/// 这个文件同时把前几轮的教训钉住（都是真机踩出来的）：
/// * 第四轮：播放窗口大到 100% 盖住主窗口 → 用户「整个程序都不能用了」；
/// * 第五轮：给播放窗口封顶 → 全屏与拖右边框一起被 `ptMaxTrackSize` 夹死；
/// * 第六轮：为了腾地方把主窗口从最大化降回还原尺寸 → 用户这次报的正是它。
library;

import 'package:dsanima/domain/window_placement.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真机（2026-10-11 实测）：2560×1600 @125%，任务栏 60 → 工作区 2048×1232 **逻辑像素**；
/// 主窗口 1100×680（逻辑）居中。
const Rect kWorkAreaReal = Rect.fromLTWH(0, 0, 2048, 1232);
const Rect kMainReal = Rect.fromLTWH(474, 276, 1100, 680);

/// 完整落在工作区内。
void expectInside(Rect player, Rect area) {
  expect(player.left, greaterThanOrEqualTo(area.left - 0.5));
  expect(player.top, greaterThanOrEqualTo(area.top - 0.5));
  expect(player.right, lessThanOrEqualTo(area.right + 0.5));
  expect(player.bottom, lessThanOrEqualTo(area.bottom + 0.5));
}

/// 水平垂直都居中（允许半像素浮点误差）。
void expectCentered(Rect player, Rect area) {
  expect(player.center.dx, closeTo(area.center.dx, 0.5), reason: '水平居中');
  expect(player.center.dy, closeTo(area.center.dy, 0.5), reason: '垂直居中');
}

void main() {
  group('centeredPlayerWindowBounds（用户 2026-10-12：播放器要在中心位置）', () {
    test('真机那台：960×540 正中落在工作区中央', () {
      final Rect player = centeredPlayerWindowBounds(workArea: kWorkAreaReal);
      // 工作区 2048×1232 比首选尺寸大得多，所以尺寸就是首选尺寸本身。
      expect(player.size, kPlayerWindowPreferredSize);
      expect(player.left, closeTo((2048 - 960) / 2, 0.5));
      expect(player.top, closeTo((1232 - 540) / 2, 0.5));
      expectCentered(player, kWorkAreaReal);
      expectInside(player, kWorkAreaReal);
      expect(player.width / player.height,
          closeTo(16 / 9, 0.01), reason: '16:9，不许拉成怪比例让画面出黑边');
    });

    test('不管主窗口在哪，落点都一样（我们不再为了避开它而挪窝）', () {
      // 这正是第六轮"算一个不盖住主窗口的落点"的反面：落点只由工作区决定，
      // 主窗口最大化还是普通窗口，播放窗口都出现在同一个中心位置。
      final Rect a = centeredPlayerWindowBounds(workArea: kWorkAreaReal);
      const Rect maxed = Rect.fromLTWH(-7, -7, 2062, 1246); // 真机最大化那份矩形
      expect(kWorkAreaReal.contains(a.center), isTrue);
      expect(maxed.contains(a.center), isTrue,
          reason: '居中就意味着会压在主窗口身上 —— 这是用户明确要的（可拖动、可关）');
    });

    test('小工作区：按 80% 等比缩，仍然居中', () {
      const Rect area = Rect.fromLTWH(0, 0, 1000, 700);
      final Rect player = centeredPlayerWindowBounds(workArea: area);
      // 0.8 × 1000 = 800 是较紧的那一边 → 800×450。
      expect(player.width, closeTo(800, 0.5));
      expect(player.height, closeTo(450, 0.5));
      expect(player.width / player.height, closeTo(16 / 9, 0.01));
      expectCentered(player, area);
      expectInside(player, area);
    });

    test('工作区比首选尺寸还小 → 缩到 80% 以内，不铺满', () {
      const Rect area = Rect.fromLTWH(0, 0, 1024, 600);
      final Rect player = centeredPlayerWindowBounds(workArea: area);
      expect(player.width, lessThanOrEqualTo(1024 * kPlayerWindowMaxAreaRatio + 0.5));
      expect(player.height, lessThanOrEqualTo(600 * kPlayerWindowMaxAreaRatio + 0.5));
      expect(player.width / player.height, closeTo(16 / 9, 0.01));
      expectCentered(player, area);
      expectInside(player, area);
    });

    test('工作区极小（比最小尺寸还小）→ 抬到最小尺寸但绝不超出工作区', () {
      const Rect area = Rect.fromLTWH(0, 0, 300, 200);
      final Rect player = centeredPlayerWindowBounds(workArea: area);
      expect(player.width, greaterThan(0));
      expect(player.height, greaterThan(0));
      expectInside(player, area);
    });

    test('矩形反着给（负宽高）→ 先归一化再算，不出现负尺寸', () {
      final Rect player = centeredPlayerWindowBounds(
        workArea: const Rect.fromLTRB(1000, 800, 0, 0), // 反着给：右下 → 左上
      );
      expect(player.width, greaterThan(0));
      expect(player.height, greaterThan(0));
      expectInside(player, const Rect.fromLTWH(0, 0, 1000, 800));
    });

    test('工作区还没测出来（0×0）→ 不崩，交给系统居中', () {
      final Rect player = centeredPlayerWindowBounds(
        workArea: const Rect.fromLTWH(0, 0, 0, 0),
      );
      expect(player.size, kPlayerWindowPreferredSize);
    });

    test('多显示器：副屏工作区带偏移，播放窗口居中在那块屏上', () {
      final Rect area = workAreaFor(
        <({Offset position, Size size})>[
          (position: const Offset(0, 0), size: const Size(2560, 1392)),
          (position: const Offset(2560, 0), size: const Size(1920, 1040)),
        ],
        const Offset(3000, 400),
      );
      expect(area, const Rect.fromLTWH(2560, 0, 1920, 1040));
      final Rect player = centeredPlayerWindowBounds(workArea: area);
      expect(player.left, greaterThanOrEqualTo(2560), reason: '不许跑到主显示器去');
      expectCentered(player, area);
    });

    // ── 第五轮的教训：不许再把尺寸上限加回来 ────────────────────────────────
    //
    // 原来靠 `playerWindowMaxSize()` 给播放窗口封顶（= 落点那条空地 462×260）。
    // 那把锁落到原生 `WM_GETMINMAXINFO` 的 `ptMaxTrackSize`，而 `ptMaxTrackSize`
    // **连 `SetWindowPos` 一起夹** —— 全屏就是 `SetWindowPos` 到显示器尺寸，
    // 于是全屏与拖右边框都被锁死在 462×260（本机 Win32 实测坐实）。

    test('开窗计划**不带尺寸上限**（带回来 = 全屏和拖边框重新被夹死）', () {
      final Rect box = centeredPlayerWindowBounds(workArea: kWorkAreaReal);
      final PlayerWindowPlan plan = PlayerWindowPlan(bounds: box);
      expect(plan.bounds, box);
      // 尺寸上限是"删掉的能力"，不是"改成 null"：计划里根本没有这个字段。
      expect(plan.toString(), isNot(contains('maxSize')));
    });

    test('默认落点远小于整块工作区（全屏那一下必须还有地方长）', () {
      final Rect player = centeredPlayerWindowBounds(workArea: kWorkAreaReal);
      expect(kWorkAreaReal.width, greaterThan(player.width));
      expect(kWorkAreaReal.height, greaterThan(player.height));
    });
  });

  // ── 记住的落点能不能直接用（store 里可能躺着坏记录）────────────────────────
  //
  // 2026-10-12 起判据只剩两条：**在工作区内 + 不太小**。
  // 「不许盖住主窗口 / 不许压标题栏」两条被删掉了 —— 用户要播放器居中弹出，
  // 居中本来就压在最大化的主窗口上；继续留着那两条，等于用户每拖一次位置都被否决、
  // 每次都跳回中心。

  test('记住的落点：用户自己拖出来的位置 → 照用', () {
    const Rect saved = Rect.fromLTWH(1600, 300, 420, 240);
    expect(reusableSavedBounds(saved: saved, workArea: kWorkAreaReal), isTrue);
  });

  test('记住的落点：压在主窗口上（甚至盖住它的标题栏）→ 照用，不再否决', () {
    // 这两条在 2026-10-11 会被否掉（"盖住主窗口"/"压标题栏"）；现在它们只是
    // "居中的自然结果"，再否决就变成"用户拖了也白拖"。
    const Rect heavy = Rect.fromLTWH(300, 276, 724, 680); // 压住主窗口左半
    expect(reusableSavedBounds(saved: heavy, workArea: kWorkAreaReal), isTrue);
    const Rect overTitle = Rect.fromLTWH(154, 196, 560, 320); // 压住标题栏一角
    expect(reusableSavedBounds(saved: overTitle, workArea: kWorkAreaReal), isTrue);
  });

  test('记住的落点：跑到工作区外的旧记录 → 否决', () {
    const Rect outside = Rect.fromLTWH(2200, 100, 400, 240); // 屏只有 2048 宽
    expect(reusableSavedBounds(saved: outside, workArea: kWorkAreaReal), isFalse);
    // 真机那条"主窗口最大化时的播放窗口矩形"：-7,-7 起手就越界。
    const Rect maxed = Rect.fromLTWH(-7, -7, 2062, 1246);
    expect(reusableSavedBounds(saved: maxed, workArea: kWorkAreaReal), isFalse);
  });

  test('记住的落点：小于最小尺寸 → 否决（重算一个够大的）', () {
    // 第五轮之前 store 里可能是 462×260 甚至更小 —— 那不是用户选的，
    // 是被 `ptMaxTrackSize` 锁死的结果。现在下限就是 kPlayerWindowMinSize(400×240)。
    const Rect tiny = Rect.fromLTWH(1586, 276, 400, 225);
    expect(reusableSavedBounds(saved: tiny, workArea: kWorkAreaReal), isFalse);
    const Rect ok = Rect.fromLTWH(1586, 276, 400, 240);
    expect(reusableSavedBounds(saved: ok, workArea: kWorkAreaReal), isTrue);
  });

  test('记住的落点：给空/反向矩形 → 一律否决', () {
    expect(
      reusableSavedBounds(
        saved: const Rect.fromLTWH(100, 100, 0, 0),
        workArea: kWorkAreaReal,
      ),
      isFalse,
    );
  });
}
