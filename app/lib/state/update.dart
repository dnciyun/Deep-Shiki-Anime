/// 检查更新 / 直接更新（第三十九轮：走 GitHub Release）。
///
/// 状态机（每一个 phase 对应界面上**一句话**，不合并、不含糊）：
/// ```
/// idle ──check──> checking ──┬─> upToDate      已是最新（带上检查时间）
///                            ├─> available     有新版本 + 挑好的更新包
///                            └─> problem       填错了 / 没有可用包 / 网络失败
/// available ──download──> downloading ──> ready（包已在本地）
/// ready ──apply──> applying（脚本已启动，本进程马上退出）──> [新版本重启]
/// ```
///
/// 两个"诚实"的落点：
/// * **判定不在这一层** —— 要不要更新、挑哪个包由 `dsanima_core` 的纯函数决定
///   （`decideUpdate`），这里只负责把结论翻译成界面状态；
/// * **重启之后要对账** —— 覆盖是另一个进程干的活，宿主看不见。下次启动拿
///   `pending.json`（"我要升到哪一版"）和现在的版本比一下：没生效就明说没生效，
///   绝不因为"用户以为更新过了"而闭嘴。
library;

import 'dart:async';
import 'dart:io';

import 'package:dsanima_core/update/update.dart' as core_update;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/app_version.dart';
import '../domain/error_text.dart';
import '../domain/ports.dart';
import 'providers.dart';

/// copyWith 里区分"没传这个参数"与"传了 null"（要清空）。
const Object _unset = Object();

enum UpdatePhase {
  /// 还没检查过。
  idle,

  /// 正在请求 GitHub。
  checking,

  /// 已是最新。
  upToDate,

  /// 有新版本，可以下载。
  available,

  /// 正在下载更新包。
  downloading,

  /// 下好了，等用户点「立即重启并更新」。
  ready,

  /// 覆盖脚本已启动（本进程马上退出）。
  applying,

  /// 出问题了（填错/没包/网络失败/上次更新没生效）——[UpdateState.failure] 里有原因和办法。
  problem,
}

@immutable
class UpdateState {
  const UpdateState({
    this.phase = UpdatePhase.idle,
    this.slug,
    this.release,
    this.asset,
    this.received = 0,
    this.total,
    this.checkedAt,
    this.package,
    this.failure,
    this.note,
  });

  final UpdatePhase phase;

  /// 规范化之后的更新源（`owner/repo`）——检查过的那个。
  final String? slug;

  final core_update.ReleaseInfo? release;
  final core_update.ReleaseAsset? asset;

  /// 已下载字节 / 服务端给的总字节（可能为 null）。
  final int received;
  final int? total;

  final DateTime? checkedAt;

  /// 下载到本地的更新包。
  final File? package;

  /// 失败原因 + 怎么办（**原样展示**，不加工）。
  final DsFailure? failure;

  /// 不是失败、但要说一句的事（"已取消下载""已更新到 v1.0.1"…）。
  final String? note;

  bool get busy =>
      phase == UpdatePhase.checking ||
      phase == UpdatePhase.downloading ||
      phase == UpdatePhase.applying;

  /// 0..1；服务端没给总大小时为 null（那就只显示"已下载多少"）。
  double? get progress {
    final int? size = total;
    if (size == null || size <= 0) return null;
    return (received / size).clamp(0.0, 1.0);
  }

  /// 更新包大小（优先用服务端给的，其次用已下载字节）。
  int get assetBytes => total ?? received;

  UpdateState copyWith({
    UpdatePhase? phase,
    String? slug,
    core_update.ReleaseInfo? release,
    core_update.ReleaseAsset? asset,
    int? received,
    Object? total = _unset,
    DateTime? checkedAt,
    Object? package = _unset,
    Object? failure = _unset,
    Object? note = _unset,
  }) => UpdateState(
    phase: phase ?? this.phase,
    slug: slug ?? this.slug,
    release: release ?? this.release,
    asset: asset ?? this.asset,
    received: received ?? this.received,
    total: identical(total, _unset) ? this.total : total as int?,
    checkedAt: checkedAt ?? this.checkedAt,
    package: identical(package, _unset) ? this.package : package as File?,
    failure: identical(failure, _unset) ? this.failure : failure as DsFailure?,
    note: identical(note, _unset) ? this.note : note as String?,
  );
}

