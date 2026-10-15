/// 「双击视频 / 二次实例转发 / 命令行带文件」这条链路的 Dart 侧单测。
///
/// 修前的断链：原生（`windows/runner/flutter_window.cpp`）一直在 `shikiin/file_open`
/// 上投递，而 Dart 侧没有任何接收方 —— `launchFile` 只写日志、
/// `PlayerRequest.fromLaunchFile` 零调用者，于是三种入口**都没反应也不报错**。
///
/// 这里用假的原生端把两个方向都钉住：Dart→原生 `ready` 握手（含就绪前暂存的路径）、
/// 原生→Dart `open` 推送、以及"宿主没实现这条通道"时的降级。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/infra/file_open_channel.dart';
import 'package:shikiin/models/player_request.dart';

const MethodChannel _channel = MethodChannel(kFileOpenChannelName);
const StandardMethodCodec _codec = StandardMethodCodec();

/// 假的原生端：记录收到的调用，`ready` 按参数返回（null = 就绪前没有暂存路径）。
List<MethodCall> _installFakeNative({String? readyResult}) {
  final List<MethodCall> calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (MethodCall call) async {
        calls.add(call);
        if (call.method == 'ready') return readyResult;
        return null;
      });
  return calls;
}

/// 模拟**原生 → Dart** 的 `InvokeMethod('open', path)`。
Future<void> _pushOpen(Object? path) async {
  final ByteData data = _codec.encodeMethodCall(MethodCall('open', path));
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(kFileOpenChannelName, data, (ByteData? _) {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 每个用例都从"没有原生端"开始：需要假原生端的用例自己装。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('ready 握手：就绪前暂存的路径（双击视频时 Dart 还没起来）会被播起来', () async {
    final List<MethodCall> calls = _installFakeNative(readyResult: r'F:\Anime\某番 - 01.mkv');

    final PlayerRequestNotifier? requests = await bindFileOpenRequests();

    expect(calls.map((MethodCall c) => c.method), <String>['ready'], reason: '启动后必须握手');
    expect(requests, isNotNull, reason: '原生端在 → 接收端必须建立');
    expect(requests!.value?.uri, r'F:\Anime\某番 - 01.mkv');
    expect(requests.value?.title, '某番 - 01', reason: '标题取文件名去掉扩展名');
  });

  test('就绪后原生推来的路径（二次实例转发）走同一条链路；同一文件再开一次也算新请求', () async {
    _installFakeNative();
    final PlayerRequestNotifier requests = (await bindFileOpenRequests())!;
    expect(requests.value, isNull, reason: '就绪前没有暂存路径');

    await _pushOpen(r'F:\Anime\A.mkv');
    expect(requests.value?.uri, r'F:\Anime\A.mkv');
    final int firstNonce = requests.value!.nonce;

    // 同一个文件第二次双击：uri 相同，必须靠 nonce 区分（否则会被去重掉、没反应）。
    await _pushOpen(r'F:\Anime\A.mkv');
    expect(requests.value?.nonce, greaterThan(firstNonce));

    await _pushOpen(r'F:\Anime\B.mkv');
    expect(requests.value?.uri, r'F:\Anime\B.mkv');
    expect(requests.value?.title, 'B');
  });

  test('命令行给的 launchFile 直接成为初始请求（不必等原生）', () async {
    _installFakeNative();
    final PlayerRequestNotifier requests =
        (await bindFileOpenRequests(launchFile: r'D:\v\ep02.mp4'))!;
    expect(requests.value?.uri, r'D:\v\ep02.mp4');
    expect(requests.value?.title, 'ep02');
  });

  test('host 没实现这条通道（MissingPluginException）→ 不抛；命令行有文件时仍给接收端', () async {
    // setUp 里已经把假原生端卸掉了 = 原生没实现。
    expect(await bindFileOpenRequests(), isNull, reason: '既没原生端也没命令行文件 → 未接通');

    final PlayerRequestNotifier? withFile =
        await bindFileOpenRequests(launchFile: r'D:\v\ep02.mp4');
    expect(withFile, isNotNull, reason: '命令行给的文件照样要能播');
    expect(withFile!.value?.uri, r'D:\v\ep02.mp4');
  });

  test('原生推来空路径 / 非字符串：忽略，不抛也不塞一个假请求', () async {
    _installFakeNative();
    final PlayerRequestNotifier requests = (await bindFileOpenRequests())!;

    await _pushOpen('');
    await _pushOpen('   ');
    await _pushOpen(42);
    expect(requests.value, isNull);
  });

  test('收到协议外的方法名 → 回「未实现」，不许把异常抛进 isolate', () async {
    _installFakeNative();
    await bindFileOpenRequests();

    final ByteData data = _codec.encodeMethodCall(const MethodCall('nonsense'));
    ByteData? reply;
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(kFileOpenChannelName, data, (ByteData? r) => reply = r);

    // MethodChannel 对方法处理器抛出的 MissingPluginException 一律回**空响应**
    // （这就是"未实现"的标准答复：Dart 侧调用方拿到它会转成 MissingPluginException）。
    // 原生那边的 `InvokeMethod("open", …)` 没有 result 回调，所以这里要的只是
    // "别把异常抛成未处理错误"。
    expect(reply, isNull, reason: '未知方法 = 未实现（空响应），而不是让异常炸掉 isolate');
  });

  test('fromLaunchFile：空串 → null；带路径 → uri 原样、标题去扩展名', () {
    expect(PlayerRequest.fromLaunchFile('  '), isNull);
    final PlayerRequest request = PlayerRequest.fromLaunchFile(r'D:\a\b\第 07 话.mkv', nonce: 3)!;
    expect(request.uri, r'D:\a\b\第 07 话.mkv');
    expect(request.title, '第 07 话');
    expect(request.nonce, 3);
  });
}
