import 'package:dsanima_core/dsanima_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 超分包的能力闸门：本版本播放器（media_kit + ANGLE/GLES）跑不了 compute 着色器。
///
/// 依据（一手证据在 `docs/specs/2026-10-18-sr-models-bench.md` §3）：
/// mpv 在 GLES 上无条件关掉 compute（`ra_gl.c`: `if (ra->glsl_es) ra->caps &= ~RA_CAP_COMPUTE;`），
/// 而 CuNNy / ArtCNN 这类超分模型每个阶段都是 `//!COMPUTE`。
/// 不闸的话体验是「装成功 → 出现在超分菜单 → 播不出来」。
void main() {
  test('普通 user shader（只有 HOOK/BIND）→ 不需要 compute', () {
    const String glsl = '''
//!DESC test sharpen
//!HOOK MAIN
//!BIND HOOKED
void main() { vec4 c = HOOKED_tex(HOOKED_pos); }
''';
    expect(glslRequiresCompute(glsl), isFalse);
  });

  test('带 //!COMPUTE 指令 → 需要 compute', () {
    const String glsl = '''
//!DESC CuNNy 4x16
//!HOOK LUMA
//!COMPUTE 16 16 8 8
void main() {}
''';
    expect(glslRequiresCompute(glsl), isTrue);
  });

  test('行首有空白也认', () {
    expect(glslRequiresCompute('   //!COMPUTE 8 8 8 8\n'), isTrue);
    expect(glslRequiresCompute('\t//!COMPUTE 8 8 8 8\r\n'), isTrue);
  });

  test('相似但不同的指令不算（不许误伤）', () {
    expect(glslRequiresCompute('//!COMPUTEX 8 8 8 8\n'), isFalse);
    expect(glslRequiresCompute('// DESC //!COMPUTE\n'), isFalse, reason: '注释里的不算');
  });

  test('unsupportedShaderReason：返回第一个要求 compute 的文件，干净时返回 null', () {
    final Map<String, String> ok = <String, String>{
      'shaders/a.glsl': '//!HOOK MAIN\n//!BIND HOOKED\n',
      'shaders/b.glsl': '//!HOOK SCALED\n//!BIND HOOKED\n',
    };
    expect(unsupportedShaderReason(ok), isNull);

    final Map<String, String> bad = <String, String>{
      'shaders/a.glsl': '//!HOOK MAIN\n',
      'shaders/c.glsl': '//!HOOK LUMA\n//!COMPUTE 16 16 8 8\n',
    };
    expect(unsupportedShaderReason(bad), 'shaders/c.glsl');
  });
}
