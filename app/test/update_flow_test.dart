/// 检查更新 / 直接更新（第三十九轮）的状态机。
///
/// 用户这一轮要求：
/// > 「加入检查更新，通过 githab 来实现直接更新」
///
/// 这里钉的都是**用户能看见的那句话**：填错了说填哪儿、已是最新、有新版本、
/// 下载进度、下载完等确认、退出后拿新版本、以及"上次更新到底成没成"的对账。
/// 端口的每个 IO 都用假实现，所以一个字节都不联网。
library;

import 'dart:async';
import 'dart:io';

import 'package:dsanima/domain/app_version.dart' show kAppVersion;
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/state/update.dart';
import 'package:dsanima_core/update/update.dart' as core_update;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假 release 的版本 = **比当前构建高一格**（patch +1）。
///
/// ⚠️ 为什么要算而不是写死 `v1.0.3`：这些用例验的是"**有新版本**"这条路，
/// 而比较基准是 [kAppVersion] —— 写死的那个号一旦被发布版追上（第四十八轮：
/// 上一轮把 app 抬到 `1.0.3+4`，这份用例当场全变成"已是最新"），
/// 用例就会静默地测错东西。
String get _newerTag =>
    'v${kAppVersion.major}.${kAppVersion.minor}.${kAppVersion.patch + 1}';

/// 与 [_newerTag] 对应的版本对象（`target` 用）。
core_update.AppVersion get _newerVersion => core_update.AppVersion(
  kAppVersion.major,
  kAppVersion.minor,
  kAppVersion.patch + 1,
);

/// 假端口：如实记录每次调用，并按开关抛错（"失败"必须真的抛，不能返回假成功）。
class _FakeUpdatePort implements UpdatePort {
  _FakeUpdatePort({required this.release});

  core_update.ReleaseInfo release;

  int checkCalls = 0;
  String? seenSlug;

  /// 第四十轮：检查与下载各自收到的那份令牌（要能一路带下去）。
  String? seenToken;
  String? seenDownloadToken;
  bool checkThrows = false;
  bool downloadThrows = false;
  bool prepareThrows = false;

  /// 卡住下载用（测"取消"）。
  Completer<void>? gate;

  bool cancelSeen = false;
  File? prepared;
  core_update.PendingUpdate? pending;
  final List<core_update.PendingUpdate?> declared = <core_update.PendingUpdate?>[];
  final List<int> progressBytes = <int>[];

  @override
  Future<core_update.ReleaseInfo> latestRelease(String repoSlug, {String token = ''}) async {
    checkCalls++;
    seenSlug = repoSlug;
    seenToken = token;
    if (checkThrows) {
      throw const PortUnavailableException('连不上 GitHub', hint: '在「设置 → 网络」配代理');
    }
    return release;
  }

