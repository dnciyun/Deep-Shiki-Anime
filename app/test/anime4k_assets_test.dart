/// 超分 shader 打包回归测试（用户要求：把 Anime4K/ACNet 等作为播放器内置工具打进应用）。
///
/// 这个测试钉的是一个**只有真机才会暴露、且症状极具误导性**的失败：
/// shikiin 的 `unpackAnime4kShaders()` 用**无包前缀**的
/// `assets/shaders/anime4k/<file>` 去 `rootBundle.load`。依赖包（shikiin）
/// 自己 pubspec 里声明了这些 asset **并不会**让它们进入宿主 app 的 asset bundle，
/// 所以宿主漏声明时：
///
///   * `flutter analyze` 干净；
///   * `flutter test` 全绿（测试不碰 rootBundle）；
///   * `flutter build windows` 成功；
///   * 真机启动只在日志里留一行
///     `Unable to load asset: "assets/shaders/anime4k/Anime4K_Clamp_Highlights.glsl"`
///     然后 `anime4k init failed (降级为关)` —— 用户感知是「超分菜单点了没用」。
///
/// 所以这里直读磁盘校验「pubspec 里确实声明了」+「文件确实在且是真 GLSL」。
/// 真正的端到端断言（rootBundle 能取到字节）由打包后的人工验证覆盖：
/// `flutter build windows` 后检查 `data/flutter_assets/assets/shaders/anime4k/`。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 必须与 shikiin 的 `kAnime4kShaderFiles`（`lib/models/anime4k_preset.dart`）+
/// `kBundledPackShaderFiles`（`lib/models/upscale_scheme.dart`）**逐字一致**：
/// 少一个 → 解包到一半抛异常，超分整体降级为关。
const List<String> kRequiredShaderFiles = <String>[
  // Anime4K（MIT, bloc97）
  'Anime4K_Clamp_Highlights.glsl',
  'Anime4K_Restore_CNN_VL.glsl',
  'Anime4K_Restore_CNN_M.glsl',
  'Anime4K_Restore_CNN_Soft_VL.glsl',
  'Anime4K_Restore_CNN_Soft_M.glsl',
  'Anime4K_Upscale_CNN_x2_VL.glsl',
  'Anime4K_Upscale_CNN_x2_M.glsl',
  'Anime4K_Upscale_CNN_x2_S.glsl',
  'Anime4K_Upscale_Denoise_CNN_x2_VL.glsl',
  'Anime4K_Upscale_Denoise_CNN_x2_S.glsl',
  'Anime4K_AutoDownscalePre_x2.glsl',
  'Anime4K_AutoDownscalePre_x4.glsl',
  // ACNet / ARNet（MIT, TianZerL/ACNetGLSL）
  'acnet_f8b8.glsl',
  'acnet_f8b8_hdn.glsl',
  'arnet_f8b16.glsl',
  // Anime4K-Ultra（MIT, Th-Underscore）
  'Anime4K-Ultra_DbL.glsl',
  // AMD FidelityFX FSR 1.0.2（MIT, AMD / agyild 移植）
  'FSR.glsl',
  // RCAS 独立锐化（上面 FSR 的 RCAS pass 抽出来，任何尺寸都生效）
  'RCAS.glsl',
];

void main() {
  group('超分 shader 随包内置（assets/shaders/anime4k/）', () {
    test('pubspec.yaml 声明了 assets/shaders/anime4k/（漏了 → 真机 Unable to load asset）', () {
      final pubspec = File('pubspec.yaml');
      expect(pubspec.existsSync(), isTrue, reason: '测试的工作目录应是 app/');

      // 只取 `flutter:` 段之后的 assets 列表，避免匹配到注释里的示例行。
      final lines = pubspec.readAsLinesSync();
      final declared = <String>[];
      var inFlutter = false;
      var inAssets = false;
      for (final raw in lines) {
        final line = raw.trimRight();
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
        if (RegExp(r'^flutter:').hasMatch(trimmed)) {
          inFlutter = true;
          continue;
        }
        if (!inFlutter) continue;
        if (RegExp(r'^assets:\s*$').hasMatch(trimmed)) {
          inAssets = true;
          continue;
        }
        if (inAssets) {
          final match = RegExp(r'^-\s+(\S+)\s*$').firstMatch(trimmed);
          if (match != null) {
            declared.add(match.group(1)!);
            continue;
          }
          inAssets = false; // 列表结束
        }
      }

      expect(
        declared,
        contains('assets/shaders/anime4k/'),
        reason: 'shikiin 按 assets/shaders/anime4k/<file> 读 rootBundle，'
            '宿主必须自己声明这一项；依赖包声明不会进宿主 bundle',
      );
      expect(
        declared,
        contains('assets/tray.ico'),
        reason: '托盘图标的历史声明不能被这次修改挤掉',
      );
    });

    test('shikiin 清单里的 18 个 shader 全部就位，且都是真 GLSL 不是错误页', () {
      final dir = Directory('assets/shaders/anime4k');
      expect(
        dir.existsSync(),
        isTrue,
        reason: '超分是内置工具，素材必须随仓入库',
      );

      final present = dir
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .toSet();

      expect(
        present,
        containsAll(kRequiredShaderFiles),
        reason: '缺任何一个文件都会让 unpackAnime4kShaders 抛异常、整体降级为关',
      );

      for (final name in kRequiredShaderFiles) {
        final file = File('assets/shaders/anime4k/$name');
        final text = file.readAsStringSync();

        expect(
          text.trim(),
          isNotEmpty,
          reason: '$name 是空文件（占位符/下载失败），libmpv 挂载会失败',
        );
        expect(
          text,
          startsWith('//'),
          reason: '$name 不是 GLSL（开头应是注释头）：'
              '素材抓取时可能存成了 HTML 错误页',
        );
        expect(
          text,
          contains('//!HOOK'),
          reason: '$name 缺 //!HOOK 挂载点声明',
        );
      }
    });

    test('shader 体积合理：大模型不能塌成空壳（防止误传同名空文件）', () {
      int size(String name) => File('assets/shaders/anime4k/$name').lengthSync();

      // Anime4K：VL 档是最大的一组 CNN 权重（约 145 KB 级）。
      expect(size('Anime4K_Upscale_CNN_x2_VL.glsl'), greaterThan(100000));
      expect(size('Anime4K_Upscale_CNN_x2_S.glsl'), greaterThan(10000));
      expect(size('Anime4K_Upscale_CNN_x2_S.glsl'), lessThan(100000));
      expect(size('Anime4K_AutoDownscalePre_x2.glsl'), lessThan(10000));
      // ACNet f8b8 约 90 KB；ARNet f8b16 约 333 KB；Ultra 约 97 KB；FSR 约 16 KB。
      expect(size('acnet_f8b8.glsl'), greaterThan(80000));
      expect(size('acnet_f8b8_hdn.glsl'), greaterThan(80000));
      expect(size('arnet_f8b16.glsl'), greaterThan(300000));
      expect(size('Anime4K-Ultra_DbL.glsl'), greaterThan(50000));
      expect(size('FSR.glsl'), greaterThan(10000));
      expect(size('FSR.glsl'), lessThan(30000));
      expect(size('RCAS.glsl'), greaterThan(2000));
      expect(size('RCAS.glsl'), lessThan(10000));
    });
  });
}
