/// 「画面调节」取值落盘（`state/picture_settings_io.dart`）。
///
/// 背景：第四轮交付时把"参数不持久化"列在「已知没做」里 —— 关掉播放窗口再开、或者重启
/// 程序，滑杆全回到包的默认值，用户调过的锐度/对比白调。这一份钉的是**落盘那一层**的
/// 契约（真磁盘 + 临时目录，不碰播放器）：
///
/// * 路径固定 `<数据根>/dsanima/picture-settings.json`（文档/诊断都指这一条）；
/// * 读失败**永不抛**（坏文件只该退回默认，不能让播放窗口起不来）；
/// * 写盘**串行 + 原子**（防抖里连着两次 apply 不会互相踩、不留 `.tmp`、不会写出半截 json）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima/state/picture_pack.dart';
import 'package:dsanima/state/picture_settings_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Directory _newSupportDir() =>
    Directory.systemTemp.createTempSync('dsanima-picture-settings-');

void main() {
  group('落盘：<数据根>/dsanima/picture-settings.json', () {
    test('路径与文件名是固定口径（文档、诊断、测试共用一份）', () {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));

      expect(kPictureSettingsFileName, 'picture-settings.json');
      expect(pictureSettingsFileOf(support).path,
          p.join(support.path, 'dsanima', kPictureSettingsFileName));
    });

    test('存下来再读：包 / 预设 / 每档取值都在', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      final PictureSettingsStore store = PictureSettingsStore(support);

      const PictureSettings settings = PictureSettings(
        packId: 'dsanima-picture-crisp',
        presetId: 'crisp',
        values: <String, double>{'sharpen': 1.0, 'line': 0.45, 'gamma': 1.0005},
      );
      await store.save(settings);

      expect(await store.load(), settings);
      // 文件里是给人看得懂的 json（排障时能直接打开看）
      final Map<String, Object?> json =
          (jsonDecode(await store.file.readAsString()) as Map).cast<String, Object?>();
      expect(json['pack'], 'dsanima-picture-crisp');
      expect(json['preset'], 'crisp');
      expect((json['values']! as Map)['sharpen'], 1.0);
    });

    test('从来没存过 → 关（不是异常，也不偷偷写一个文件出来）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      final PictureSettingsStore store = PictureSettingsStore(support);

      expect(await store.load(), PictureSettings.off);
      expect(store.file.existsSync(), isFalse);
    });

    test('坏 json / 半截文件 → 关，不抛（旧版本或手改写坏只该退化）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      final PictureSettingsStore store = PictureSettingsStore(support);
      store.file.parent.createSync(recursive: true);

      File(store.file.path).writeAsStringSync('{"pack": "x", "values": {"sharpen":');
      expect(await store.load(), PictureSettings.off);

      // 结构不对（不是对象）也只退化
      File(store.file.path).writeAsStringSync('[1,2,3]');
      expect(await store.load(), PictureSettings.off);

      // 空文件（断电留下）同样
      File(store.file.path).writeAsStringSync('   ');
      expect(await store.load(), PictureSettings.off);
    });

    test('连写两次：后一次胜出，且没有 .tmp 残留（串行 + 原子）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      final PictureSettingsStore store = PictureSettingsStore(support);

      // 不 await 第一次：模拟"拖完滑杆立刻点重置"时两次保存几乎同时进来。
      final Future<void> first = store.save(const PictureSettings(
        packId: 'p',
        values: <String, double>{'sharpen': 0.2},
      ));
      final Future<void> second = store.save(const PictureSettings(
        packId: 'p',
        presetId: 'crisp',
        values: <String, double>{'sharpen': 1.2},
      ));
      await Future.wait(<Future<void>>[first, second]);

      expect((await store.load()).values['sharpen'], 1.2);
      expect(File('${store.file.path}.tmp').existsSync(), isFalse);
      expect(
        Directory(p.join(support.path, 'dsanima'))
            .listSync()
            .whereType<File>()
            .map((File f) => p.basename(f.path)),
        <String>[kPictureSettingsFileName],
      );
    });

    test('目录被删/不可写时保存不抛（存不下来最坏是这次没记住）', () async {
      final Directory missing = Directory(
        p.join(_newSupportDir().path, 'not-created-parent', 'support'),
      );
      addTearDown(() => missing.parent.deleteSync(recursive: true));
      final PictureSettingsStore store = PictureSettingsStore(missing);

      // 父目录不存在也没关系：_write 会 create(recursive: true)。
      await store.save(const PictureSettings(packId: 'p'));
      expect(await store.load(), const PictureSettings(packId: 'p'));
    });
  });
}
