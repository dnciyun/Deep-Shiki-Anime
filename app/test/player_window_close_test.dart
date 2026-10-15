/// 播放窗口的「关闭」路径回归测试。
///
/// 两条历史 bug 都在这条链路上，本文件把它们钉死：
/// 1. 用户 2026-10-10「关闭播放器后为什么全关了」—— 子窗口的 `onWindowClose` 里调了
///    `windowManager.destroy()`，而 `window_manager` 0.5.1 的 Windows 实现
///    （`window_manager.cpp:232`）就是 `PostQuitMessage(0)`：它把 `WM_QUIT` 投给
///    **处理这次调用的线程**（主线程），于是 `main.cpp` 的消息循环直接退出，
///    主窗口、托盘、边车一起没。
/// 2. 用户 2026-10-11「关掉播放器后不会全关掉，但是主窗口会卡死」—— 真关这一扇窗
///    会触发子窗口引擎在**主线程消息泵里**同步拆除（`FlutterWindow::OnDestroy`
///    → `flutter_controller_ = nullptr`，还要 join 子窗口的 UI 线程）。
///
/// 所以现在：**关闭 = 停播 + 收起（hide，不拆引擎）**；只有用户明确要
/// 「彻底关闭播放器」才走 destroy 那条老路。本文件钉死：
/// * 源码里再也**不许出现** `windowManager.destroy()`；
/// * 默认关闭下发的是 `hideSelf`，且不会调 `windowManager.close()`；
/// * 彻底关闭才下发 `closeSelf`（子窗口自己发 `SC_CLOSE`，只关这一扇）；
/// * 两条路都**不**下发插件没实现的 `window_close`。
library;

import 'dart:io';

import 'package:dsanima/state/player_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const MethodChannel _plugin = MethodChannel('mixin.one/desktop_multi_window');
const MethodChannel _channelBus = MethodChannel('mixin.one/desktop_multi_window/channels');

