import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/anime4k_preset.dart';
import 'package:shikiin/models/upscale_scheme.dart';

void main() {
  final List<UpscaleScheme> schemes = builtinUpscaleSchemes();

  test('内置方案：Anime4K 默认 + 至少 2 个 mpv 缩放器（零下载、实时）', () {
    final ids = schemes.map((s) => s.id).toList();
    expect(ids.first, kAnime4kSchemeId);
    expect(schemes.first.isAnime4k, isTrue);
    expect(schemes.where((s) => s.kind == UpscaleSchemeKind.mpvScaler).length,
        greaterThanOrEqualTo(2));
  });

  test('Anime4K 方案 = 三档（轻/标/极），链与 anime4kShaderChain 一致', () {
    final a4k = anime4kScheme();
    expect(a4k.tiers.map((t) => t.id), Anime4kPreset.simpleTiers.map((p) => p.name));
    for (final p in Anime4kPreset.simpleTiers) {
      final tier = a4k.tierOf(p.name)!;
      expect(tier.files, anime4kShaderChain(p));
    }
  });

  test('mpv 缩放器方案只带 scale 属性（不挂 shader，故 hasShaders 为 false）', () {
    for (final s in schemes.where((s) => s.kind == UpscaleSchemeKind.mpvScaler)) {
      expect(s.properties.keys, ['scale'], reason: '${s.id} 只该改放大算法');
      expect(s.tiers, isNotEmpty);
      expect(s.usesShaders, isFalse);
    }
  });

  test('胶囊循环顺序：关 → Anime4K 轻/标/极 → 各 mpv 方案 → 关', () {
    final order = UpscaleSelection.cycleOrder(schemes);
    expect(order.first, UpscaleSelection.off);
    expect(order[1], const UpscaleSelection(preset: Anime4kPreset.light));
    expect(order[2], const UpscaleSelection(preset: Anime4kPreset.standard));
    expect(order[3], const UpscaleSelection(preset: Anime4kPreset.ultra));
    expect(order[4].schemeId, 'mpv-ewa-lanczossharp');
    expect(order[order.length - 1].cycle(schemes), UpscaleSelection.off);
  });

  test('cycle 走完 mpv 方案回到关，且不会卡在同一项', () {
    var s = UpscaleSelection.off;
    final seen = <UpscaleSelection>{s};
    for (var i = 0; i < schemes.length + 3; i++) {
      s = s.cycle(schemes);
      seen.add(s);
    }
    expect(s, UpscaleSelection.off);
    expect(seen.length, UpscaleSelection.cycleOrder(schemes).length);
  });

  test('胶囊文案：关 / Anime4K 档 / mpv 短名', () {
    expect(UpscaleSelection.off.label(schemes), '超分 关');
    expect(const UpscaleSelection(preset: Anime4kPreset.standard).label(schemes), '超分 标');
    expect(const UpscaleSelection(preset: Anime4kPreset.ultra).label(schemes), '超分 极');
    expect(
      const UpscaleSelection(schemeId: 'mpv-ewa-lanczossharp').label(schemes),
      '超分 EWA锐',
    );
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
      schemeId: 'mpv-spline36',
      presetName: '没这个档',
      schemes: schemes,
    );
    expect(s.schemeId, 'mpv-spline36');
    expect(s.preset, Anime4kPreset.off);
    expect(s.resolve(schemes).name, 'mpv · Spline36');
  });
}
