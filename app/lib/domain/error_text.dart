/// 错误 → 用户可读文案（中文界面统一走这里，避免各处 `e.toString()`）。
library;

import 'package:flutter/foundation.dart';

import 'ports.dart';

/// 一次失败的展示形态：发生了什么 + 怎么办 + 原始细节。
@immutable
class DsFailure {
  final String message;
  final String? hint;
  final String? detail;

  const DsFailure(this.message, {this.hint, this.detail});

  @override
  String toString() => hint == null ? message : '$message（$hint）';
}

/// 把任意异常转成「可行动」的展示文案。
DsFailure describeFailure(Object error, {StackTrace? stackTrace}) {
  if (error is PortUnavailableException) {
    return DsFailure(error.message, hint: error.hint);
  }
  final String raw = error.toString();
  // dart:io / package:http 的网络错误统一口径（不直接 import http：app 不依赖它）。
  if (raw.contains('SocketException') || raw.contains('ClientException')) {
    return DsFailure(
      '网络请求失败',
      hint: '检查网络连接；若在墙内/内网，请到「设置 → 网络」配置 HTTP 或 SOCKS5 代理',
      detail: raw,
    );
  }
  if (raw.contains('TimeoutException')) {
    return const DsFailure(
      '请求超时',
      hint: '站点可能被限速或不可达；稍后重试，或在「设置 → 网络」调大请求间隔',
    );
  }
  if (raw.contains('HandshakeException')) {
    return const DsFailure(
      'TLS 握手失败',
      hint: '可能是代理或证书问题；到「设置 → 网络」检查代理配置',
    );
  }
  if (raw.contains('FileSystemException')) {
    return DsFailure(
      '文件系统错误',
      hint: '检查「设置 → 下载目录」是否存在且可写；磁盘是否已满',
      detail: raw,
    );
  }
  if (raw.contains('ProcessException')) {
    return DsFailure(
      '无法启动引擎进程',
      hint: '到「设置 → 引擎」确认 rqbit-engine.exe 路径正确、文件未被杀软隔离',
      detail: raw,
    );
  }
  return DsFailure('操作失败：$raw', detail: stackTrace?.toString());
}