  @override
  Future<File> downloadAsset(
    core_update.ReleaseAsset asset, {
    String token = '',
    void Function(int received, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    seenDownloadToken = token;
    onProgress?.call(1024, asset.sizeBytes);
    progressBytes.add(1024);
    await gate?.future;
    if (isCancelled?.call() ?? false) {
      cancelSeen = true;
      throw const PortUnavailableException('已取消下载', hint: '半截文件已经删掉');
    }
    if (downloadThrows) {
      throw const PortUnavailableException('下载中断（连接被重置）', hint: '重新点一次「下载更新包」');
    }
    onProgress?.call(asset.sizeBytes, asset.sizeBytes);
    progressBytes.add(asset.sizeBytes);
    return File(r'C:\Users\x\DSAnima-data\update\DSAnima-win-x64.zip');
  }

  @override
  Future<void> prepareUpdate(File package) async {
    if (prepareThrows) {
      throw const PortUnavailableException('更新包解压失败（PowerShell 退出码 1）', hint: '手动下载 zip');
    }
    prepared = package;
  }

  @override
  Future<core_update.PendingUpdate?> pendingUpdate() async => pending;

  @override
  Future<void> declarePending(core_update.PendingUpdate? value) async {
    declared.add(value);
    pending = value;
  }
}

core_update.ReleaseInfo _release({
  String? tag,
  List<String> assets = const <String>['DSAnima-20261015-win-x64.zip'],
}) =>
    core_update.ReleaseInfo.tryParse(<String, Object?>{
      'tag_name': tag ?? _newerTag,
      'name': 'DSAnima ${tag ?? _newerTag}',
      'body': '## 修复\n- 点下一集有反馈了',
      'published_at': '2026-10-15T13:00:00Z',
      'html_url': 'https://github.com/abc/DSAnima/releases/tag/${tag ?? _newerTag}',
      'draft': false,
      'prerelease': false,
      'assets': <Object?>[
        for (final String name in assets)
          <String, Object?>{
            'name': name,
            'browser_download_url':
                'https://github.com/abc/DSAnima/releases/download/${tag ?? _newerTag}/$name',
            'size': 4 * 1024 * 1024,
          },
      ],
    })!;

ProviderContainer _container(UpdatePort port, {Future<void> Function()? quit}) {
  final ProviderContainer container = ProviderContainer(
    overrides: [updatePortProvider.overrideWithValue(port)],
  );
  if (quit != null) container.read(quitAppProvider).register(quit);
  addTearDown(container.dispose);
  return container;
}

/// 让 `build()` 里那个不 await 的对账跑完。
Future<void> _settle() async {
  for (int i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('检查', () {
    test('更新源留空 = 用内置仓库（不用填也能检查）', () async {
      final _FakeUpdatePort port = _FakeUpdatePort(release: _release());
      final ProviderContainer container = _container(port);
      await container.read(updateProvider.notifier).check('');

      expect(port.checkCalls, 1, reason: '留空不是"没配"，而是用内置的更新源');
      expect(port.seenSlug, core_update.kBuiltinUpdateRepo);
      expect(container.read(updateProvider).phase, UpdatePhase.available);
    });

    test('填了个不是地址的东西：不请求网络，直接说清"留空也行"', () async {
      final _FakeUpdatePort port = _FakeUpdatePort(release: _release());
      final ProviderContainer container = _container(port);
      await container.read(updateProvider.notifier).check('  不是地址  ');

      expect(port.checkCalls, 0, reason: '填错了就别去打网络 —— 只会白挨一次 404');
      final UpdateState state = container.read(updateProvider);
      expect(state.phase, UpdatePhase.problem);
      expect(state.failure!.message, contains('两段'));
      expect(state.failure!.hint, contains('留空'));
      expect(state.failure!.hint, contains('github.com'));
    });

    test('访问令牌：检查时带上（剪掉两端空白），下载用的是同一份', () async {
      final _FakeUpdatePort port = _FakeUpdatePort(release: _release());
      final ProviderContainer container = _container(port);
      final UpdateController controller = container.read(updateProvider.notifier);

      await controller.check('abc/DSAnima', tokenRaw: ' github_pat_abc ');
      expect(port.seenToken, 'github_pat_abc', reason: '粘贴常带空格/换行，要剪掉');

      await controller.download();
      expect(
        port.seenDownloadToken,
        'github_pat_abc',
        reason: '下载必须跟检查用同一份令牌 —— 不然私有仓库/受限账号还是下不来',
      );
    });

    test('第二次检查不带令牌 = 退回匿名，不沿用上一次那份', () async {
      final _FakeUpdatePort port = _FakeUpdatePort(release: _release());
      final ProviderContainer container = _container(port);
      final UpdateController controller = container.read(updateProvider.notifier);

      await controller.check('abc/DSAnima', tokenRaw: 'ghp_x');
      expect(port.seenToken, 'ghp_x');
      await controller.check('abc/DSAnima');
      expect(port.seenToken, isEmpty, reason: '用户清空那一格之后就必须是匿名请求');
    });

    test('有更新：挑出 win-x64 的 zip，并把接口地址规范化', () async {
      final _FakeUpdatePort port = _FakeUpdatePort(
        release: _release(
          assets: <String>['DSAnima-20261015-win-x64.zip.sha256', 'DSAnima-20261015-win-x64.zip'],
        ),
      );
      final ProviderContainer container = _container(port);
      // 用户粘的是整条地址（他就这么干）—— 必须认。
      await container.read(updateProvider.notifier).check('https://github.com/abc/DSAnima');

      expect(port.seenSlug, 'abc/DSAnima');
      final UpdateState state = container.read(updateProvider);
      expect(state.phase, UpdatePhase.available);
      expect(state.slug, 'abc/DSAnima');
      expect(state.asset!.name, 'DSAnima-20261015-win-x64.zip');
      expect(state.total, 4 * 1024 * 1024);
      expect(state.checkedAt, isNotNull);
    });

    test('远端比本地旧 / 一样 → 已是最新（自编译的测试版也算）', () async {
      final _FakeUpdatePort port = _FakeUpdatePort(release: _release(tag: 'v1.0.0'));
      final ProviderContainer container = _container(port);
      await container.read(updateProvider.notifier).check('abc/DSAnima');

      final UpdateState state = container.read(updateProvider);
      expect(state.phase, UpdatePhase.upToDate);
      expect(state.note, contains('已是最新'));
    });

    test('有新版本但没有可用 zip：单独说清楚（不能说"已是最新"）', () async {
      final _FakeUpdatePort port = _FakeUpdatePort(release: _release(assets: <String>['setup.exe']));
      final ProviderContainer container = _container(port);
      await container.read(updateProvider.notifier).check('abc/DSAnima');

      final UpdateState state = container.read(updateProvider);
      expect(state.phase, UpdatePhase.problem);
      expect(state.failure!.message, contains('没有可用的更新包'));
      expect(state.failure!.hint, contains('win-x64'));
    });

    test('标签不是版本号：说清标签该写成什么样', () async {
      final _FakeUpdatePort port = _FakeUpdatePort(release: _release(tag: 'nightly'));
      final ProviderContainer container = _container(port);
      await container.read(updateProvider.notifier).check('abc/DSAnima');

      final UpdateState state = container.read(updateProvider);
      expect(state.phase, UpdatePhase.problem);
      expect(state.failure!.message, contains('nightly'));
      expect(state.failure!.hint, contains('v1.0.1'));
    });

    test('网络失败：端口给的原话与"怎么办"原样展示', () async {
      final _FakeUpdatePort port = _FakeUpdatePort(release: _release())..checkThrows = true;
      final ProviderContainer container = _container(port);
      await container.read(updateProvider.notifier).check('abc/DSAnima');

      final UpdateState state = container.read(updateProvider);
      expect(state.phase, UpdatePhase.problem);
      expect(state.failure!.message, '连不上 GitHub');
      expect(state.failure!.hint, contains('代理'));
    });
  });

  group('下载', () {
    test('进度进状态；下完是 ready（等用户点确认，不偷偷替换）', () async {
      final _FakeUpdatePort port = _FakeUpdatePort(release: _release());
      final ProviderContainer container = _container(port);
      final UpdateController controller = container.read(updateProvider.notifier);
      await controller.check('abc/DSAnima');
      await controller.download();

      final UpdateState state = container.read(updateProvider);
      expect(state.phase, UpdatePhase.ready);
      expect(state.received, 4 * 1024 * 1024);
      expect(state.progress, 1.0);
      expect(state.package!.path, endsWith('DSAnima-win-x64.zip'));
      expect(state.note, contains('下载完成'));
      expect(port.progressBytes.length, 2);
    });

    test('下载失败：退回 problem，原因与办法都在', () async {
      final _FakeUpdatePort port = _FakeUpdatePort(release: _release())..downloadThrows = true;
      final ProviderContainer container = _container(port);
      final UpdateController controller = container.read(updateProvider.notifier);
      await controller.check('abc/DSAnima');
      await controller.download();

      final UpdateState state = container.read(updateProvider);
      expect(state.phase, UpdatePhase.problem);
      expect(state.failure!.message, contains('下载中断'));
      expect(state.failure!.hint, contains('重新点'));
    });

    test('取消下载：退回可下载，并留一句"已取消"', () async {
      final _FakeUpdatePort port = _FakeUpdatePort(release: _release());
      port.gate = Completer<void>();
      final ProviderContainer container = _container(port);
      final UpdateController controller = container.read(updateProvider.notifier);
      await controller.check('abc/DSAnima');

      final Future<void> downloading = controller.download();
      controller.cancelDownload();
      port.gate!.complete();
      await downloading;

      expect(port.cancelSeen, isTrue);
      final UpdateState state = container.read(updateProvider);
      expect(state.phase, UpdatePhase.available);
      expect(state.note, '已取消下载');
      expect(state.failure, isNull);
    });
  });

  group('重启并更新', () {
    test('写待办 → 交给覆盖脚本 → 走宿主统一退出', () async {
      final _FakeUpdatePort port = _FakeUpdatePort(release: _release());
      int quitCalls = 0;
      final ProviderContainer container = _container(port, quit: () async {
        quitCalls++;
      });
      final UpdateController controller = container.read(updateProvider.notifier);
      await controller.check('abc/DSAnima');
      await controller.download();
      await controller.apply();
      await _settle();

      expect(port.prepared, isNotNull);
      expect(port.declared.single!.tag, _newerTag);
      expect(port.declared.single!.target, _newerVersion);
      expect(quitCalls, 1, reason: '必须真的走宿主那条退出流程（先放 Hive 锁再停边车）');
      expect(container.read(updateProvider).note, contains('更新脚本已启动'));
    });

    test('覆盖脚本没起来：不退出程序，如实报错，并撤掉待办', () async {
      final _FakeUpdatePort port = _FakeUpdatePort(release: _release())..prepareThrows = true;
      int quitCalls = 0;
      final ProviderContainer container = _container(port, quit: () async {
        quitCalls++;
      });
      final UpdateController controller = container.read(updateProvider.notifier);
      await controller.check('abc/DSAnima');
      await controller.download();
      await controller.apply();
      await _settle();

      final UpdateState state = container.read(updateProvider);
      expect(state.phase, UpdatePhase.problem);
      expect(state.failure!.message, contains('解压'));
      expect(quitCalls, 0, reason: '都没准备好就别把程序切走');
      // 写下的待办要撤掉：否则下次启动会说"上次更新没生效"，而那次压根没开始。
      expect(port.declared, hasLength(2));
      expect(port.declared.first, isNotNull);
      expect(port.declared.last, isNull);
      expect(port.pending, isNull);
    });

    test('没登记退出回调：不假装已退出，把原因说出来', () async {
      final _FakeUpdatePort port = _FakeUpdatePort(release: _release());
      final ProviderContainer container = _container(port); // 不登记 quit
      final UpdateController controller = container.read(updateProvider.notifier);
      await controller.check('abc/DSAnima');
      await controller.download();
      await controller.apply();
      await _settle();

      final UpdateState state = container.read(updateProvider);
      expect(state.phase, UpdatePhase.problem);
      expect(state.failure!.message, contains('退出程序'));
      expect(state.failure!.hint, contains('手动'));
    });
  });

  group('重启之后对账（覆盖是另一个进程干的活，宿主看不见）', () {
    test('版本到位：记一句"已更新"，并清掉待办（不每次启动都念）', () async {
      final _FakeUpdatePort port = _FakeUpdatePort(release: _release());
      port.pending = core_update.PendingUpdate(
        tag: 'v1.0.0',
        target: const core_update.AppVersion(1, 0, 0),
        startedAt: DateTime(2026, 10, 15, 12),
      );
      final ProviderContainer container = _container(port);
      container.read(updateProvider); // 触发 build 里的对账
      await _settle();

      final UpdateState state = container.read(updateProvider);
      expect(state.note, contains('已更新到'));
      expect(port.declared, <core_update.PendingUpdate?>[null]);
    });

    test('还是老版本：明说"上次更新没有生效"，并指出日志在哪', () async {
      final _FakeUpdatePort port = _FakeUpdatePort(release: _release());
      port.pending = core_update.PendingUpdate(
        tag: _newerTag,
        target: _newerVersion,
        startedAt: DateTime(2026, 10, 15, 12),
      );
      final ProviderContainer container = _container(port);
      container.read(updateProvider);
      await _settle();

      final UpdateState state = container.read(updateProvider);
      expect(state.phase, UpdatePhase.problem);
      expect(state.failure!.message, contains('没有生效'));
      expect(state.failure!.hint, contains('apply.log'));
      expect(port.declared, <core_update.PendingUpdate?>[null]);
    });

    test('没有待办（没更新过）：安静不动', () async {
      final _FakeUpdatePort port = _FakeUpdatePort(release: _release());
      final ProviderContainer container = _container(port);
      container.read(updateProvider);
      await _settle();

      final UpdateState state = container.read(updateProvider);
      expect(state.phase, UpdatePhase.idle);
      expect(state.note, isNull);
      expect(state.failure, isNull);
      expect(port.declared, isEmpty);
    });
  });
}
