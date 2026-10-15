import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/anime4k_preset.dart';

void main() {
  test('off 产出空链', () {
    expect(anime4kShaderChain(Anime4kPreset.off), isEmpty);
  });

  test('每个静态档位都产出非空链，且都以 Clamp_Highlights 开头', () {
    for (final p in Anime4kPreset.simpleTiers) {
      final chain = anime4kShaderChain(p);
      expect(chain, isNotEmpty, reason: '$p 链不应为空');
      expect(chain.first, 'Anime4K_Clamp_Highlights.glsl', reason: '$p 应以 Clamp 开头');
    }
  });

  test('链里引用的文件都在打包清单 kAnime4kShaderFiles 内', () {
    for (final p in Anime4kPreset.values) {
      for (final f in anime4kShaderChain(p)) {
        expect(kAnime4kShaderFiles, contains(f), reason: '$p 引用了未打包的 $f');
      }
    }
  });

  test('打包清单仍是 12 个文件名（app 侧解包逻辑依赖它）', () {
    expect(kAnime4kShaderFiles, hasLength(12));
    expect(kAnime4kShaderFiles, contains('Anime4K_Clamp_Highlights.glsl'));
  });

  test('标准档用 VL 模型，轻量档用较小模型', () {
    expect(anime4kShaderChain(Anime4kPreset.standard), contains('Anime4K_Upscale_CNN_x2_VL.glsl'));
    expect(anime4kShaderChain(Anime4kPreset.light), isNot(contains('Anime4K_Upscale_CNN_x2_VL.glsl')));
  });

  test('极致档 = A+A：Restore_CNN_VL 出现两次', () {
    final ultra = anime4kShaderChain(Anime4kPreset.ultra);
    expect(ultra.where((f) => f == 'Anime4K_Restore_CNN_VL.glsl').length, 2);
  });

  test('三档互不相同，且 Clamp 每档只出现一次', () {
    final chains = Anime4kPreset.simpleTiers.map(anime4kShaderChain).toList();
    expect(chains[0], isNot(chains[1]));
    expect(chains[1], isNot(chains[2]));
    for (final chain in chains) {
      expect(chain.where((f) => f == 'Anime4K_Clamp_Highlights.glsl').length, 1);
    }
  });

  test('simpleTiers 覆盖且不含 off', () {
    expect(Anime4kPreset.simpleTiers, [Anime4kPreset.light, Anime4kPreset.standard, Anime4kPreset.ultra]);
    expect(Anime4kPreset.simpleTiers.contains(Anime4kPreset.off), isFalse);
  });

  test('cycled：关→轻→标→极→关', () {
    expect(Anime4kPreset.off.cycled, Anime4kPreset.light);
    expect(Anime4kPreset.light.cycled, Anime4kPreset.standard);
    expect(Anime4kPreset.standard.cycled, Anime4kPreset.ultra);
    expect(Anime4kPreset.ultra.cycled, Anime4kPreset.off);
  });

  test('每个档位都有非空 label 与 hint（小字注释）', () {
    for (final p in Anime4kPreset.values) {
      expect(p.label, isNotEmpty, reason: '$p 缺 label');
      expect(p.hint, isNotEmpty, reason: '$p 缺 hint');
    }
    expect(Anime4kPreset.off.label, '关');
  });
}
