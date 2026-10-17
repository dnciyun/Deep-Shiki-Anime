/// 错误 → 用户可读文案（中文界面统一走这里，避免各处 `e.toString()`）。
library;

import 'package:flutter/foundation.dart';

import 'bangumi.dart';
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
  // Bangumi 的异常是**自带结构**的（状态码 / URL），而 `toString()` 是一串
  // `BangumiException(… · HTTP 400 · https://api.bgm.tv/v0/search/subjects)` ——
  // 旧实现没有这一支，于是整页主标题就变成那串技术文本（第四十二轮 UX #15）。
  if (error is BangumiException) {
    return _fromBangumi(error);
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
  return DsFailure(
    '操作失败：${_short(raw)}',
    detail: _stackSummary(stackTrace),
  );
}

/// Bangumi 接口失败 → 按状态码给不同的"怎么办"。
DsFailure _fromBangumi(BangumiException error) {
  final int? code = error.statusCode;
  final String where = error.url == null ? '' : '（${error.url}）';
  if (code == 404) {
    return DsFailure(
      'Bangumi 上没有这一条$where',
      hint: '这个条目可能被合并/删除了；换个关键词搜，或从番剧页重新进来',
    );
  }
  if (code == 401 || code == 403) {
    return DsFailure(
      'Bangumi 拒绝了这次请求（HTTP $code）',
      hint: '多半是请求太密被限流：等一下再试；也可以在「设置 → 网络」调大请求间隔',
    );
  }
  // 第五十一轮：429 是官方在限流（不是挂了）。
  //
  // 为什么文案要点名"别换 IP"：用户 2026-10-17 的原话是「能不能做多个虚拟 ip 访问」——
  // 轮换出口 IP 只是把同一批请求摊到多个 IP 上，对 Bangumi 的公开接口属于滥用，
  // 被发现会整段封；正确做法是降频（客户端已经把三个服务合到一条 1.1s 闸门上）。
  if (code == 429) {
    return const DsFailure(
      'Bangumi 在限流（HTTP 429）',
      hint: '请求太密、被官方限流了：DSAnima 已经把 Bangumi 请求排到每秒最多一次，'
          '等一两分钟再试；不要用代理/多 IP 轮换去绕，官方会按滥用处理',
    );
  }
  // 第五十一轮：Cloudflare 的 52x = **它自己连不上 Bangumi 的源站**（502 不算，
  // 502 是通用的"上游挂了"，走下面 >=500 那一支）。实测 2026-10-17 当天
  // api.bgm.tv / bgm.tv 整片 522，本机与第三方多地区监控同时复现 —— 与访客的
  // IP、代理都无关，换 IP 没有任何用，所以这里必须把话说明白，别让用户去折腾代理。
  if (code != null && code >= 520 && code <= 524) {
    return DsFailure(
      'Bangumi 官方接口现在连不上（HTTP $code）',
      hint: 'Cloudflare 收到了请求、却连不上 Bangumi 自己的服务器 —— 是他们那边挂了，'
          '不是你这边的问题，也不是你的 IP 被限（换 IP / 挂代理都没用）。'
          '过几分钟再点一次；官方状态：https://bgm-status.ry.mk/',
      detail: _short(error.message),
    );
  }
  if (code != null && code >= 500) {
    return DsFailure(
      'Bangumi 服务器出错（HTTP $code）',
      hint: '这是对面挂了，不是你这边的问题：过一会儿再试',
    );
  }
  if (code == null) {
    return DsFailure(
      'Bangumi 数据读不出来',
      hint: '可能是接口改版或网络被拦：稍后重试；到「设置 → 网络」检查代理',
      detail: _short(error.message),
    );
  }
  return DsFailure(
    'Bangumi 接口返回 HTTP $code',
    hint: '稍后重试；反复出现就把下面的细节发给开发者',
    detail: _short(error.message),
  );
}

/// 异常文本的单行截断：有些异常会把整个响应体塞进 message，
/// 整段贴到界面上会把一屏占满（详情页主标题尤其明显）。
String _short(String raw, {int max = 200}) {
  final String oneLine = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  return oneLine.length <= max ? oneLine : '${oneLine.substring(0, max)}…';
}

/// 把堆栈压成"能贴进工单但**不含本机路径**"的一小段。
///
/// 为什么不直接给 `stackTrace.toString()`：错误面板里的 `detail` 是**可选中复制**的
/// 文本，而 Dart 堆栈每一帧都带本机绝对路径（`C:\Users\<用户名>\…`）——
/// 用户截图或贴日志时会把用户名与目录结构一起发出去（第四十二轮 UX #15）。
/// 这里只留前 3 帧的**函数名**，定位价值保留、路径去掉。
String? _stackSummary(StackTrace? stackTrace) {
  if (stackTrace == null) return null;
  final List<String> frames = <String>[];
  for (final String line in stackTrace.toString().split('\n')) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    // `#0  Foo.bar (package:dsanima/…:12:3)` → `#0 Foo.bar`
    final int paren = trimmed.indexOf(' (');
    frames.add(paren < 0 ? trimmed : trimmed.substring(0, paren));
    if (frames.length >= 3) break;
  }
  return frames.isEmpty ? null : '出错位置：${frames.join(' ← ')}';
}
