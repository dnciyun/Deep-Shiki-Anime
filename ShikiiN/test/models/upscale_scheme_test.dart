import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/anime4k_preset.dart';
import 'package:shikiin/models/upscale_scheme.dart';

void main() {
  final List<UpscaleScheme> schemes = builtinUpscaleSchemes();

  test('内置只剩 Anime4K（默认）+ Anime4K-Ultra', () {
    expect(schemes.map((s) => s.id).toList(), [kAnime4kSchemeId, kAnime4kUltraSchemeId]);
    expect(schemes.first.isAnime4k, isTrue);
    // 用户 2026-10-17：「效果微乎其微，去除掉吧，仅保留anime4k包括u」。
    for (final gone in <String>['acnet', 'acnet-hdn', 'arnet', 'fsr', 'rcas']) {
      expect(schemes.where((s) => s.id == gone), isEmpty, reason: gone);
    }
    // 曾被否掉的 mpv 缩放器方案也不许回来。
    expect(schemes.where((s) => s.id.startsWith('mpv-')), isEmpty);
  });

  test('Anime4K 方案 = 三档（轻/标/极），链与 anime4kShaderChain 一致', () {
    final a4k = anime4kScheme();
    expect(a4k.tiers.map((t) => t.id), Anime4kPreset.simpleTiers.map((p) => p.name));
    for (final p in Anime4kPreset.simpleTiers) {
      final tier = a4k.tierOf(p.name)!;
      expect(tier.files, anime4kShaderChain(p));
    }
  });

  test('Anime4K-Ultra 是单文件 glslPack，且在随包清单里', () {
    final u = schemes.firstWhere((s) => s.id == kAnime4kUltraSchemeId);
    expect(u.kind, UpscaleSchemeKind.glslPack);
    expect(u.files, [kAnime4kUltraShader]);
    expect(kBundledPackShaderFiles, contains(kAnime4kUltraShader));
    expect(u.tiers, isEmpty);
    expect(u.dir, isNull, reason: '内置包用启动注入的 shader 目录');
    expect(u.isAnime4k, isFalse);
  });

  test('胶囊循环：关 → 轻 → 标 → 极 → Anime4K-Ultra → 关', () {
    final order = UpscaleSelection.cycleOrder(schemes);
    expect(order, [
      UpscaleSelection.off,
      const UpscaleSelection(preset: Anime4kPreset.light),
      const UpscaleSelection(preset: Anime4kPreset.standard),
      const UpscaleSelection(preset: Anime4kPreset.ultra),
      const UpscaleSelection(schemeId: kAnime4kUltraSchemeId),
    ]);
    var s = UpscaleSelection.off;
    for (var i = 0; i < order.length; i++) {
      s = s.cycle(schemes);
    }
    expect(s, UpscaleSelection.off);
  });

  test('胶囊文案：关 / Anime4K 档 / A4K-U', () {
    expect(UpscaleSelection.off.label(schemes), '超分 关');
    expect(const UpscaleSelection(preset: Anime4kPreset.standard).label(schemes), '超分 标');
    expect(const UpscaleSelection(preset: Anime4kPreset.ultra).label(schemes), '超分 极');
    expect(const UpscaleSelection(schemeId: kAnime4kUltraSchemeId).label(schemes), '超分 A4K-U');
  });

  test('设置还原：缺字段=关；以前存过的已删方案（acnet/fsr/rcas/mpv-*）回退 Anime4K', () {
    expect(UpscaleSelection.fromSettings().isOff, isTrue);
    for (final old in <String>['acnet', 'arnet', 'fsr', 'rcas', 'mpv-ewa-lanczossharp']) {
      final s = UpscaleSelection.fromSettings(
        schemeId: old,
        presetName: 'standard',
        schemes: schemes,
      );
      expect(s.schemeId, kAnime4kSchemeId, reason: old);
      expect(s.preset, Anime4kPreset.standard, reason: '旧档位继续沿用');
    }
  });

  test('设置还原：anime4k-ultra 保留，未知 preset 名回退 off', () {
    final s = UpscaleSelection.fromSettings(
      schemeId: kAnime4kUltraSchemeId,
      presetName: '没这个档',
      schemes: schemes,
    );
    expect(s.schemeId, kAnime4kUltraSchemeId);
    expect(s.preset, Anime4kPreset.off);
    expect(s.resolve(schemes).name, 'Anime4K-Ultra · 保颗粒');
  });

  test('关 = anime4k + off，任何方案 + off 都算「开」', () {
    expect(const UpscaleSelection(schemeId: kAnime4kUltraSchemeId).isOff, isFalse);
    expect(const UpscaleSelection(schemeId: kAnime4kSchemeId).isOff, isTrue);
  });
}
