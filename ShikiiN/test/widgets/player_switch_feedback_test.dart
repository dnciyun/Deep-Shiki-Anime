/// 切集反馈（第三十八轮）。
///
/// 用户原话：「优化反馈，点击下一集或上一集都没实质性反馈」。跨种子的播放列表里，
/// 其它集还没进引擎 —— 点下去要等「补磁力 → `addMagnet` 等元数据」，慢的时候几十秒，
/// 而这一段时间原本画面上什么都不发生（用户看到的就是"点了没反应"）。
///
/// ⚠️ 这里**只钉判定规则**（`playerSwitchFeedback` / `playerSwitchWaitingText`），
/// 不挂 `PlayerSurface`：让它真的 build 就要 `playerProvider` 注入可用的
/// `PlayerController`，而那条路一 build 到 `VideoStage` 就要 media_kit 的原生纹理
/// （= 测试里起解码器）。这与 `player_chrome_hotzone_test.dart` 顶部记的是同一件事，
/// 所以规则同样抽成纯函数来守。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/episode_switch_notice.dart';
import 'package:shikiin/widgets/player_surface.dart';

final DateTime _t0 = DateTime(2026, 10, 16, 12);

PlayerSwitchFeedback _fb({
  String? pending,
  DateTime? startedAt,
  String? localError,
  String? localHint,
  EpisodeSwitchNotice? notice,
  EpisodeSwitchNotice? dismissed,
  DateTime? now,
}) =>
    playerSwitchFeedback(
      pendingTitle: pending,
      startedAt: startedAt,
      localError: localError,
      localHint: localHint,
      notice: notice,
      dismissed: dismissed,
      now: now ?? _t0,
    );

void main() {
  group('切集反馈层：显示什么', () {
    test('什么都没发生 → 不显示（不占屏）', () {
      expect(_fb().visible, isFalse);
    });

    test('点下去那一刻就有反馈：显示集名 + 已等 0 秒', () {
      final PlayerSwitchFeedback fb = _fb(pending: '某番 - 05', startedAt: _t0);
      expect(fb.visible, isTrue);
      expect(fb.pendingTitle, '某番 - 05');
      expect(fb.waitedSeconds, 0);
      expect(fb.error, isNull);
    });

    test('等待秒数跟着时间走（数字在动才叫"有反馈"）', () {
      expect(
        _fb(pending: '某番 - 05', startedAt: _t0, now: _t0.add(const Duration(seconds: 3)))
            .waitedSeconds,
        3,
      );
      // 时钟回拨/开始时间在未来：夹到 0，不许出现负数秒。
      expect(
        _fb(pending: '某番 - 05', startedAt: _t0, now: _t0.subtract(const Duration(seconds: 5)))
            .waitedSeconds,
        0,
      );
    });

    test('8 秒前后换一句话：先"正在补磁力"，之后解释为什么这么慢', () {
      expect(playerSwitchWaitingText(0), contains('已等 0 秒'));
      expect(playerSwitchWaitingText(7), contains('正在补磁力'));
      expect(playerSwitchWaitingText(8), contains('已经等了 8 秒'));
      expect(playerSwitchWaitingText(8), contains('元数据'));
    });

    test('宿主推来的失败：原因 + 怎么办，等待层让位', () {
      final PlayerSwitchFeedback fb = _fb(
        pending: '某番 - 05',
        startedAt: _t0,
        notice: const EpisodeSwitchNotice(message: '这条结果没有磁力链', hint: '换一条带磁力的'),
        now: _t0.add(const Duration(seconds: 12)),
      );
      expect(fb.visible, isTrue);
      expect(fb.pendingTitle, isNull, reason: '失败之后不该还写着"正在切到…"');
      expect(fb.error, '这条结果没有磁力链');
      expect(fb.hint, '换一条带磁力的');
    });

    test('本地打开失败优先于宿主通知（画面这边知道的更直接）', () {
      final PlayerSwitchFeedback fb = _fb(
        localError: '打不开这一集：boom',
        localHint: '地址可能失效',
        notice: const EpisodeSwitchNotice(message: '宿主说：没有磁力链', hint: '换一条'),
      );
      expect(fb.error, '打不开这一集：boom');
      expect(fb.hint, '地址可能失效');
    });

    test('按 ✕ 关掉的那一条不再显示；宿主的**下一条**照常显示', () {
      const EpisodeSwitchNotice first = EpisodeSwitchNotice(message: '第一条失败');
      expect(_fb(notice: first, dismissed: first).visible, isFalse);
      expect(_fb(notice: first).visible, isTrue);
      // 内容不同的新一条：不是同一个对象 ⇒ 照常弹（否则"关过一次就再也不提示了"）。
      expect(
        _fb(notice: const EpisodeSwitchNotice(message: '第二条失败'), dismissed: first).visible,
        isTrue,
      );
    });

    test('没有失败也没有等待时，通知为空 → 不显示', () {
      expect(_fb(notice: null, dismissed: null).visible, isFalse);
    });
  });
}
