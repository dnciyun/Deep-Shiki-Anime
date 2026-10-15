/// 默认下载目录（用户 2026-10-11：「下载目录默认在 `C:\Users\用户名\Downloads\Anime`」）。
///
/// 这一层守三件事：
/// * 解析规则是**纯函数 + 注入环境变量**：USERPROFILE → HOMEDRIVE+HOMEPATH → 空串
///   （**不猜盘符**，拿不到就维持原来的"还没有设置下载目录"报错）；
/// * 归一化：尾部多余分隔符去掉、`/` 统一成 `\`，但**盘符根**（`C:\`）不能被吞成 `C:`；
/// * 「生效值」语义：设置里有值用设置值，否则用默认值 —— 引擎启动、设置页显示、
///   首启向导预填读的都是这一个函数，三者不可能各说一套。
library;

import 'dart:io';

import 'package:dsanima/domain/download_dir.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/ui/first_run.dart';
import 'package:dsanima/ui/settings_page.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 首启向导的最小脚手架：假端口 + 内存设置（不联网、不起引擎）。
Widget _wizard(AppSettings settings) => ProviderScope(
  overrides: [
    keyValueStoreProvider.overrideWithValue(
      InMemoryKeyValueStore(<String, Object?>{
        SettingsController.storageKey: settings.toJson(),
      }),
    ),
    sourcePortProvider.overrideWithValue(const UnavailableSourcePort()),
    engineBootstrapPortProvider.overrideWithValue(const UnavailableEngineBootstrapPort()),
    pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
  ],
  child: MaterialApp(theme: buildDsanimaTheme(), home: const FirstRunPage()),
);

/// 设置页的最小脚手架（假端口 + 内存设置）。
Widget _settings(InMemoryKeyValueStore store) => ProviderScope(
  overrides: [
    keyValueStoreProvider.overrideWithValue(store),
    supportDirProvider.overrideWithValue(Directory.systemTemp),
    sourcePortProvider.overrideWithValue(const UnavailableSourcePort()),
    engineBootstrapPortProvider.overrideWithValue(const UnavailableEngineBootstrapPort()),
    pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
    subsPortProvider.overrideWithValue(const UnavailableSubsPort()),
    queuePortProvider.overrideWithValue(const UnavailableQueuePort()),
    trayPortProvider.overrideWithValue(const UnavailableTrayPort()),
  ],
  child: MaterialApp(
    theme: buildDsanimaTheme(),
    home: const Scaffold(body: SettingsPage()),
  ),
);

