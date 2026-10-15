/// 设置页第 ⑤ 组「软件更新」（第三十九轮）。
///
/// 用户这一轮要求：
/// > 「加入检查更新，通过 githab 来实现直接更新」
///
/// 这里钉的是**界面真的接上了**：更新源那一格读的是保存过的值、点「检查更新」会走端口、
/// 有新版本才出现「下载更新包」、下完才出现「立即重启并更新」。
/// （状态机本身的那几条在 `update_flow_test.dart` 里逐条钉。）
library;

import 'dart:io';

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/ui/settings_page.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:dsanima_core/update/update.dart' as core_update;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Lifecycle implements LifecyclePort {
  @override
  Future<void> applySettings(AppSettings settings) async {}
}

/// 假更新端口：只回答"有新版本 + 能下"。
class _FakeUpdatePort implements UpdatePort {
  int checkCalls = 0;
  int downloadCalls = 0;

  /// 第四十轮：端口收到的那份令牌。
  String? seenToken;
  String? seenDownloadToken;

  @override
  Future<core_update.ReleaseInfo> latestRelease(String repoSlug, {String token = ''}) async {
    checkCalls++;
    seenToken = token;
    return core_update.ReleaseInfo.tryParse(<String, Object?>{
      'tag_name': 'v1.0.3',
      'name': 'DSAnima 1.0.2',
      'body': '## 修复\n- 点下一集有反馈了',
      'html_url': 'https://github.com/abc/DSAnima/releases/tag/v1.0.3',
      'draft': false,
      'assets': <Object?>[
        <String, Object?>{
          'name': 'DSAnima-20261016-win-x64.zip',
          'browser_download_url': 'https://example.invalid/x.zip',
          'size': 4194304,
        },
      ],
    })!;
  }

  @override
  Future<File> downloadAsset(
    core_update.ReleaseAsset asset, {
    String token = '',
    void Function(int received, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    downloadCalls++;
    seenDownloadToken = token;
    onProgress?.call(asset.sizeBytes, asset.sizeBytes);
    return File(r'C:\tmp\DSAnima-20261016-win-x64.zip');
  }

  @override
  Future<void> prepareUpdate(File package) async {}

  @override
  Future<core_update.PendingUpdate?> pendingUpdate() async => null;

  @override
  Future<void> declarePending(core_update.PendingUpdate? pending) async {}
}

InMemoryKeyValueStore _store({String updateRepo = 'abc/DSAnima', String updateToken = ''}) =>
    InMemoryKeyValueStore(<String, Object?>{
      SettingsController.storageKey: AppSettings(
        firstRunCompleted: true,
        updateRepo: updateRepo,
        updateToken: updateToken,
      ).toJson(),
    });

Widget _harness(InMemoryKeyValueStore store, UpdatePort updatePort) => ProviderScope(
  overrides: [
    keyValueStoreProvider.overrideWithValue(store),
    supportDirProvider.overrideWithValue(Directory.systemTemp),
    lifecyclePortProvider.overrideWithValue(_Lifecycle()),
    pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
    subsPortProvider.overrideWithValue(const UnavailableSubsPort()),
    queuePortProvider.overrideWithValue(const UnavailableQueuePort()),
    updatePortProvider.overrideWithValue(updatePort),
  ],
  child: MaterialApp(
    theme: buildDsanimaTheme(),
    home: const Scaffold(body: SettingsPage()),
  ),
);

/// 第 ⑤ 组在设置页最下面：`ListView` 只建可见的 child，不滚过去 `find` 是找不到的。
Future<void> _scrollToUpdateSection(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('软件更新'),
    320,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

/// 点一个会随着状态长出来的按钮：先把它滚进视口再点
/// （设置页底部的保存条下面没有空间，状态一长按钮就落到 1200px 之外 —— 那是真的点不到）。
Future<void> _tapVisible(WidgetTester tester, String label) async {
  final Finder finder = find.text(label);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('「更新 · 版本」分组在：显示当前版本、更新源那一格读的是保存过的值', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(_store(), _FakeUpdatePort()));
    await tester.pumpAndSettle();
    await _scrollToUpdateSection(tester);

    expect(find.textContaining('更新 · 版本'), findsOneWidget);
    expect(find.text('软件更新'), findsOneWidget);
    expect(find.textContaining('当前 v'), findsOneWidget);
    expect(find.text('更新源：用户名/仓库名'), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
    // 接口地址（用户问的就是"api 在哪"）：填好更新源之后就显示真正会请求的那条。
    expect(
      find.textContaining('https://api.github.com/repos/abc/DSAnima/releases/latest'),
      findsOneWidget,
    );
  });

  testWidgets('访问令牌那一格（第四十轮）：密码框、读保存过的值、空的时候说明指向只读令牌', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // ① 已经保存过令牌 → 这一格必须读出来，而且是**密码框**（不该明晃晃显示在屏幕上）。
    await tester.pumpWidget(_harness(_store(updateToken: 'github_pat_probe'), _FakeUpdatePort()));
    await tester.pumpAndSettle();
    await _scrollToUpdateSection(tester);

    expect(find.text('访问令牌（可选）'), findsOneWidget);
    final EditableText field = tester.widget<EditableText>(
      find.descendant(
        of: find.widgetWithText(TextFormField, '访问令牌（可选）'),
        matching: find.byType(EditableText),
      ),
    );
    expect(field.obscureText, isTrue, reason: '令牌不该明晃晃显示在屏幕上');
    expect(field.controller.text, 'github_pat_probe', reason: '这一格要读保存过的值');

    // ② 空的时候 → 那一行说明要告诉用户去哪生成、勾哪个权限（只读就够）。
    await tester.pumpWidget(_harness(_store(), _FakeUpdatePort()));
    await tester.pumpAndSettle();
    await _scrollToUpdateSection(tester);
    expect(find.textContaining('Contents: Read-only'), findsWidgets);
    expect(find.textContaining('Fine-grained tokens'), findsWidgets);
    expect(find.textContaining('匿名额度 60 次/小时'), findsWidgets);
  });

  testWidgets('填令牌 → 保存并生效 → 真的写进设置（不然重启后又得重填）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final InMemoryKeyValueStore store = _store();
    await tester.pumpWidget(_harness(store, _FakeUpdatePort()));
    await tester.pumpAndSettle();
    await _scrollToUpdateSection(tester);

    await tester.enterText(
      find.widgetWithText(TextFormField, '访问令牌（可选）'),
      'github_pat_saved',
    );
    await tester.pumpAndSettle();
    await _tapVisible(tester, '保存并生效');

    final Map<String, Object?> saved =
        Map<String, Object?>.from(store.get(SettingsController.storageKey)! as Map);
    expect(saved['updateToken'], 'github_pat_saved');
  });