class UpdateController extends Notifier<UpdateState> {
  bool _cancelRequested = false;

  /// 最近一次检查用的访问令牌（第四十轮）——**下载那一趟要用同一个**。
  ///
  /// 为什么不放进 [UpdateState]：① 令牌不该出现在任何界面会回放/记录的状态里；
  /// ② `check()` 里有五六个分支各自构造 `UpdateState`，塞进去要改六处，漏一处就是
  /// "检查带了令牌、下载没带"这种只在私有仓库/受限账号上才暴露的怪 bug。
  /// 空 = 匿名；[reset] 会一起清掉。
  String _token = '';
  bool _reconciled = false;

  @override
  UpdateState build() {
    // 启动时对一次账（上次更新到底成没成）。不 await：build 是同步的，而且这件事
    // 不该挡首帧。
    if (!_reconciled) {
      _reconciled = true;
      unawaited(_reconcileAfterRestart());
    }
    return const UpdateState();
  }

  /// 上次更新对账（见文件头）。
  Future<void> _reconcileAfterRestart() async {
    final UpdatePort port = ref.read(updatePortProvider);
    final core_update.PendingUpdate? pending;
    try {
      pending = await port.pendingUpdate();
    } catch (_) {
      return; // 读不到就当没有待办（不该因为一次读失败而弹一个吓人的红条）
    }
    if (pending == null) return;
    final core_update.UpdateAftermath outcome =
        core_update.compareAftermath(current: kAppVersion, pending: pending);
    try {
      await port.declarePending(null); // 只报一次，不每次启动都念
    } catch (_) {
      // 清不掉也不影响这次汇报。
    }
    if (!ref.mounted) return;
    if (outcome == core_update.UpdateAftermath.applied) {
      state = UpdateState(
        phase: UpdatePhase.upToDate,
        note: '已更新到 ${kAppVersion.label}（目标 ${pending.tag}）',
      );
      return;
    }
    state = UpdateState(
      phase: UpdatePhase.problem,
      failure: DsFailure(
        '上次更新没有生效：现在还是 ${kAppVersion.label}',
        hint: '目标版本是 ${pending.tag}。覆盖脚本的日志在数据目录的 '
            r'update\apply.log；也可以到项目发布页手动下载 zip 解压覆盖。',
      ),
    );
  }