void _sizeTo(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  group(r'resolveDefaultDownloadDir：%USERPROFILE%\Downloads\Anime', () {
    test('USERPROFILE 优先；分隔符统一成反斜杠', () {
      expect(
        resolveDefaultDownloadDir(env: <String, String>{'USERPROFILE': r'C:\Users\anna'}),
        r'C:\Users\anna\Downloads\Anime',
      );
    });

    test('尾部多余分隔符不会拼出双反斜杠（正斜杠也归一化）', () {
      expect(
        resolveDefaultDownloadDir(env: <String, String>{'USERPROFILE': r'C:\Users\anna\'}),
        r'C:\Users\anna\Downloads\Anime',
      );
      expect(
        resolveDefaultDownloadDir(env: <String, String>{'USERPROFILE': 'C:/Users/anna/'}),
        r'C:\Users\anna\Downloads\Anime',
      );
      expect(
        resolveDefaultDownloadDir(env: <String, String>{'USERPROFILE': '  C:\\Users\\anna  '}),
        r'C:\Users\anna\Downloads\Anime',
      );
    });

    test('USERPROFILE 缺失 → 用 HOMEDRIVE + HOMEPATH 拼', () {
      expect(
        resolveDefaultDownloadDir(
          env: <String, String>{'HOMEDRIVE': 'H:', 'HOMEPATH': r'\Users\anna'},
        ),
        r'H:\Users\anna\Downloads\Anime',
      );
      // HOMEPATH 不带前导斜杠也要拼对（老系统上两种写法都见过）。
      expect(
        resolveDefaultDownloadDir(
          env: <String, String>{'HOMEDRIVE': r'H:\', 'HOMEPATH': 'Users/anna'},
        ),
        r'H:\Users\anna\Downloads\Anime',
      );
    });

    test('USERPROFILE 是空白 → 当作缺失，回落 HOMEDRIVE + HOMEPATH', () {
      expect(
        resolveDefaultDownloadDir(
          env: <String, String>{
            'USERPROFILE': '   ',
            'HOMEDRIVE': 'H:',
            'HOMEPATH': r'\Users\anna',
          },
        ),
        r'H:\Users\anna\Downloads\Anime',
      );
    });

    test('都拿不到 → 空串（绝不猜盘符）', () {
      expect(resolveDefaultDownloadDir(env: <String, String>{}), '');
      expect(
        resolveDefaultDownloadDir(env: <String, String>{'HOMEDRIVE': 'H:'}),
        '',
        reason: '只有 HOMEDRIVE、没有 HOMEPATH：拼不出用户目录，不许编',
      );
      expect(
        resolveDefaultDownloadDir(env: <String, String>{'HOMEPATH': r'\Users\anna'}),
        '',
        reason: '只有 HOMEPATH：更不许猜一个 C:',
      );
      expect(
        resolveDefaultDownloadDir(env: <String, String>{'USERPROFILE': '  ', 'HOMEPATH': '  '}),
        '',
      );
    });
  });

  group('effectiveDownloadDir：设置值优先，否则默认值', () {
    const Map<String, String> env = <String, String>{'USERPROFILE': r'C:\Users\anna'};

    test('设置里有值 → 用设置值（默认目录不参与）', () {
      expect(effectiveDownloadDir(r'F:\Anime', env: env), r'F:\Anime');
    });

    test('设置值的尾部斜杠被去掉；但盘符根不能被吞成裸盘符', () {
      expect(effectiveDownloadDir(r'F:\Anime\', env: env), r'F:\Anime');
      expect(effectiveDownloadDir('F:/Anime//', env: env), r'F:\Anime');
      expect(effectiveDownloadDir(r'D:\', env: env), r'D:\', reason: r'C:\ 是盘符根，语义与 C: 不同');
    });

    test('设置为 null / 空串 / 空白 → 用默认值', () {
      expect(effectiveDownloadDir(null, env: env), r'C:\Users\anna\Downloads\Anime');
      expect(effectiveDownloadDir('', env: env), r'C:\Users\anna\Downloads\Anime');
      expect(effectiveDownloadDir('   ', env: env), r'C:\Users\anna\Downloads\Anime');
    });

    test('设置与默认都拿不到 → 空串（调用方据此维持"还没有设置下载目录"）', () {
      expect(effectiveDownloadDir(null, env: <String, String>{}), '');
      expect(effectiveDownloadDir('  ', env: <String, String>{}), '');
    });
  });

  group('首启向导：进第 ① 步就把默认下载目录填进草稿', () {
    final String expected = resolveDefaultDownloadDir();

    testWidgets('输入框已是默认目录，可以直接点「下一步」', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wizard(const AppSettings(firstRunCompleted: false)));
      await tester.pumpAndSettle();

      expect(find.text(expected), findsWidgets, reason: '用户 2026-10-11：输入框要预填默认目录');

      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();

      expect(find.text('② 启动并测试引擎'), findsOneWidget, reason: '预填了默认目录就不该再拦「还没有选下载目录」');
      expect(find.text('还没有选下载目录'), findsNothing);
    }, skip: expected.isEmpty);

    testWidgets('设置里已经选过目录 → 向导不覆盖它', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _wizard(const AppSettings(firstRunCompleted: false, downloadDir: r'F:\Anime')),
      );
      await tester.pumpAndSettle();

      expect(find.text(r'F:\Anime'), findsWidgets);
      expect(find.text(expected), findsNothing, reason: '有设置值时不该再出现默认目录');
    }, skip: expected.isEmpty);
  });

  group('设置页：空设置也看得见"真正会用哪个目录"', () {
    final String expected = resolveDefaultDownloadDir();

    testWidgets('下载目录框显示默认值 + 说明，且**不偷改**设置', (WidgetTester tester) async {
      _sizeTo(tester, const Size(1400, 3000));
      final InMemoryKeyValueStore store = InMemoryKeyValueStore(<String, Object?>{
        SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
      });

      await tester.pumpWidget(_settings(store));
      await tester.pumpAndSettle();

      expect(find.text(expected), findsWidgets, reason: '用户 2026-10-11：不要"空着但实际会用默认路径"的迷惑态');
      expect(find.textContaining('引擎用默认目录'), findsOneWidget, reason: '说明白"未设置 = 用默认"');

      // 显示默认值 ≠ 改设置：进一次设置页不该把默认值写进配置
      //（自动保存看门狗 1.2s 就会动手，所以这里必须真的等过它）。
      await tester.pump(const Duration(milliseconds: 1600));
      await tester.pumpAndSettle();
      final AppSettings persisted = AppSettings.fromJson(
        (store.get(SettingsController.storageKey) as Map?)?.cast<Object?, Object?>(),
      );
      expect(persisted.downloadDir, isNull, reason: '不脏就不落盘');
    }, skip: expected.isEmpty);

    testWidgets('设置里已有目录 → 框里就是那个目录', (WidgetTester tester) async {
      _sizeTo(tester, const Size(1400, 3000));
      final InMemoryKeyValueStore store = InMemoryKeyValueStore(<String, Object?>{
        SettingsController.storageKey: const AppSettings(
          firstRunCompleted: true,
          downloadDir: r'F:\Anime',
        ).toJson(),
      });

      await tester.pumpWidget(_settings(store));
      await tester.pumpAndSettle();

      expect(find.text(r'F:\Anime'), findsWidgets);
      expect(find.text(expected), findsNothing);
    }, skip: expected.isEmpty);
  });
}
