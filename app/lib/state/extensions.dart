/// 扩展页的**状态机**（1.1.0 M3/T14）。
///
/// 照 `update.dart` 的做法：每一个 phase 对应界面上**一句**确定的话，
/// 判定与 IO 都不在这里 —— 判据在 `dsanima_core`（清单/守卫），IO 在
/// `extensions_adapter.dart`，这里只负责"按顺序调用 + 把结果翻成状态"。
///
/// ```
/// idle ──ensureLoaded──> scanning ──> ready ──┬─ install ──> installing ──> ready(notice)
///                                            │                      └──> problem(红字)
///                                            ├─ setEnabled/remove ──> ready(notice)
///                                            └─ addCatalog ─────────> ready(目录填好 / problem)
/// ```
///
/// 三个"不撒谎"的落点：
/// * **取消 ≠ 失败**：用户点了取消显示「已取消安装（临时文件已清理）」，
///   不显示红字失败；
/// * **装上 ≠ 能用**：类型本版本不接运行时（`usable == false`）时，
///   [ExtensionsState.notice] 里要补一句"装好了但本版本不会生效"，界面照它显示；
/// * **进度不是猜的**：对端没给 Content-Length 时 [ExtensionProgress.fraction] 为 null，
///   界面用不确定进度条，不拿"已下载多少"除以一个编造的总量。
library;

import 'dart:async';

import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/error_text.dart';
import '../domain/extensions.dart';
import '../domain/extensions_port.dart';
import '../domain/unavailable.dart';
import 'providers.dart';

/// 扩展端口的注入点。
///
/// 放在本文件而不是 `providers.dart`：`extensionsPortProvider` 只被扩展这条链路用到
/// （`main.dart` 覆盖 + 本文件读），放这里能让"扩展"整块保持在一个文件里。
/// `providers.dart` 那边只有 `ShellTab` 一处需要为扩展加一行。
final Provider<ExtensionsPort> extensionsPortProvider = Provider<ExtensionsPort>(
  (Ref ref) => const UnavailableExtensionsPort(),
  name: 'extensionsPort',
);

/// 扩展目录/启用状态的**版本号**：装/卸/启用/禁用之后 +1。
///
/// 谁订阅它谁就要重读扩展（1.1.0 T17：播放器的超分方案清单、设置页的方案区）。
/// 不直接让播放器 watch 整个 [extensionsProvider]（那会连带下载进度一起重建）。
class ExtensionsRevisionController extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

final NotifierProvider<ExtensionsRevisionController, int> extensionsRevisionProvider =
    NotifierProvider<ExtensionsRevisionController, int>(ExtensionsRevisionController.new);

/// 扩展页当前处于哪一步。
enum ExtensionsPhase {
  /// 还没扫过（页面刚挂载）。
  idle,

  /// 正在读磁盘上的 `state.json` + 目录。
  scanning,

  /// 可以操作（列表/目录已就绪）。
  ready,

  /// 正在下载/校验/解压（[ExtensionsState.progress] 有值）。
  installing,

  /// 上一步出问题了（[ExtensionsState.problem] 说为什么、怎么办）。
  problem,
}

/// copyWith 里区分"没传这个参数"与"传了 null"（要清空）。
const Object _unset = Object();

/// 扩展页的完整状态（不可变，UI 直接渲染）。
@immutable
class ExtensionsState {
  const ExtensionsState({
    this.phase = ExtensionsPhase.idle,
    this.installed = const <InstalledExtension>[],
    this.catalog = const <core.CatalogEntry>[],
    this.catalogUri,
    this.catalogFetchedAt,
    this.installingId,
    this.installingName,
    this.progress,
    this.cancelling = false,
    this.notice,
    this.problem,
    this.problemHint,
  });

  final ExtensionsPhase phase;

  /// 已安装的扩展（按名字排序，界面直接渲染）。
  final List<InstalledExtension> installed;

  /// 最近一次成功拉到的在线目录（没拉过 = 空）。
  final List<core.CatalogEntry> catalog;

  /// 目录是从哪个地址拉的（界面显示"来自 …"，刷新用）。
  final Uri? catalogUri;

  final DateTime? catalogFetchedAt;

  /// 正在安装的扩展 id（本地 zip 且清单还没读到时为 null）。
  final String? installingId;

  /// 正在安装的扩展名字（界面「正在安装 X」）。
  final String? installingName;

  /// 下载进度（只有 [ExtensionsPhase.installing] 且在线安装时有值）。
  final ExtensionProgress? progress;