  /// 检查更新。[repoRaw] 是设置里那一格（整条地址也认；**留空 = 用内置仓库**）。
  ///
  /// [tokenRaw] 是可选的访问令牌（第四十轮）：私有仓库、账号被 GitHub 限制可见性
  ///（匿名读什么都是 404）、以及匿名 60 次/小时的额度，三种情况都靠它。空 = 匿名。
  Future<void> check(String repoRaw, {String tokenRaw = ''}) async {
    _token = tokenRaw.trim();
    // 留空就用内置的更新源（第四十一轮）：从哪更新是产品的一部分，
    // 不该要求用户去仓库页面抄 `owner/repo`；那一格只是"换成别的仓库"的覆盖入口。
    final String? slug = core_update.normalizeRepoSlug(core_update.effectiveUpdateRepo(repoRaw));
    if (slug == null) {
      state = const UpdateState(
        phase: UpdatePhase.problem,
        failure: DsFailure(
          '「更新源」填的不是仓库地址：要的是 `用户名/仓库名` 两段',
          hint: '**留空**就用内置的更新源（不用填）；只有想换成自己的仓库时才需要写：'
              '在浏览器打开仓库，地址栏里 github.com/ 后面的两段就是它'
              '（例如 github.com/abc/DSAnima → 填 abc/DSAnima）；整条地址直接粘也认。',
        ),
      );
      return;
    }
    state = UpdateState(phase: UpdatePhase.checking, slug: slug);
    try {
      final core_update.ReleaseInfo release =
          await ref.read(updatePortProvider).latestRelease(slug, token: _token);
      final core_update.UpdateDecision decision =
          core_update.decideUpdate(current: kAppVersion, latest: release);
      if (!ref.mounted) return;
      final DateTime now = DateTime.now();
      switch (decision) {
        case core_update.UpdateUpToDate():
          state = UpdateState(
            phase: UpdatePhase.upToDate,
            slug: slug,
            release: release,
            checkedAt: now,
            note: '已是最新（远端 ${release.tag}）',
          );
        case core_update.UpdateAvailable(:final core_update.ReleaseAsset asset):
          state = UpdateState(
            phase: UpdatePhase.available,
            slug: slug,
            release: release,
            asset: asset,
            total: asset.sizeBytes > 0 ? asset.sizeBytes : null,
            checkedAt: now,
          );
        case core_update.UpdateNoAsset():
          state = UpdateState(
            phase: UpdatePhase.problem,
            slug: slug,
            release: release,
            checkedAt: now,
            failure: DsFailure(
              '有新版本 ${release.tag}，但这次发布里没有可用的更新包',
              hint: '发布 Release 时要把 `tool/release_github.ps1` 打出来的 '
                  '`DSAnima-*-win-x64.zip` 传成 asset（名字里带 win-x64、以 .zip 结尾）。',
            ),
          );
        case core_update.UpdateUnparsableTag(:final String tag):
          state = UpdateState(
            phase: UpdatePhase.problem,
            slug: slug,
            release: release,
            checkedAt: now,
            failure: DsFailure(
              '最新发布的标签是 `$tag`，不是版本号，没法比较',
              hint: '发布时标签写成 `v1.0.1` 这种形态（`tool/release_github.ps1` 会自动这么打）。',
            ),
          );
      }
    } on PortUnavailableException catch (error) {
      if (!ref.mounted) return;
      state = UpdateState(
        phase: UpdatePhase.problem,
        slug: slug,
        failure: DsFailure(error.message, hint: error.hint),
      );
    } catch (error) {
      if (!ref.mounted) return;
      state = UpdateState(phase: UpdatePhase.problem, slug: slug, failure: describeFailure(error));
    }
  }

  /// 下载更新包（可中途 [cancelDownload]）。
  Future<void> download() async {
    final core_update.ReleaseAsset? asset = state.asset;
    if (asset == null || state.phase == UpdatePhase.downloading) return;
    _cancelRequested = false;
    state = state.copyWith(
      phase: UpdatePhase.downloading,
      received: 0,
      total: asset.sizeBytes > 0 ? asset.sizeBytes : null,
      failure: null,
      note: null,
    );
    try {
      final File file = await ref.read(updatePortProvider).downloadAsset(
        asset,
        token: _token,
        onProgress: (int received, int? total) {
          if (!ref.mounted) return;
          state = state.copyWith(received: received, total: total ?? state.total);
        },
        isCancelled: () => _cancelRequested,
      );
      if (!ref.mounted) return;
      state = state.copyWith(
        phase: UpdatePhase.ready,
        package: file,
        received: asset.sizeBytes > 0 ? asset.sizeBytes : state.received,
        note: '下载完成：${asset.name}',
      );
    } on PortUnavailableException catch (error) {
      if (!ref.mounted) return;
      if (_cancelRequested) {
        state = state.copyWith(phase: UpdatePhase.available, failure: null, note: '已取消下载');
      } else {
        state = state.copyWith(
          phase: UpdatePhase.problem,
          failure: DsFailure(error.message, hint: error.hint),
          note: null,
        );
      }
    } catch (error) {
      if (!ref.mounted) return;
      state = state.copyWith(
        phase: UpdatePhase.problem,
        failure: describeFailure(error),
        note: null,
      );
    } finally {
      _cancelRequested = false;
    }
  }

  /// 请下载线程在下一块之后停下；半截文件由端口实现负责删掉。
  void cancelDownload() {
    if (state.phase == UpdatePhase.downloading) _cancelRequested = true;
  }

