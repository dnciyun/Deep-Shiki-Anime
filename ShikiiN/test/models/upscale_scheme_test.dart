import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/anime4k_preset.dart';
import 'package:shikiin/models/upscale_scheme.dart';

void main() {
  final List<UpscaleScheme> schemes = builtinUpscaleSchemes();

  test('内置方案：Anime4K 默认在前 + 6 个随包 GLSL 方案，且不再有 mpv 缩放器', () {
    expect(schemes.first.id, kAnime4kSchemeId);
    expect(schemes.first.isAnime4k, isTrue);
    expect(schemes.map((s) => s.id).toList(), [
      kAnime4kSchemeId,
      'acnet',
      'acnet-hdn',
      'arnet',
      'anime4k-ultra',
      'fsr',
      'rcas',
    ]);
    // 用户 2026-10-17：「去除内置的mpv这套」—— 方案 id 里不能再出现 mpv-*。
    expect(schemes.where((s) => s.id.startsWith('mpv-')), isEmpty);
  });

  test('每个随包方案的文件都在随包清单里（写错文件名 → 真机 shader 目录缺文件）', () {
    for (final s in schemes.where((s) => !s.isAnime4k)) {
      expect(s.kind, UpscaleSchemeKind.glslPack);
      expect(s.files, isNotEmpty, reason: '${s.id} 没文件链');
      for (final f in s.files) {
        expect(kBundledPackShaderFiles, contains(f), reason: '${s.id} 引用了未打包的 $f');
      }
      expect(s.tiers, isEmpty, reason: 'glslPack 方案不分档');
      expect(s.dir, isNull, reason: '内置包用启动注入的 shader 目录');
    }
  });

  test('Anime4K 方案 = 三档（轻/标/极），链与 anime4kShaderChain 一致', () {
    final a4k = anime4kScheme();
    expect(a4k.tiers.map((t) => t.id), Anime4kPreset.simpleTiers.map((p) => p.name));
    for (final p in Anime4kPreset.simpleTiers) {
      final tier = a4k.tierOf(p.name)!;
      expect(tier.files, anime4kShaderChain(p));
    }
  });

  test('胶囊循环顺序：关 → Anime4K 轻/标/极 → 各随包方案 → 关', () {
    final order = UpscaleSelection.cycleOrder(schemes);
    expect(order.first, UpscaleSelection.off);
    expect(order[1], const UpscaleSelection(preset: Anime4kPreset.light));
    expect(order[2], const UpscaleSelection(preset: Anime4kPreset.standard));
    expect(order[3], const UpscaleSelection(preset: Anime4kPreset.ultra));
    expect(order[4].schemeId, 'acnet');
    expect(order.last.cycle(schemes), UpscaleSelection.off);
    expect(order.length, 4 + schemes.where((s) => !s.isAnime4k).length);
  });

  test('cycle 走完所有方案回到关，且不会卡在同一项', () {
    var s = UpscaleSelection.off;
    final seen = <UpscaleSelection>{s};
    for (var i = 0; i < schemes.length + 3; i++) {
      s = s.cycle(schemes);
      seen.add(s);
    }
    expect(s, UpscaleSelection.off);
    expect(seen.length, UpscaleSelection.cycleOrder(schemes).length);
  });

  test('胶囊文案：关 / Anime4K 档 / 随包方案短名', () {
    expect(UpscaleSelection.off.label(schemes), '超分 关');
    expect(const UpscaleSelection(preset: Anime4kPreset.standard).label(schemes), '超分 标');
    expect(const UpscaleSelection(preset: Anime4kPreset.ultra).label(schemes), '超分 极');
    expect(const UpscaleSelection(schemeId: 'acnet').label(schemes), '超分 ACNet');
    expect(const UpscaleSelection(schemeId: 'fsr').label(schemes), '超分 FSR');
    expect(const UpscaleSelection(schemeId: 'anime4k-ultra').label(schemes), '超分 A4K-U');
    expect(const UpscaleSelection(schemeId: 'rcas').label(schemes), '超分 RCAS');
  });

  test('设置还原：缺字段=关；未知方案回退 Anime4K', () {
    expect(UpscaleSelection.fromSettings().isOff, isTrue);
    final unknown = UpscaleSelection.fromSettings(
      schemeId: 'not-installed',
      presetName: 'standard',
      schemes: schemes,
    );
    expect(unknown.schemeId, kAnime4kSchemeId);
    expect(unknown.preset, Anime4kPreset.standard);
  });

  test('设置还原：已安装方案保留，未知 preset 名回退 off', () {
    final s = UpscaleSelection.fromSettings(
      schemeId: 'fsr',
      presetName: '没这个档',
      schemes: schemes,
    );
    expect(s.schemeId, 'fsr');
    expect(s.preset, Anime4kPreset.off);
    expect(s.resolve(schemes).name, 'FSR 1.0 · EASU+RCAS');
  });

  test('放大门槛：ACNet/ARNet=1.2，FSR=1.0，Ultra/RCAS 无门槛', () {
    for (final s in schemes.where((s) =>
        s.id == 'acnet' || s.id == 'acnet-hdn' || s.id == 'arnet')) {
      expect(s.upscaleOnlyAbove, 1.2, reason: s.id);
    }
    expect(const UpscaleSelection(schemeId: 'fsr').resolve(schemes).upscaleOnlyAbove, 1.0);
    for (final s in schemes.where((s) =>
        s.id == 'anime4k-ultra' || s.id == 'rcas' || s.isAnime4k)) {
      expect(s.upscaleOnlyAbove, isNull, reason: s.id);
    }
  });

  test('关 = anime4k + off，任何方案 + off 都算「开」', () {
    expect(const UpscaleSelection(schemeId: 'acnet').isOff, isFalse);
    expect(const UpscaleSelection(schemeId: kAnime4kSchemeId).isOff, isTrue);
    expect(UpscaleSelection.off.isOff, isTrue);
  });
}