  /// 用户已点取消、正在等端口收尾。
  final bool cancelling;

  /// 成功提示（一次性；下一次操作时清掉）。
  final String? notice;

  /// 出错时的主文案（红字）与"怎么办"。
  final String? problem;
  final String? problemHint;

  /// 顶部统计。
  ExtensionsSummary get summary => ExtensionsSummary.of(installed);

  /// 是否正在忙（扫描/安装期间按钮要禁用）。
  bool get busy => phase == ExtensionsPhase.scanning || phase == ExtensionsPhase.installing;

  /// 已安装里能真的用起来的（T17 的超分方案区读它）。
  List<InstalledExtension> get enabledUsable => <InstalledExtension>[
        for (final InstalledExtension item in installed)
          if (item.enabled && item.usable) item,
      ];

  ExtensionsState copyWith({
    ExtensionsPhase? phase,
    List<InstalledExtension>? installed,
    List<core.CatalogEntry>? catalog,
    Object? catalogUri = _unset,
    Object? catalogFetchedAt = _unset,
    Object? installingId = _unset,
    Object? installingName = _unset,
    Object? progress = _unset,
    bool? cancelling,
    Object? notice = _unset,
    Object? problem = _unset,
    Object? problemHint = _unset,
  }) =>
      ExtensionsState(
        phase: phase ?? this.phase,
        installed: installed ?? this.installed,
        catalog: catalog ?? this.catalog,
        catalogUri: identical(catalogUri, _unset) ? this.catalogUri : catalogUri as Uri?,
        catalogFetchedAt: identical(catalogFetchedAt, _unset)
            ? this.catalogFetchedAt
            : catalogFetchedAt as DateTime?,
        installingId:
            identical(installingId, _unset) ? this.installingId : installingId as String?,
        installingName:
            identical(installingName, _unset) ? this.installingName : installingName as String?,
        progress: identical(progress, _unset) ? this.progress : progress as ExtensionProgress?,
        cancelling: cancelling ?? this.cancelling,
        notice: identical(notice, _unset) ? this.notice : notice as String?,
        problem: identical(problem, _unset) ? this.problem : problem as String?,
        problemHint: identical(problemHint, _unset) ? this.problemHint : problemHint as String?,
      );
}

/// 扩展页控制器。所有方法都可以在 widget 里直接 `ref.read(...).xxx()`。
class ExtensionsController extends Notifier<ExtensionsState> {
  /// 只在真正需要时才扫盘（扩展页是懒挂载的，见 M1/T1）。
  bool _loaded = false;

  /// 取消标志：端口每读一次就问一次（下载/解压的每个 chunk 之间）。
  bool _cancelRequested = false;

  /// 安装代次：用户取消后又立刻重装时，旧的那次结果必须被丢掉。
  int _generation = 0;

  /// 进度节流的最后推送时间（`onProgress` 一秒能来几十次，别把 UI 顶满）。
  DateTime _lastProgressPush = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  ExtensionsState build() => const ExtensionsState();

  ExtensionsPort get _port => ref.read(extensionsPortProvider);