/// 源码里去掉注释行后的代码文本（注释里会引用这些名字做说明，不算违规）。
String _codeOnly(String path) => File(path)
    .readAsLinesSync()
    .where((String line) {
      final String s = line.trimLeft();
      return !s.startsWith('//') && !s.startsWith('///') && !s.startsWith('*');
    })
    .join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('源码守卫', () {
    test('子窗口里不得出现 windowManager.destroy()（它会 PostQuitMessage 干掉整个进程）', () {
      final String code = _codeOnly('lib/ui/player_window_app.dart');
      expect(
        code.contains('windowManager.destroy('),
        isFalse,
        reason:
            'window_manager 0.5.1 的 destroy() = PostQuitMessage(0)：'
            '从子窗口调它等于杀掉主消息循环。',
      );
      // 默认关闭 = 收起来（hide）；只有"彻底关闭"才 close()。
      expect(code.contains('windowManager.hide('), isTrue, reason: '默认关闭必须是把这一扇窗收起来（不拆引擎）');
      expect(code.contains('windowManager.close('), isTrue, reason: '「彻底关闭播放器」仍然要能真关这一扇窗');
      expect(code.contains('kMethodHideSelf'), isTrue);
      expect(code.contains('kMethodCloseSelf'), isTrue);
    });

    test('子窗口停下播来之前不许收窗（不能让声音留在看不见的窗口里）', () {
      final String code = _codeOnly('lib/ui/player_window_app.dart');
      // 停播失败 → 退回彻底关闭（见 _hideSelf 的分支）。
      expect(code.contains('_stopPlayback'), isTrue);
      expect(code.contains('_destroySelf'), isTrue);
      // 拦 WM_CLOSE → 自己决定收起还是关掉。
      expect(code.contains('setPreventClose(true)'), isTrue);
      expect(code.contains('setPreventClose(false)'), isTrue);
      // ✕ 走的是收起那条路。
      expect(code.contains('_OnClose(_hideSelf)'), isTrue);
    });

    test('主窗口不得再下发插件没实现的 window_close', () {
      final String code = _codeOnly('lib/state/player_window.dart');
      expect(
        code.contains("'window_close'"),
        isFalse,
        reason:
            'desktop_multi_window 0.3.1 的 Windows HandleWindowMethod 只认 '
            'window_show / window_hide，window_close 一定回 unknown method。',
      );
      expect(code.contains('kMethodCloseSelf'), isTrue);
      expect(code.contains('kMethodHideSelf'), isTrue);
      // 主窗口必须注册自己的窗口通道：子窗口收起来时要能回话（子 → 父方向）。
      expect(code.contains('setWindowMethodHandler'), isTrue);
      expect(code.contains('kMethodChildHidden'), isTrue);
    });
  });

  group('PlayerWindowService', () {
    late List<Map<Object?, Object?>> invokes;
    late List<String> liveWindows;

    setUp(() {
      invokes = <Map<Object?, Object?>>[];
      liveWindows = <String>['player-1'];
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

      messenger.setMockMethodCallHandler(_plugin, (MethodCall call) async {
        switch (call.method) {
          case 'createWindow':
            return 'player-1';
          case 'getAllWindows':
            return <Map<String, Object?>>[
              for (final String id in liveWindows)
                <String, Object?>{'windowId': id, 'windowArgument': ''},
            ];
          case 'getWindowDefinition':
            return <String, Object?>{'windowId': 'player-1', 'windowArgument': ''};
        }
        return null;
      });
      // 跨窗口通道：（channel, method, arguments）都记下来，用来断言下发的是哪个方法。
      messenger.setMockMethodCallHandler(_channelBus, (MethodCall call) async {
        if (call.method == 'invokeMethod') {
          invokes.add((call.arguments as Map).cast<Object?, Object?>());
        }
        return null;
      });
    });

    tearDown(() {
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_plugin, null);
      messenger.setMockMethodCallHandler(_channelBus, null);
    });

    Future<PlayerWindowService> opened() async {
      final PlayerWindowService service = PlayerWindowService();
      await service.bindSelf();
      await service.open(
        const PlayerWindowArgs(streamUrl: 'https://example.invalid/a.mkv', title: '第 1 集'),
      );
      return service;
    }

    test('关闭（默认）：下发 hideSelf —— 停播 + 收起，窗口与引擎都还在', () async {
      final PlayerWindowService service = await opened();
      expect(service.isOpen.value, isTrue);
      expect(service.isHidden.value, isFalse);
      invokes.clear();

      await service.hide();

      expect(invokes, hasLength(1));
      expect(invokes.single['method'], kMethodHideSelf);
      expect(invokes.single['method'], isNot('window_close'));
      expect(invokes.single['method'], isNot(kMethodCloseSelf), reason: '默认关闭绝不能真关窗（拆除期会崩/会卡主窗口）');
      expect(invokes.single['channel'], contains('player-1'));
      expect(service.isOpen.value, isTrue, reason: '窗口还在（只是隐藏）');
      expect(service.isHidden.value, isTrue);
      expect(service.hasWindow, isTrue, reason: '下次播放要复用这扇窗（秒开）');
    });

    test('被收起来后再播：复用同一扇窗（不下发 createWindow）', () async {
      final PlayerWindowService service = await opened();
      await service.hide();
      invokes.clear();

      await service.open(
        const PlayerWindowArgs(streamUrl: 'https://example.invalid/b.mkv', title: '第 2 集'),
      );

      expect(invokes.single['method'], kMethodOpen);
      expect(invokes.single['channel'], contains('player-1'));
      expect(service.isHidden.value, isFalse, reason: '重新播放 = 窗口重新显示出来');
      expect(service.currentTitle.value, '第 2 集');
    });

    test('子窗口回话 childHidden（用户点 ✕）：状态切到「已收起」', () async {
      final PlayerWindowService service = await opened();
      expect(service.isHidden.value, isFalse);

      // 子窗口自己收起来后回发的那条消息（主窗口的通道处理器接收）。
      await _invokeSelfHandler(kMethodChildHidden);

      expect(service.isOpen.value, isTrue);
      expect(service.isHidden.value, isTrue);
      expect(service.currentTitle.value, isNull);
    });

    test('彻底关闭：下发 closeSelf（不是 window_close），窗口没了就收干净状态', () async {
      final PlayerWindowService service = await opened();
      invokes.clear();
      liveWindows = <String>[]; // 关掉了：插件侧列表里没有它了

      await service.destroy();

      expect(invokes, hasLength(1));
      expect(invokes.single['method'], kMethodCloseSelf);
      expect(invokes.single['method'], isNot('window_close'));
      expect(service.isOpen.value, isFalse);
      expect(service.isHidden.value, isFalse);
      expect(service.hasWindow, isFalse);
    });

    test('彻底关闭：窗口还活着时**不**假装关了（状态保持"开着"，可以再点一次）', () async {
      final PlayerWindowService service = await opened();
      invokes.clear();

      await service.destroy();

      expect(invokes.single['method'], kMethodCloseSelf);
      expect(service.isOpen.value, isTrue, reason: '窗口列表里还有它：UI 说"已关闭"会骗人（用户再点播放会开出第二个窗口）');
      expect(service.hasWindow, isTrue);
    });
  });
}

/// 模拟「子窗口 → 主窗口」的一次调用：主窗口注册的是自己的窗口通道
/// （`mixin.one/window_controller/<自己的 id>`），插件侧会把它投给该引擎的
/// `mixin.one/desktop_multi_window/channels` 处理器，再交给注册的 handler。
Future<void> _invokeSelfHandler(String method) async {
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  await messenger.handlePlatformMessage(
    'mixin.one/desktop_multi_window/channels',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall('methodCall', <String, Object?>{
        'channel': 'mixin.one/window_controller/player-1',
        'method': method,
        'arguments': null,
      }),
    ),
    (ByteData? _) {},
  );
}
