/// 「我的组合」的模型与落盘（`domain/picture_combo.dart` + `state/picture_combos.dart`）。
///
/// 守的是一类"用户辛苦调的搭配某天不见了"的静默失败：
/// * 文件被手改坏一半 → 只该丢坏的那几项，别的组合还在；
/// * 同名组合被后者覆盖 → 用户存第二次就少一套；
/// * 菜单 id 拼装/拆解错位 → 点了「我的 · 夜间」套上去是别的取值（最难发现的一种）。
/// 全程临时目录、不联网。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima/domain/picture_combo.dart';
import 'package:dsanima/state/picture_combos.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Directory _newSupportDir() =>
    Directory.systemTemp.createTempSync('dsanima-picture-combo-');

File _combosFile(Directory support) => File(p.join(support.path, 'dsanima', kPictureCombosFileName));

void main() {
  group('组合 id：`<包>/custom:<组合>` 拼装与拆解', () {
    test('拼出来的格式就是约定的那一种', () {
      expect(pictureComboIdOf('p', 'c1'), 'p/custom:c1');
    });

    test('拆得回去（菜单里的值只认字符串）', () {
      expect(
        parsePictureComboId('p/custom:c1'),
        (packId: 'p', comboId: 'c1'),
      );
    });

    test('包自带预设（不带 custom: 前缀）→ null，不许被当成组合', () {
      expect(parsePictureComboId('p/preset'), isNull);
      expect(parsePictureComboId('p/customx:1'), isNull);
      expect(parsePictureComboId('p/custom:'), isNull);
      expect(parsePictureComboId('no-slash'), isNull);
      expect(parsePictureComboId('/custom:c1'), isNull);
    });
  });

  group('json → 组合表（永不抛，坏项跳过）', () {
    test('正常形状全部读出来（取值是数字）', () {
      final Map<String, List<PictureCombo>> combos = combosFromJson(<String, Object?>{
        'pack-a': <Object?>[
          <String, Object?>{
            'id': 'c1',
            'name': '夜间',
            'values': <String, Object?>{'sharpen': 0.7, 'line': 0.3},
          },
        ],
      });
      expect(combos['pack-a'], hasLength(1));
      expect(combos['pack-a']!.single.id, 'c1');
      expect(combos['pack-a']!.single.name, '夜间');
      expect(combos['pack-a']!.single.values, <String, double>{'sharpen': 0.7, 'line': 0.3});
    });

    test('不是 Map / 值不是 List → 空表，不抛', () {
      expect(combosFromJson(null), isEmpty);
      expect(combosFromJson('{ 这不是 json'), isEmpty);
      expect(combosFromJson(<String, Object?>{'pack-a': 'nope'}), isEmpty);
    });

    test('缺 id / name / values 的项被跳过，同表里好的项留下', () {
      final Map<String, List<PictureCombo>> combos = combosFromJson(<String, Object?>{
        'pack-a': <Object?>[
          <String, Object?>{'name': '没 id', 'values': <String, Object?>{'sharpen': 1}},
          <String, Object?>{'id': 'x', 'values': <String, Object?>{'sharpen': 1}},
          <String, Object?>{'id': 'y', 'name': '没 values'},
          <String, Object?>{'id': 'z', 'name': '好的', 'values': <String, Object?>{'sharpen': 0.5}},
          'not-a-map',
        ],
      });
      expect(combos['pack-a']!.map((PictureCombo c) => c.id), <String>['z']);
    });

    test('取值里的非数字项丢掉，不抛（手改文件把 0.5 写成字符串）', () {
      final Map<String, List<PictureCombo>> combos = combosFromJson(<String, Object?>{
        'pack-a': <Object?>[
          <String, Object?>{
            'id': 'c1',
            'name': '夜间',
            'values': <String, Object?>{'sharpen': '0.5', 'line': 1},
          },
        ],
      });
      expect(combos['pack-a']!.single.values, <String, double>{'line': 1});
    });

    test('同名不同 id 的两套都保留（存第二次不许覆盖第一套）', () {
      final Map<String, List<PictureCombo>> combos = combosFromJson(<String, Object?>{
        'pack-a': <Object?>[
          <String, Object?>{'id': 'c1', 'name': '夜间', 'values': <String, Object?>{'sharpen': 0.4}},
          <String, Object?>{'id': 'c2', 'name': '夜间', 'values': <String, Object?>{'sharpen': 0.9}},
        ],
      });
      expect(combos['pack-a']!.map((PictureCombo c) => c.id), <String>['c1', 'c2']);
    });
  });

  group('组合表 → json（空列表的包不写进文件）', () {
    test('有组合的包照写，空列表的包不写', () {
      final Map<String, Object?> json = combosToJson(<String, List<PictureCombo>>{
        'pack-a': <PictureCombo>[
          const PictureCombo(id: 'c1', name: '夜间', values: <String, double>{'sharpen': 0.4}),
        ],
        'pack-b': const <PictureCombo>[],
      });
      expect(json.keys, <String>['pack-a']);
      expect(json['pack-a'], <Object?>[
        <String, Object?>{
          'id': 'c1',
          'name': '夜间',
          'values': <String, Object?>{'sharpen': 0.4},
        },
      ]);
    });
  });

  group('落盘：写 → 读相等，坏文件只退化', () {
    test('往返：两个包、多套组合原样回来（含同名不同 id）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      final Map<String, List<PictureCombo>> byPack = <String, List<PictureCombo>>{
        'pack-a': <PictureCombo>[
          const PictureCombo(
            id: 'c1',
            name: '夜间',
            values: <String, double>{'sharpen': 0.4, 'line': 0.2},
          ),
          const PictureCombo(id: 'c2', name: '夜间', values: <String, double>{'sharpen': 0.9}),
        ],
        'pack-b': <PictureCombo>[
          const PictureCombo(id: 'c3', name: '白天', values: <String, double>{'line': 1}),
        ],
      };

      await PictureCombosStore(support).save(byPack);
      final Map<String, List<PictureCombo>> back = await PictureCombosStore(support).load();

      expect(back.keys.toSet(), byPack.keys.toSet());
      expect(back['pack-a'], byPack['pack-a']);
      expect(back['pack-b'], byPack['pack-b']);
    });

    test('文件不存在 → 空表，不抛', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      expect(await PictureCombosStore(support).load(), isEmpty);
    });

    test('半截 json → 空表，不抛（播放窗口随时可能读到写了一半的文件）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _combosFile(support)
        ..createSync(recursive: true)
        ..writeAsStringSync('{"pack-a": [{"id": "c1", "na');

      expect(await PictureCombosStore(support).load(), isEmpty);
    });

    test('保存是原子的：没有 .tmp 残留，正文是合法 json', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      await PictureCombosStore(support).save(<String, List<PictureCombo>>{
        'pack-a': <PictureCombo>[const PictureCombo(id: 'c1', name: '夜间')],
      });

      final File file = _combosFile(support);
      expect(file.existsSync(), isTrue);
      expect(File('${file.path}.tmp').existsSync(), isFalse);
      expect(jsonDecode(file.readAsStringSync()), isA<Map<String, Object?>>());
    });

    test('连续两次保存串行排队，第二次的结果是最终文件（不互相踩）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      final PictureCombosStore store = PictureCombosStore(support);

      // 不 await 第一笔：模拟"存完立刻删"这种连来两次的写。
      final Future<void> first = store.save(<String, List<PictureCombo>>{
        'pack-a': <PictureCombo>[const PictureCombo(id: 'c1', name: '一')],
      });
      final Future<void> second = store.save(<String, List<PictureCombo>>{
        'pack-a': <PictureCombo>[const PictureCombo(id: 'c2', name: '二')],
      });
      await Future.wait(<Future<void>>[first, second]);

      final Map<String, List<PictureCombo>> back = await store.load();
      expect(back['pack-a']!.single.id, 'c2');
    });
  });
}
