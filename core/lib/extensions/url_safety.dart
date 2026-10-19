/// 下载 / 资源地址的安全判据 —— 单独一个文件，给 `manifest.dart`（扩展清单/目录）与
/// `generic.dart`（通用载荷里的 URL 字段）共用。
///
/// 为什么单独抽出来：`generic.dart` 不能 import `manifest.dart`（manifest 要 import
/// generic 做分发，会成环）。这个函数只依赖 `dart:core` 的 `Uri`，搬出来最干净；
/// `manifest.dart` 继续 `export` 它，既有 `import 'manifest.dart'` 的代码不受影响。
library;

/// 下载地址的安全判据（纯函数，返回 null = 可以下）。
///
/// 只允许 **HTTPS**；HTTP 只给回环地址（`127.0.0.1` / `localhost` / `[::1]`）留一条缝 ——
/// 本地起个静态目录测扩展是正当需求，而公网明文 HTTP 会被中间人换成任意 zip。
String? unsafeExtensionUrlReason(Uri? uri) {
  if (uri == null) return '地址为空';
  if (uri.hasScheme == false) return '地址缺少协议（要写 https://）';
  final String scheme = uri.scheme.toLowerCase();
  if (scheme == 'https') {
    if (uri.host.isEmpty) return '地址缺少主机名';
    return null;
  }
  if (scheme == 'http') {
    final String host = uri.host.toLowerCase();
    final bool loopback = host == 'localhost' || host == '127.0.0.1' || host == '::1' || host == '[::1]';
    if (loopback) return null;
    return '出于安全只接受 HTTPS 地址（HTTP 仅限本机回环地址）';
  }
  return '不支持的协议「$scheme」（只接受 https://）';
}
