/// 扩展用户设置（`state/extension_settings.dart`）：预设开关 / 官方目录地址的落盘。
///
/// 守的是"改了没记住"和"文件坏了整页起不来"这两类：
/// * 设置写在 `<数据根>/dsanima/extension-settings.json`，**原子替换**（写一半被读到
///   等于"没有设置"，用户关掉的预设会自己回来）；
/// * 读盘永不抛（用户手改、旧版本写坏都只该退化）；
/// * 播放子窗口开窗时读同一份文件 —— 所以落盘格式必须和 `core` 的
///   `ExtensionUserSettings` 一致（这里用真实 fromJson 往返验一遍）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima/state/extension_settings.dart';
import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Directory _tmp() => Directory.systemTemp.createTempSync('dsanima-ext-settings-');

void main() {
  group('落盘 / 读回', () {
    test('写的文件在约定位置，且能被 core 原样读回来', () async {
      final Directory support = _tmp();
      addTearDown(() => support.deleteSync(recursive: true));
      final core.ExtensionUserSettings settings = core.ExtensionUserSettings.empty
          .withHiddenPresets('dsanima-picture-crisp', <String>{'warm', 'extreme'})
          .withCatalogUrl('https://github.com/o/r');

      await saveExtensionUserSettings(support, settings);

      final File file = extensionUserSettingsFileOf(support);
      expect(file.path, p.join(support.path, 'dsanima', 'extension-settings.json'));
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), isNot(contains('.tmp')));

      final core.ExtensionUserSettings back = await loadExtensionUserSettings(support);
      expect(back, settings);
      expect(back.hiddenPresetsOf('dsanima-picture-crisp'), <String>{'extreme', 'warm'});
      expect(back.catalogUrl, 'https://github.com/o/r');
    });

    test('没有文件 / 空文件 / 坏 json / 顶层不是对象 → 全是"没有设置"，不抛', () async {
      final Directory support = _tmp();
      addTearDown(() => support.deleteSync(recursive: true));
      expect(await loadExtensionUserSettings(support), core.ExtensionUserSettings.empty);

      final File file = extensionUserSettingsFileOf(support);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('   ');
      expect(await loadExtensionUserSettings(support), core.ExtensionUserSettings.empty);

      file.writeAsStringSync('{ not json');
      expect(await loadExtensionUserSettings(support), core.ExtensionUserSettings.empty);

      file.writeAsStringSync('"字符串"');
      expect(await loadExtensionUserSettings(support), core.ExtensionUserSettings.empty);
    });

    test('目录不存在时自己建（首启就改设置也不会失败）', () async {
      final Directory support = Directory(p.join(_tmp().path, 'deep', 'root'));
      addTearDown(() => support.existsSync() ? support.deleteSync(recursive: true) : null);
      await saveExtensionUserSettings(support, core.ExtensionUserSettings.empty);
      expect(extensionUserSettingsFileOf(support).existsSync(), isTrue);
    });
  });

  group('Notifier', () {
    test('ensureLoaded → 改预设 → 立刻落盘；再读回来一致', () async {
      final Directory support = _tmp();
      addTearDown(() => support.deleteSync(recursive: true));
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      final ExtensionUserSettingsController controller =
          container.read(extensionUserSettingsProvider.notifier);

      await controller.ensureLoaded(support);
      expect(container.read(extensionUserSettingsProvider), core.ExtensionUserSettings.empty);

      await controller.setHiddenPresets('pack.a', <String>{'warm'});
      expect(container.read(extensionUserSettingsProvider).hiddenPresetsOf('pack.a'),
          <String>{'warm'});
      // 写盘是用 await 的：这条断言证明"改完立刻写"，不是等关窗口。
      final core.ExtensionUserSettings onDisk = await loadExtensionUserSettings(support);
      expect(onDisk.hiddenPresetsOf('pack.a'), <String>{'warm'});

      // 新容器（模拟重开播放窗口）读到的是同一份
      final ProviderContainer second = ProviderContainer();
      addTearDown(second.dispose);
      await second.read(extensionUserSettingsProvider.notifier).ensureLoaded(support);
      expect(second.read(extensionUserSettingsProvider).hiddenPresetsOf('pack.a'),
          <String>{'warm'});
    });

    test('记住目录地址 / 卸载扩展时清掉它的设置', () async {
      final Directory support = _tmp();
      addTearDown(() => support.deleteSync(recursive: true));
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      final ExtensionUserSettingsController controller =
          container.read(extensionUserSettingsProvider.notifier);
      await controller.ensureLoaded(support);

      await controller.rememberCatalogUrl('https://github.com/o/r');
      await controller.setHiddenPresets('pack.a', <String>{'x'});
      await controller.forgetExtension('pack.a');

      final core.ExtensionUserSettings onDisk = await loadExtensionUserSettings(support);
      expect(onDisk.catalogUrl, 'https://github.com/o/r');
      expect(onDisk.hasExtensionSettings('pack.a'), isFalse);
    });

    test('还没 ensureLoaded 就改：只在内存里生效，不写盘、不抛', () async {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      final ExtensionUserSettingsController controller =
          container.read(extensionUserSettingsProvider.notifier);
      await controller.setHiddenPresets('pack.a', <String>{'x'});
      expect(container.read(extensionUserSettingsProvider).hiddenPresetsOf('pack.a'),
          <String>{'x'});
    });
  });

  test('写出去的是 utf8 明文 json（排障时能直接看）', () async {
    final Directory support = _tmp();
    addTearDown(() => support.deleteSync(recursive: true));
    await saveExtensionUserSettings(
      support,
      core.ExtensionUserSettings.empty.withHiddenPresets('包.a', <String>{'预设一'}),
    );
    final String text = extensionUserSettingsFileOf(support).readAsStringSync();
    final Object? json = jsonDecode(text);
    expect(json, isA<Map<String, Object?>>());
    expect(text, contains('包.a'));
  });
}