  testWidgets('点「检查更新」→ 有新版本 → 点「下载更新包」→ 出现「立即重启并更新」', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _FakeUpdatePort port = _FakeUpdatePort();
    await tester.pumpWidget(_harness(_store(updateToken: 'ghp_from_settings'), port));
    await tester.pumpAndSettle();
    await _scrollToUpdateSection(tester);

    await _tapVisible(tester, '检查更新');
    expect(port.checkCalls, 1);
    expect(
      port.seenToken,
      'ghp_from_settings',
      reason: '界面上那一格的值要真的传到端口（第四十轮：不然填了等于没填）',
    );
    expect(find.textContaining('发现新版本 v1.0.3'), findsOneWidget);
    expect(find.text('下载更新包'), findsOneWidget);
    // 还没下载 → 不该出现"重启并更新"那颗按钮（不偷偷替换用户的程序）。
    expect(find.text('立即重启并更新'), findsNothing);

    await _tapVisible(tester, '下载更新包');
    expect(port.downloadCalls, 1);
    expect(find.textContaining('更新包已下载'), findsOneWidget);
    expect(find.text('立即重启并更新'), findsOneWidget);
  });

  testWidgets('更新源没填：不去请求，直接说清要填地址栏里那两段', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _FakeUpdatePort port = _FakeUpdatePort();
    await tester.pumpWidget(_harness(_store(updateRepo: ''), port));
    await tester.pumpAndSettle();
    await _scrollToUpdateSection(tester);

    expect(find.textContaining('地址栏里那两段'), findsOneWidget);
    await _tapVisible(tester, '检查更新');

    expect(port.checkCalls, 0);
    expect(find.textContaining('还没填对'), findsOneWidget);
    expect(find.textContaining('怎么办'), findsWidgets);
  });

  testWidgets('改了更新源：草稿变脏（要保存才记得住），检查用的是草稿里的值', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _FakeUpdatePort port = _FakeUpdatePort();
    await tester.pumpWidget(_harness(_store(updateRepo: ''), port));
    await tester.pumpAndSettle();
    await _scrollToUpdateSection(tester);

    await tester.enterText(
      find.ancestor(
        of: find.text('更新源：用户名/仓库名'),
        matching: find.byType(TextFormField),
      ),
      'abc/DSAnima',
    );
    await tester.pumpAndSettle();
    // 手动保存这一层照旧：底部条要立刻说"有未保存的改动"。
    expect(find.byKey(dsSettingsSaveBarTextKey), findsOneWidget);
    await tester.ensureVisible(find.byKey(dsSettingsSaveBarTextKey));
    expect(tester.widget<Text>(find.byKey(dsSettingsSaveBarTextKey)).data, contains('未保存'));

    await _tapVisible(tester, '检查更新');
    expect(port.checkCalls, 1, reason: '填完就能点，不必先保存');
    expect(find.textContaining('发现新版本'), findsOneWidget);
  });

  testWidgets('检查失败：原因与「怎么办」都摆在页面上', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _FailingUpdatePort port = _FailingUpdatePort();
    await tester.pumpWidget(_harness(_store(), port));
    await tester.pumpAndSettle();
    await _scrollToUpdateSection(tester);

    await _tapVisible(tester, '检查更新');
    expect(find.textContaining('连不上 GitHub'), findsOneWidget);
    expect(find.textContaining('怎么办'), findsWidgets);
  });
}

/// 端口抛错的那条路（网络失败）。
class _FailingUpdatePort extends _FakeUpdatePort {
  @override
  Future<core_update.ReleaseInfo> latestRelease(String repoSlug, {String token = ''}) async {
    throw const PortUnavailableException('连不上 GitHub（无网络）', hint: '在「设置 → 网络」配代理');
  }
}
