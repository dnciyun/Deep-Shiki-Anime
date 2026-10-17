import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shikiin/infra/anime4k_assets.dart';
import 'package:shikiin/models/upscale_scheme.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('a4k_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('解包写出全部 shader 文件（Anime4K 12 + Anime4K-Ultra 1），返回版本子目录', () async {
    var loads = 0;
    final dir = await unpackAnime4kShaders(
      loadAsset: (path) async { loads++; return utf8Bytes('// $path'); },
      targetRootDir: tmp.path,
      version: 'testv',
    );
    expect(p.basename(dir), 'anime4k_testv');
    for (final f in kBundledShaderFiles) {
      expect(File(p.join(dir, f)).existsSync(), isTrue, reason: '$f 未写出');
    }
    expect(loads, kBundledShaderFiles.length);
    // 内置方案引用的文件必须全部被解包（漏一个 → 真机 set 直接失败）。
    for (final scheme in builtinUpscaleSchemes()) {
      for (final f in scheme.files) {
        expect(File(p.join(dir, f)).existsSync(), isTrue, reason: '${scheme.id} 缺 $f');
      }
    }
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
    expect(File(p.join(dir, kBundledShaderFiles.first)).existsSync(), isTrue);
  });

  test('默认版本号是 v4.3（升 shader 集合时没改 → 老用户永远缺新文件）', () {
    expect(kAnime4kVersion, 'v4.3');
  });
}

List<int> utf8Bytes(String s) => s.codeUnits;
