import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shikiin/infra/anime4k_assets.dart';
import 'package:shikiin/models/anime4k_preset.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('a4k_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('解包写出全部 shader 文件，返回版本子目录', () async {
    var loads = 0;
    final dir = await unpackAnime4kShaders(
      loadAsset: (path) async { loads++; return utf8Bytes('// $path'); },
      targetRootDir: tmp.path,
      version: 'testv',
    );
    expect(p.basename(dir), 'anime4k_testv');
    for (final f in kAnime4kShaderFiles) {
      expect(File(p.join(dir, f)).existsSync(), isTrue, reason: '$f 未写出');
    }
    expect(loads, kAnime4kShaderFiles.length);
  });

  test('版本标记存在时跳过重复解包（不再读 asset）', () async {
    await unpackAnime4kShaders(
      loadAsset: (path) async => utf8Bytes('x'),
      targetRootDir: tmp.path, version: 'testv');
    var loads = 0;
    final dir = await unpackAnime4kShaders(
      loadAsset: (path) async { loads++; return utf8Bytes('x'); },
      targetRootDir: tmp.path, version: 'testv');
    expect(loads, 0, reason: '第二次不应再读 asset');
    expect(File(p.join(dir, kAnime4kShaderFiles.first)).existsSync(), isTrue);
  });
}

List<int> utf8Bytes(String s) => s.codeUnits;