  /// 解压 + 写覆盖脚本 + 启动它，然后**退出本进程**（新版本会自己起来）。
  Future<void> apply() async {
    final File? file = state.package;
    final core_update.ReleaseInfo? release = state.release;
    if (file == null || release == null || state.phase == UpdatePhase.applying) return;
    state = state.copyWith(phase: UpdatePhase.applying, failure: null, note: null);
    final UpdatePort port = ref.read(updatePortProvider);
    try {
      await port.declarePending(
        core_update.PendingUpdate(
          tag: release.tag,
          target: release.version ?? kAppVersion,
          startedAt: DateTime.now(),
          packagePath: file.path,
        ),
      );
    } catch (error) {
      if (!ref.mounted) return;
      state = state.copyWith(phase: UpdatePhase.problem, failure: describeFailure(error));
      return;
    }
    try {
      await port.prepareUpdate(file);
    } catch (error) {
      // 更新根本没开始（解压失败/脚本起不来）→ 撤掉刚写下的待办，
      // 否则下次启动会报"上次更新没有生效"，而那次压根没开始。
      await _abortPending(port);
      if (!ref.mounted) return;
      state = state.copyWith(phase: UpdatePhase.problem, failure: describeFailure(error));
      return;
    }
    if (!ref.mounted) return;
    state = state.copyWith(
      phase: UpdatePhase.applying,
      note: '更新脚本已启动：DSAnima 会退出，几秒后自动以新版本打开'
          '（若没自动起来，双击安装目录里的 dsanima.exe 即可，更新已经落地）',
    );
    // 退出必须走宿主统一流程（先放 Hive 锁、再停边车）。`exit(0)` 在里面，
    // 所以这里不 await 它 —— 但它要是**起不来**（没登记/抛错），必须说出来。
    unawaited(_quitAfterUpdate());
  }

  Future<void> _quitAfterUpdate() async {
    try {
      await ref.read(quitAppProvider)();
    } catch (error) {
      if (!ref.mounted) return;
      state = state.copyWith(
        phase: UpdatePhase.problem,
        failure: DsFailure(
          '更新脚本已启动，但退出程序失败：$error',
          hint: '手动关掉 DSAnima 再打开：覆盖脚本会在进程消失后自动完成更新。',
        ),
      );
    }
  }

  /// 撤掉待办记录（失败就算了：它只影响下次启动那句提示）。
  Future<void> _abortPending(UpdatePort port) async {
    try {
      await port.declarePending(null);
    } catch (_) {
      // 忽略：不因为清不掉一条记录而盖住真正的失败原因。
    }
  }

  /// 把状态清回"没检查过"（用户点了「重新检查」）。
  void reset() {
    _token = '';
    state = const UpdateState();
  }
}

final NotifierProvider<UpdateController, UpdateState> updateProvider =
    NotifierProvider<UpdateController, UpdateState>(UpdateController.new);

/// 「立刻退出程序」的**登记处**。
///
/// 为什么是登记处而不是 provider override：容器在启动早期就建好了，而
/// `CloseCoordinator`（唯一知道怎么正确收尾的人：先放 Hive 锁 → 再停边车 →
/// `exit(0)`）是启动末尾才建出来的 —— override 改不了已经建好的容器。
///
/// 为什么不让 UI 直接 `exit(0)`：退出顺序是"血的教训"（`domain/exit_runner.dart`
/// 那套逐步预算 + 总闸就是为它写的），复制一份迟早会走偏 —— 尤其是更新这一路，
/// Hive 的 `<box>.lock` 不放掉，新版本重启后会撞锁。
class QuitRegistrar {
  Future<void> Function()? _quit;

  /// 装配根在启动末尾登记（`main.dart`）。
  void register(Future<void> Function() quit) => _quit = quit;

  /// 真的有人登记了吗（测试/未装配时为 false）。
  bool get isRegistered => _quit != null;

  /// 触发退出。**没登记就抛** —— 与其它"未接通"同一条规矩，绝不假装已退出。
  Future<void> call() async {
    final Future<void> Function()? quit = _quit;
    if (quit == null) {
      throw StateError('还没有登记退出回调（quitAppProvider）：装配根要先走完启动');
    }
    await quit();
  }
}

final Provider<QuitRegistrar> quitAppProvider =
    Provider<QuitRegistrar>((Ref ref) => QuitRegistrar());
