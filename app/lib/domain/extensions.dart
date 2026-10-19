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

/// 「这类扩展在本版本能干什么」——**唯一口径**，扩展页、安装成功提示都用它。
///
/// 为什么要一个函数：`usable` 只说"清单完整、能用"，不说"用在哪儿"。
/// 1.1.0 里 `shader-pack` 进播放器「超分」菜单，`picture-pack` 进「画面调节」
/// （预设 + 滑杆面板），两者混着说会指错菜单（用户点进去找不到）。
String extensionUseHint(core.ExtensionManifest manifest) {
  // 通用包（preset-pack / list-pack / audio-pack）的回答由它声明的「面」决定：
  // 已知面 → 这个面自己的入口文案；未知面 → 如实说本版本不接。
  final bool genericKind = manifest.kind == core.ExtensionKind.presetPack ||
      manifest.kind == core.ExtensionKind.listPack ||
      manifest.kind == core.ExtensionKind.audioPack;
  if (genericKind) {
    final String label = core.ExtensionKind.labelOf(manifest.kind);
    final core.GenericPayload? payload = manifest.generic;
    final core.ExtensionSurface? surface =
        payload == null ? null : core.extensionSurfaceOf(payload.surface);
    if (surface != null) return '$label：${surface.hostHint}';
    final String surfaceId = payload?.surface ?? '未知';
    return '$label（面「$surfaceId」本版本不接运行时）：装得上、暂时不会有新功能';
  }
  if (!manifest.isUsable) {
    if (!manifest.isKnownKind) {
      return '类型「${manifest.kind}」本版本不接运行时，暂时不会有新功能';
    }
    return '本版本不接运行时（数据包装得上、用不上，暂时不会有新功能）';
  }
  if (manifest.kind == core.ExtensionKind.picturePack) {
    return '画面调节包：装上后进播放器右键菜单的「画面调节」（预设 + 滑杆面板）';
  }
  return '可在播放器的「超分」菜单里选用';
}

/// 官方插件库的地址（用户 2026-10-18：「加入官方插件库，可以直接下载我加进去的插件」）。
///
/// 用户 2026-10-18 晚给了仓库：<https://github.com/dnciyun/DSAnima-plungin>，本轮填上 ——
/// 扩展页「官方插件库」按钮从此**开箱就能点**，不用先粘一次地址。
///
/// 填的是**仓库网页地址**而不是 `catalog.json` 的 raw 地址，这是故意的：
/// * 从网页地址看不出"默认分支叫 main 还是 master"、"catalog.json 放根还是 extensions/ 下"，
///   所以 `core.extensionCatalogUrlCandidates` 会把仓库地址展开成 4 个候选依次试；
///   直接写死 raw 地址只会试一个，作者把文件放歪一格就是一句看不懂的 404；
/// * 用户粘的也是这个地址 —— 应用自己认得（`core/lib/extensions/urls.dart` 有测试）。
///
/// 仓库名 `DSAnima-plungin` 是用户给的原样拼写（`plungin`，不是 `plugin`）：
/// GitHub 的仓库名就是地址的一部分，**不要顺手"改正"**，改一个字母就是另一个仓库。
///
/// 仓库里还没有 `catalog.json` 时按钮会报 404 —— `extensions_adapter.dart` 对"官方库"
/// 这条地址有专门的一句提示（把 catalog.json 推上去就好了），别让用户去猜。
///
/// 换仓库时改这一行即可；用户那边"上次成功拉过的地址"优先于它（`extension-settings.json`），
/// 所以换仓库也不会让已经配好别的目录的人突然被改掉。
const String kOfficialExtensionsCatalogUrl = 'https://github.com/dnciyun/DSAnima-plungin';