  /// 页面挂载时调一次：扫盘（已扫过就什么都不做）。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    await refresh();
  }

  /// 重新扫盘（安装/卸载后也会自动调）。
  Future<void> refresh() async {
    if (state.phase == ExtensionsPhase.installing) return;
    state = state.copyWith(
      phase: ExtensionsPhase.scanning,
      notice: null,
      problem: null,
      problemHint: null,
    );
    try {
      final List<InstalledExtension> list = await _port.scan();
      _loaded = true;
      state = state.copyWith(phase: ExtensionsPhase.ready, installed: _sorted(list));
    } catch (error) {
      state = state.copyWith(
        phase: ExtensionsPhase.problem,
        problem: _describe(error).message,
        problemHint: _describe(error).hint,
      );
    }
  }

  /// 拉一份在线目录（[catalogUrl] 必须是目录 json 的地址，或其来源页）。
  Future<void> addCatalog(String catalogUrl) async {
    if (state.busy) return;
    final Uri? uri = Uri.tryParse(catalogUrl.trim());
    final String? unsafe = core.unsafeExtensionUrlReason(uri);
    if (unsafe != null) {
      state = state.copyWith(
        phase: ExtensionsPhase.problem,
        problem: '目录地址不可用：$unsafe',
        problemHint: '填 https:// 开头的目录 json 地址（本机回环可用 http）',
      );
      return;
    }
    state = state.copyWith(
      phase: ExtensionsPhase.scanning,
      notice: null,
      problem: null,
      problemHint: null,
    );
    try {
      final List<core.CatalogEntry> entries = await _port.fetchCatalog(uri!);
      state = state.copyWith(
        phase: ExtensionsPhase.ready,
        catalog: entries,
        catalogUri: uri,
        catalogFetchedAt: DateTime.now(),
        notice: entries.isEmpty ? '这个目录里没有可用扩展' : '目录已加载：${entries.length} 个扩展',
      );
    } catch (error) {
      final DsFailure failure = _describe(error);
      state = state.copyWith(
        phase: ExtensionsPhase.problem,
        problem: failure.message,
        problemHint: failure.hint,
      );
    }
  }

  /// 从已拉到的目录里装一条（sha256/size 用目录里给的，校验更严）。
  Future<void> installFromCatalog(core.CatalogEntry entry) async {
    await _install(ExtensionInstallRequest(
      url: entry.url,
      sha256: entry.sha256,
      size: entry.size,
      manifest: entry.manifest,
      label: entry.manifest.name,
    ));
  }

  /// 从用户填的地址装一个 zip（直链；没有预先的 sha256，只校验清单里的逐文件哈希）。
  Future<void> installFromUrl(String urlText) async {
    final Uri? uri = Uri.tryParse(urlText.trim());
    final String? unsafe = core.unsafeExtensionUrlReason(uri);
    if (unsafe != null) {
      state = state.copyWith(
        phase: ExtensionsPhase.problem,
        problem: '下载地址不可用：$unsafe',
        problemHint: '填 zip 的 https:// 直链（本机回环可用 http）',
      );
      return;
    }
    await _install(ExtensionInstallRequest(url: uri));
  }

  /// 选一个本地 zip 安装（`PickerPort`，测试注入假选择器）。
  Future<void> installFromZip() async {
    if (state.busy) return;
    final String? path;
    try {
      path = await ref.read(pickerPortProvider).pickFile(
            title: '选择扩展包（.zip）',
            extensions: const <String>['zip'],
          );
    } catch (error) {
      final DsFailure failure = _describe(error);
      state = state.copyWith(
        phase: ExtensionsPhase.problem,
        problem: '打不开文件选择器：${failure.message}',
        problemHint: failure.hint,
      );
      return;
    }
    if (path == null || path.trim().isEmpty) return; // 用户取消选择：不是错误
    await _install(ExtensionInstallRequest(localPath: path.trim()));
  }

  /// 取消正在进行的安装（下载中断/解压中断；端口负责清临时文件）。
  void cancelInstall() {
    if (state.phase != ExtensionsPhase.installing) return;
    _cancelRequested = true;
    state = state.copyWith(cancelling: true);
  }

  /// 启用/禁用（禁用保留文件，立刻对运行时生效）。
  Future<void> setEnabled(String id, bool enabled) async {
    if (state.busy) return;
    try {
      await _port.setEnabled(id, enabled);
      final List<InstalledExtension> list = await _port.scan();
      state = state.copyWith(
        phase: ExtensionsPhase.ready,
        installed: _sorted(list),
        notice: enabled ? '已启用「${_nameOf(list, id)}」' : '已禁用「${_nameOf(list, id)}」（文件还在）',
        problem: null,
        problemHint: null,
      );
      _bumpRevision();
    } catch (error) {
      final DsFailure failure = _describe(error);
      state = state.copyWith(
        phase: ExtensionsPhase.problem,
        problem: failure.message,
        problemHint: failure.hint,
      );
    }
  }

  /// 卸载（目录进回收站；文件可恢复）。
  Future<void> remove(String id) async {
    if (state.busy) return;
    try {
      await _port.remove(id);
      final List<InstalledExtension> list = await _port.scan();
      state = state.copyWith(
        phase: ExtensionsPhase.ready,
        installed: _sorted(list),
        notice: '已卸载「${_nameOf(state.installed, id)}」（文件在回收站里）',
        problem: null,
        problemHint: null,
      );
      _bumpRevision();
    } catch (error) {
      final DsFailure failure = _describe(error);
      state = state.copyWith(
        phase: ExtensionsPhase.problem,
        problem: failure.message,
        problemHint: failure.hint,
      );
    }
  }

  /// 在资源管理器里打开扩展目录。
  Future<void> openDirectory() async {
    try {
      await _port.openDirectory();
    } catch (error) {
      final DsFailure failure = _describe(error);
      state = state.copyWith(
        phase: ExtensionsPhase.problem,
        problem: failure.message,
        problemHint: failure.hint,
      );
    }
  }

  // ── 内部 ──────────────────────────────────────────────────────────────────

  Future<void> _install(ExtensionInstallRequest request) async {
    if (state.busy) return;
    _cancelRequested = false;
    final int generation = ++_generation;
    _lastProgressPush = DateTime.fromMillisecondsSinceEpoch(0);
    state = state.copyWith(
      phase: ExtensionsPhase.installing,
      installingId: request.manifest?.id,
      installingName: request.displayName,
      progress: request.url == null ? null : const ExtensionProgress(received: 0),
      cancelling: false,
      notice: null,
      problem: null,
      problemHint: null,
    );
    try {
      final InstalledExtension installed = await _port.install(
        request,
        onProgress: (ExtensionProgress progress) {
          if (generation != _generation) return;
          final DateTime now = DateTime.now();
          final bool last = progress.total != null && progress.received >= progress.total!;
          if (!last && now.difference(_lastProgressPush) < const Duration(milliseconds: 80)) {
            return;
          }
          _lastProgressPush = now;
          state = state.copyWith(progress: progress);
        },
        isCancelled: () => _cancelRequested || generation != _generation,
      );
      if (generation != _generation) return; // 被新的安装顶掉了，旧结果不许覆盖界面
      _cancelRequested = false;
      final List<InstalledExtension> list = await _port.scan();
      _loaded = true;
      state = state.copyWith(
        phase: ExtensionsPhase.ready,
        installed: _sorted(list),
        installingId: null,
        installingName: null,
        progress: null,
        cancelling: false,
        notice: _installedNotice(installed),
      );
      _bumpRevision();
    } on ExtensionInstallCancelled {
      if (generation != _generation) return;
      _cancelRequested = false;
      final List<InstalledExtension> list = await _safeScan();
      state = state.copyWith(
        phase: ExtensionsPhase.ready,
        installed: _sorted(list),
        installingId: null,
        installingName: null,
        progress: null,
        cancelling: false,
        notice: '已取消安装（临时文件已清理，磁盘上没有半成品）',
      );
    } catch (error) {
      if (generation != _generation) return;
      _cancelRequested = false;
      final DsFailure failure = _describe(error);
      final List<InstalledExtension> list = await _safeScan();
      state = state.copyWith(
        phase: ExtensionsPhase.problem,
        installed: _sorted(list),
        installingId: null,
        installingName: null,
        progress: null,
        cancelling: false,
        problem: failure.message,
        problemHint: failure.hint,
      );
    }
  }

  Future<List<InstalledExtension>> _safeScan() async {
    try {
      return await _port.scan();
    } catch (_) {
      return state.installed;
    }
  }

  void _bumpRevision() {
    try {
      ref.read(extensionsRevisionProvider.notifier).bump();
    } catch (_) {
      // build 期/已 dispose：版本号不是关键路径，忽略。
    }
  }

  /// 安装成功的提示：类型本版本不接运行时的话，必须当场说清楚（不许让用户以为有了新功能）。
  String _installedNotice(InstalledExtension installed) {
    final String base = '「${installed.name}」已安装';
    if (installed.usable) {
      return '$base · 可在播放器的「超分」菜单里选用';
    }
    if (!installed.manifest.isKnownKind) {
      return '$base · 类型「${installed.manifest.kind}」本版本不接运行时，暂时不会有新功能';
    }
    return '$base · 本版本还不会让它生效（数据包装得上、用不上）';
  }

  static String _nameOf(Iterable<InstalledExtension> list, String id) {
    for (final InstalledExtension item in list) {
      if (item.id == id) return item.name;
    }
    return id;
  }

  static List<InstalledExtension> _sorted(List<InstalledExtension> list) {
    final List<InstalledExtension> copy = List<InstalledExtension>.of(list);
    copy.sort((InstalledExtension a, InstalledExtension b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return List<InstalledExtension>.unmodifiable(copy);
  }

  /// 端口异常 → 展示文案（[ExtensionFailure] 自带 message/hint；其余走统一口径）。
  static DsFailure _describe(Object error) {
    if (error is ExtensionFailure) {
      return DsFailure(error.message, hint: error.hint);
    }
    return describeFailure(error);
  }
}

/// 扩展页状态入口（UI 用 `ref.watch(extensionsProvider)`）。
final NotifierProvider<ExtensionsController, ExtensionsState> extensionsProvider =
    NotifierProvider<ExtensionsController, ExtensionsState>(ExtensionsController.new);
