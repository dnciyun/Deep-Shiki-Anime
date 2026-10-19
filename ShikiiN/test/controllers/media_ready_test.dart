/// `waitUntilMediaReady`：这次的文件真的加载好了吗？
///
/// 它守的是「续播 seek 太早被 mpv 丢掉」这条真机 bug（用户 2026-10-18：
/// 「点的继续播放会不生效」）。真机日志 2026-10-18 17:22:20 一字不差：
///
/// ```text
/// BREADCRUMB app open request: http://127.0.0.1:…/stream?token=…
/// BREADCRUMB app open: …
/// ERROR mpv [media_kit] error: error running command _command(seek, 10.0100, absolute)
/// ```
///
/// `open()` 只把 `loadlist` 交给 mpv 就返回（见 media_kit `native/player/real.dart`），
/// 紧接着的 `seek` 撞上"还没有文件"→ mpv 报错并**丢掉这次 seek** ⇒ 从 0 开始播。
///
/// 真实播放器在单测里造不出来（要 libmpv 原生库），所以把判据做成纯函数钉在这里，
/// 再加一条源码守卫，确保 `PlayerController.open` 是「先订阅、再 open、最后 seek」。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/controllers/player_controller.dart';

void main() {
  test('duration 从 0 变成正值才算加载完成（0 不算）', () async {
    final StreamController<Duration> ctrl =
        StreamController<Duration>.broadcast();
    addTearDown(ctrl.close);
    bool done = false;
    final Future<bool> ready =
        waitUntilMediaReady(ctrl.stream, timeout: const Duration(seconds: 5))
            .then((bool value) {
      done = true;
      return value;
    });

    // `open()` 内部先 `stop(open: true)`，会往 duration 推一次 0 —— 那不算加载完。
    ctrl.add(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(done, isFalse, reason: 'duration=0 只是"换片时清空"，不是能 seek 的信号');

    ctrl.add(const Duration(minutes: 23, seconds: 40));
    expect(await ready, isTrue);
  });

  test('一直等不到（直播没有时长）→ 超时返回 false，不抛', () async {
    final StreamController<Duration> ctrl =
        StreamController<Duration>.broadcast();
    addTearDown(ctrl.close);

    expect(
      await waitUntilMediaReady(ctrl.stream,
          timeout: const Duration(milliseconds: 30)),
      isFalse,
    );
  });

  test('流带错误 → false，不把开播拖崩', () async {
    final StreamController<Duration> ctrl =
        StreamController<Duration>.broadcast();
    addTearDown(ctrl.close);
    final Future<bool> ready =
        waitUntilMediaReady(ctrl.stream, timeout: const Duration(seconds: 5));
    ctrl.addError(StateError('mpv loadfile failed'));
    expect(await ready, isFalse);
  });

  test('PlayerController.open：先订阅就绪 → 再 open → 最后 seek（源码守卫）', () {
    final String src =
        File('lib/controllers/player_controller.dart').readAsStringSync();
    final int openStart = src.indexOf('Future<void> open(MediaItem item');
    expect(openStart, greaterThan(-1), reason: 'open() 没了？');
    final int openEnd =
        src.indexOf('\n  /// 等「下一次」视频输出重配置完成', openStart);
    expect(openEnd, greaterThan(openStart));
    final String body = src.substring(openStart, openEnd);

    final int subscribe = body.indexOf('waitUntilMediaReady(player.stream.duration)');
    final int openCall = body.indexOf('await player.open(');
    final int seekCall = body.indexOf('await player.seek(');
    expect(subscribe, greaterThan(-1),
        reason: '必须订阅 duration（broadcast 流无重放，只能在 open 前订阅）');
    expect(openCall, greaterThan(subscribe), reason: '订阅必须在 open 之前');
    expect(seekCall, greaterThan(openCall), reason: 'seek 必须在 open 之后（等加载）');
  });
}
