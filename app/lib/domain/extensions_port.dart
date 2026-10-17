/// 「扩展」端口 —— 宿主 UI/状态机与真 IO 之间唯一的那道缝。
///
/// 为什么值得抽象：真实现要动**磁盘结构**（`extensions/<id>/`、`.staging/`、`.trash/`、
/// `state.json`）、要下载、要解压、删东西进回收站 —— 这些在 widget 测试里一样都不该真跑。
/// 所以界面只认这 7 件事，`main.dart` 注入 `state/extensions_adapter.dart` 的真实现，
/// 测试注入假实现；未接通时注入 `domain/unavailable.dart` 的
/// [UnavailableExtensionsPort]（**抛异常并说明怎么办**，绝不假装成功）。
///
/// ## 契约（实现方必须逐条满足，测试照着钉）
///
/// 1. **原子性**：安装要么完整成功、要么正式目录毫无变化。过程只往
///    `.staging/` 写，全部校验通过才 rename 进 `extensions/<id>/`；旧版本先挪进
///    `.trash/`。任何一步失败都清掉临时目录，**正式目录不许出现半成品**。
/// 2. **校验不可省**：先按 `core.checkExtensionPackage` 过条目表（zip-slip/炸弹/夹带），
///    再逐文件比对 `size` + `sha256`；给的 `sha256` 与 zip 整体不符就拒。
/// 3. **取消要干净**：`isCancelled()` 变成 true 时尽快抛 [ExtensionInstallCancelled]，
///    临时文件/临时目录清掉（下次安装不受影响）。
/// 4. **失败要可行动**：抛 [ExtensionFailure]（中文：发生了什么 + 怎么办）；
///    网络/磁盘的底层异常也包成它。**不许**静默吞掉。
/// 5. **状态以磁盘为准**：`scan()` 每次读 `state.json` 并对账目录（目录没了 = 该条作废）；
///    写 `state.json` 也要原子（临时文件 + rename）。
/// 6. **卸载进回收站**（用户 2026-10-12 定下的规矩：删除要可恢复）。
library;

import 'package:dsanima_core/dsanima_core.dart' as core;

import 'extensions.dart';

/// 装一个扩展时端口要做的全部事情（下载 → 校验 → 解压 → 原子替换）。
abstract interface class ExtensionsPort {
  /// 扩展根目录（`<数据根>/extensions`）的绝对路径。
  ///
  /// 界面上的「打开扩展目录」用它；它可能还不存在（第一次装之前）。
  String get extensionsDir;

  /// 扫描已安装扩展（`state.json` + 目录对账）。失败抛 [ExtensionFailure]。
  Future<List<InstalledExtension>> scan();

  /// 安装/升级一个扩展，返回装好之后的那一条。
  ///
  /// 同一个 `id` 已存在时按**升级**处理：旧目录进 `.trash/`、新目录 rename 就位、
  /// 保留原来的启用状态（用户禁用过的包升级后不该自己变成启用）。
  Future<InstalledExtension> install(
    ExtensionInstallRequest request, {
    void Function(ExtensionProgress progress)? onProgress,
    bool Function()? isCancelled,
  });

  /// 启用/禁用。禁用保留文件（只是不参与运行时），且要立刻对播放器生效。
  Future<void> setEnabled(String id, bool enabled);

  /// 卸载（目录进回收站）。`id` 不存在时**静默成功**（重复点不该报错）。
  Future<void> remove(String id);

  /// 拉一份在线目录并解析（HTTPS/回环 HTTP，校验由 core 的 `parseExtensionCatalog` 做）。
  Future<List<core.CatalogEntry>> fetchCatalog(Uri url);

  /// 在资源管理器里打开扩展目录（不存在就建出来）。
  Future<void> openDirectory();
}
