import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/anime4k_preset.dart';
import '../models/upscale_scheme.dart';

/// shader 包版本：升级打包的 shader 时改这个值，触发重新解包。
///
/// v4.3：用户真机否掉 ACNet/ARNet/FSR/RCAS 后，只留 Anime4K 12 + Anime4K-Ultra
///（MIT，见 `THIRD_PARTY_NOTICES.txt`）。旧安装目录不动，回滚旧版本还能用。
const String kAnime4kVersion = 'v4.3';

const String _assetPrefix = 'assets/shaders/anime4k';

/// 随包解包的全部 shader：Anime4K 12 个 + 第三方 GLSL 包 5 个。
const List<String> kBundledShaderFiles = [
  ...kAnime4kShaderFiles,
  ...kBundledPackShaderFiles,
];

/// 把打包的 shader 解包到 `<targetRootDir>/anime4k_<version>/`，返回该目录绝对路径。
/// 目录已存在「完成标记」(.ok)则跳过（不调用 loadAsset）。
/// [loadAsset] 入参为 asset 路径（如 `assets/shaders/anime4k/X.glsl`），返回其字节。
Future<String> unpackAnime4kShaders({
  required Future<List<int>> Function(String assetPath) loadAsset,
  required String targetRootDir,
  String version = kAnime4kVersion,
}) async {
  final dir = p.join(targetRootDir, 'anime4k_$version');
  final okMarker = File(p.join(dir, '.ok'));
  if (okMarker.existsSync()) return dir;

  Directory(dir).createSync(recursive: true);
  for (final f in kBundledShaderFiles) {
    final bytes = await loadAsset('$_assetPrefix/$f');
    File(p.join(dir, f)).writeAsBytesSync(bytes);
  }
  okMarker.writeAsStringSync(version);
  return dir;
}
