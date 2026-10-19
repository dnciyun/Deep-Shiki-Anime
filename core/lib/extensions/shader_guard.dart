/// 超分包（`shader-pack`）的能力闸门：**本版本播放器跑不了 compute 着色器**。
///
/// 为什么需要这个闸门（一手证据见 `docs/specs/2026-10-18-sr-models-bench.md` §3、§5）：
/// * 播放器是 media_kit，Windows 端走 ANGLE/**GLES**；
/// * mpv 在 GLES 上**无条件**关掉 compute（`video/out/opengl/ra_gl.c`：
///   `if (ra->glsl_es) ra->caps &= ~RA_CAP_COMPUTE;`，注释写明 GLES 不支持写纹理）；
/// * 而 CuNNy / ArtCNN 这类超分模型的**每一个阶段**都是 `//!COMPUTE`。
///
/// 所以这类包在现在的链路上必然"装得上、菜单里能选、播不出来"——正是用户体验契约里
/// 明确要消灭的那种。闸门放在**安装阶段**：直接拒装并说清原因，而不是让它进菜单。
library;

/// mpv user shader 的 compute 指令（`//!COMPUTE <bx> <by> <tx> <ty>`）。
const String _kComputeDirective = '//!COMPUTE';

/// 扫描时单个 GLSL 的大小上限：一份 user-shader 链不会有几 MB，超大的就不扫。
const int kShaderScanMaxBytes = 4 * 1024 * 1024;

/// 这份 GLSL 是否要求 compute 着色器。
///
/// 只认**行首（可带空白）**的 `//!COMPUTE`；相似的 `//!COMPUTEX`、注释里出现的字样
/// 都不算——误伤一个能跑的包比漏放一个更糟。
bool glslRequiresCompute(String source) {
  for (final String line in source.split('\n')) {
    final String trimmed = line.trimLeft();
    if (!trimmed.startsWith(_kComputeDirective)) continue;
    final int end = _kComputeDirective.length;
    // 后面必须是结尾或空白，否则是别的指令名（`//!COMPUTEX`）。
    if (trimmed.length == end) return true;
    final String next = trimmed.substring(end, end + 1);
    if (next.trim().isEmpty) return true;
  }
  return false;
}

/// 扫描一组 `路径 → GLSL 正文`：返回**第一个**要求 compute 的路径；都通过 → null。
String? unsupportedShaderReason(Map<String, String> sources) {
  for (final MapEntry<String, String> entry in sources.entries) {
    if (glslRequiresCompute(entry.value)) return entry.key;
  }
  return null;
}
