/// 「双击视频 / 命令行带文件 / 二次实例转发」→ 播放请求这条链路（审查发现的断链）。
///
/// 原生侧（`ShikiinN/windows/runner/flutter_window.cpp`，通道 `shikiin/file_open`）：
/// * Dart 启动完成后调 `ready`；原生把**就绪之前**暂存的那条路径随返回值给回
///   （没有则返回 null），并把 `dart_ready_` 置 true；
/// * 此后二次实例经 `WM_COPYDATA`（魔数 `'SHKN'`）转发的路径由原生
///   `InvokeMethod('open', path)` 推过来。
///
/// 而修前 Dart 侧**没有任何接收方**：`AppRuntime.launchFile` 只写一行日志、
/// `PlayerRequest.fromLaunchFile` 零调用者 —— 双击视频 / 命令行传文件 / 二次实例转发
/// 全是"没反应也不报错"（静默假成功）。这里把接收端接上。
library;

import 'package:flutter/services.dart';

import '../models/player_request.dart';
import 'diagnostics/diag.dart';

/// 原生通道名（与 `windows/runner/flutter_window.cpp` 一致）。
const String kFileOpenChannelName = 'shikiin/file_open';

/// 建立接收端并完成 `ready` 握手。
///
/// 返回的 [PlayerRequestNotifier] 就是播放器的开播链路（`PlayerSurface` 监听它，
/// 见 `widgets/player_surface.dart` 的 `_onPlayerRequest`）；把它交给
/// `shikiinOverrides(..., playerRequests:)`，或直接依赖
/// [AppRuntime.fileOpenRequests]（`bootstrapPlayer` 已自动带上）。
///
/// * [launchFile]：本次进程**命令行**给的待播文件（第一个非选项参数），成为接收端的
///   初始值 —— 播放面挂载时会走既有的"补消费一次"路径打开它，不必等原生通道；
/// * 返回 null = 这个宿主既没有原生投递端、命令行也没给文件（例如 DSAnima 主窗口的
///   runner 没实现这条通道）—— 判定为"未接通"，**不抛**；
/// * 通道没接通但 [launchFile] 有效时仍返回接收端（命令行给的文件照样要能播）。
Future<PlayerRequestNotifier?> bindFileOpenRequests({
  String? launchFile,
  MethodChannel channel = const MethodChannel(kFileOpenChannelName),
}) async {
  final PlayerRequest? initial =
      launchFile == null ? null : PlayerRequest.fromLaunchFile(launchFile);
  final PlayerRequestNotifier requests = PlayerRequestNotifier(initial);
  int nonce = 0;

  void handle(Object? rawPath) {
    final String text = rawPath is String ? rawPath.trim() : '';
    if (text.isEmpty) {
      // 空路径只有一种来源：原生那边传了个空串。显式记一笔，不猜。
      diag.warn('file_open', '原生推来一个空路径，忽略');
      return;
    }
    final PlayerRequest? request = PlayerRequest.fromLaunchFile(text, nonce: ++nonce);
    if (request == null) return;
    diag.info('file_open', 'open ${request.uri}');
    requests.request(request);
  }

  channel.setMethodCallHandler((MethodCall call) async {
    if (call.method == 'open') {
      handle(call.arguments);
      return null;
    }
    // 协议只有 ready（Dart→原生）与 open（原生→Dart）两个方法：别的方法说明
    // 两边版本不一致，明确报"没实现"，让原生侧的 InvokeMethod 拿到错误而不是静默。
    throw MissingPluginException('$kFileOpenChannelName 不认的方法：${call.method}');
  });

  try {
    final String? pending = await channel.invokeMethod<String>('ready');
    handle(pending);
  } on MissingPluginException {
    // 这个宿主没有原生投递端（DSAnima 主窗口的 `app/windows/runner` 就没实现它）。
    // 解绑处理器，只留命令行那一条（如果有）。
    channel.setMethodCallHandler(null);
    diag.info(
      'file_open',
      '原生未实现 $kFileOpenChannelName：这个宿主不会转发「打开文件」'
      '${requests.value == null ? '' : '（只能用命令行给的那个文件）'}',
    );
    return requests.value == null ? null : requests;
  } catch (error, stackTrace) {
    channel.setMethodCallHandler(null);
    diag.error('file_open', 'ready 握手失败', error, stackTrace);
    return requests.value == null ? null : requests;
  }
  return requests;
}
