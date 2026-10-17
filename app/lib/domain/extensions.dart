/// 扩展（1.1.0 M3）——宿主这一侧的**数据形态**（不含 IO，也不含界面状态）。
///
/// 三层分工（改任何一层前先读这里）：
/// * `dsanima_core` 的 `extensions/manifest.dart` + `package_guard.dart`：**判据**
///   （这份清单/这个包能不能装），纯函数、离线可测；
/// * 本文件 + `domain/extensions_port.dart`：**形态与接口**（装好的扩展长什么样、
///   端口提供哪几件事），UI 与测试只认这里；
/// * `state/extensions.dart`：**状态机**（把端口调用翻成界面上的一句话）；
///   `state/extensions_adapter.dart`：**真 IO**（下载/解压/原子替换），只许 `main.dart` 引。
///
/// 三条不撒谎的约定（M1 那一轮定下、这里沿用）：
/// 1. 装不上就是装不上 —— 端口抛异常，异常带"为什么 + 怎么办"，界面绝不显示假的"已安装"；
/// 2. 取消是真的取消 —— 下载/解压中途取消要清掉临时文件，正式目录不出现半成品；
/// 3. 装上 ≠ 能用 —— [InstalledExtension.usable] 为 false 的包（类型本版本不接运行时）
///    界面必须写清楚，不许让用户以为"装了就有新功能"。
library;

import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter/foundation.dart';

/// 扩展来源（界面「来源」列显示，卸载/重装排错时用）。
enum ExtensionOrigin {
  /// 用户选的本地 zip。
  localZip('本地文件'),

  /// 从 HTTPS 地址下载的 zip。
  url('在线下载');

  const ExtensionOrigin(this.label);
  final String label;
}

/// 一份**已安装**的扩展（`state.json` + 目录 + 清单三者对账后的结果）。
@immutable
class InstalledExtension {
  const InstalledExtension({
    required this.manifest,
    required this.enabled,
    required this.installedAt,
    required this.origin,
    this.sourceUrl,
    this.bytes = 0,
  });

  /// 清单（`core.parseExtensionManifest` 的产物，含原始 json）。
  final core.ExtensionManifest manifest;

  /// 是否启用。**禁用只是不让它参与运行时**，文件还在（卸载才是删）。
  final bool enabled;

  final DateTime installedAt;

  final ExtensionOrigin origin;

  /// 在线安装时的下载地址（本地导入为 null）。
  final String? sourceUrl;

  /// 目录占用字节数（界面「大小」列；0 = 没算出来，显示「—」）。
  final int bytes;

  String get id => manifest.id;

  String get name => manifest.name;

  /// 本版本能不能真的用起来（`shader-pack` 且 shader 描述完整）。
  ///
  /// 注意：这是**类型层面**的可用性；运行时还要求引擎/播放器实际加载成功。
  bool get usable => manifest.isUsable;

  InstalledExtension copyWith({bool? enabled, int? bytes}) => InstalledExtension(
        manifest: manifest,
        enabled: enabled ?? this.enabled,
        installedAt: installedAt,
        origin: origin,
        sourceUrl: sourceUrl,
        bytes: bytes ?? this.bytes,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'enabled': enabled,
        'installedAt': installedAt.toIso8601String(),
        'origin': origin.name,
        if (sourceUrl != null) 'sourceUrl': sourceUrl,
        'bytes': bytes,
        'manifest': manifest.toJson(),
      };
}

/// 一次安装请求。
///
/// 两种来源之一：[url]（在线 zip）或 [localPath]（本地 zip）。两者都给或都不给 = 装配错误。
@immutable
class ExtensionInstallRequest {
  const ExtensionInstallRequest({
    this.url,
    this.localPath,
    this.sha256,
    this.size,
    this.manifest,
    this.label,
  })  : assert(url != null || localPath != null, '安装请求必须给 url 或 localPath'),
        assert(!(url != null && localPath != null), 'url 与 localPath 只能给一个');

  /// 在线 zip 的地址。
  final Uri? url;

  /// 本地 zip 的绝对路径。
  final String? localPath;

  /// 期望的 zip sha256（在线目录给了就必须校验；null = 只校验清单里的逐文件哈希）。
  final String? sha256;

  /// 期望的 zip 字节数（null = 不校验长度）。
  final int? size;

  /// 已知清单（从目录装的；用于界面显示名字/进度，**不作为可信来源**：
  /// 真正生效的清单只认 zip 里的 `manifest.json`，目录里的可以先看）。
  final core.ExtensionManifest? manifest;

  /// 界面「正在安装 X」用的名字（null 时回退 [manifest]?.name，再回退「扩展」）。
  final String? label;

  String get displayName => label ?? manifest?.name ?? '扩展';

  ExtensionOrigin get origin => localPath != null ? ExtensionOrigin.localZip : ExtensionOrigin.url;

  String? get sourceUrl => url?.toString();
}

/// 下载进度。[total] 未知时（对端不给 Content-Length）只说已收到多少。
@immutable
class ExtensionProgress {
  const ExtensionProgress({required this.received, this.total});

  final int received;
  final int? total;

  /// 0..1；[total] 未知或为 0 时返回 null（界面用不确定进度条，不假装知道）。
  double? get fraction {
    final int? t = total;
    if (t == null || t <= 0) return null;
    return (received / t).clamp(0.0, 1.0);
  }

  @override
  String toString() => total == null ? '$received B' : '$received / $total B';
}

/// 安装被用户取消（端口抛这个；状态机据此显示「已取消」而不是「失败」）。
class ExtensionInstallCancelled implements Exception {
  const ExtensionInstallCancelled();

  @override
  String toString() => '安装已取消';
}

/// 扩展相关的可预期失败（清单不合法 / 校验不符 / 磁盘不足 / 网络失败…）。
///
/// 与 [PortUnavailableException] 的区别：那是"端口没接通"的装配问题，
/// 这是"用户真的遇到了"的问题，两者的界面文案完全不同。
class ExtensionFailure implements Exception {
  const ExtensionFailure(this.message, {this.hint});

  /// 发生了什么（中文、写给用户）。
  final String message;

  /// 怎么办（中文；null = 没有更好的建议）。
  final String? hint;

  @override
  String toString() => hint == null ? message : '$message（$hint）';
}

/// 一次「扫描扩展目录」的结果摘要（界面顶部统计 + 缓存统计）。
@immutable
class ExtensionsSummary {
  const ExtensionsSummary({
    required this.installedCount,
    required this.enabledCount,
    required this.usableCount,
    required this.bytes,
  });

  final int installedCount;
  final int enabledCount;
  final int usableCount;

  /// 扩展目录总占用（字节）。
  final int bytes;

  static const ExtensionsSummary empty = ExtensionsSummary(
    installedCount: 0,
    enabledCount: 0,
    usableCount: 0,
    bytes: 0,
  );

  factory ExtensionsSummary.of(Iterable<InstalledExtension> list) {
    int enabled = 0;
    int usable = 0;
    int bytes = 0;
    int count = 0;
    for (final InstalledExtension item in list) {
      count++;
      if (item.enabled) enabled++;
      if (item.usable) usable++;
      bytes += item.bytes;
    }
    return ExtensionsSummary(
      installedCount: count,
      enabledCount: enabled,
      usableCount: usable,
      bytes: bytes,
    );
  }
}
