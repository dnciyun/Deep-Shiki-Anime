import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/controllers/anime4k_controller.dart';
import 'package:shikiin/models/anime4k_preset.dart';
import 'package:shikiin/models/upscale_scheme.dart';

void main() {
  late List<List<String>> sent;
  late Anime4kController c;
  setUp(() {
    sent = [];
    c = Anime4kController(runner: (args) async => sent.add(args))
      ..setShaderDir(r'C:\sh');
  });

  // 用户 2026-10-10 第二阶段优化 1：宿主自己不播时不能因为"载入档位"去建 mpv。
  test('loadPreset 只记档位、不下发（懒播放器宿主用）', () {
    c.loadPreset(Anime4kPreset.ultra);
    expect(sent, isEmpty, reason: '下发会经 runner 去创建播放器 —— 正是要避免的那份实例');
    expect(c.preset, Anime4kPreset.ultra);
    expect(c.hasShaders, isTrue, reason: '档位记着：真正播出时换片流程会挂链');
  });

  test('off → 下发 clr', () async {
    await c.setPreset(Anime4kPreset.off);
    expect(sent.single[0], 'change-list');
    expect(sent.single[1], 'glsl-shaders');
    expect(sent.single[2], 'clr');
    expect(c.preset, Anime4kPreset.off);
  });

  test('standard → set 带分号分隔的绝对路径，顺序同链', () async {
    await c.setPreset(Anime4kPreset.standard);
    final args = sent.single;
    expect(args.sublist(0, 3), ['change-list', 'glsl-shaders', 'set']);
    final paths = args[3].split(';');
    final chain = anime4kShaderChain(Anime4kPreset.standard);
    expect(paths.length, chain.length);
    expect(paths.first, r'C:\sh\Anime4K_Clamp_Highlights.glsl');
    expect(paths.every((p) => p.startsWith(r'C:\sh\')), isTrue);
  });

  test('未设 shader 目录时即使非 off 也 clr（安全降级）', () async {
    final c2 = Anime4kController(runner: (args) async => sent.add(args));
    await c2.setPreset(Anime4kPreset.standard);
    expect(sent.single[2], 'clr');
  });

  test('reapply 用当前 preset 重下发（换片后用）', () async {
    await c.setPreset(Anime4kPreset.light);
    sent.clear();
    await c.reapply();
    expect(sent.single[2], 'set');
  });

  test('hasShaders：off → false，有链 → true', () async {
    expect(c.hasShaders, isFalse); // 默认 off
    await c.setPreset(Anime4kPreset.standard);
    expect(c.hasShaders, isTrue);
    await c.setPreset(Anime4kPreset.off);
    expect(c.hasShaders, isFalse);
  });

  test('clearForSwitch：发 clr 但保留当前档位（换片前清、之后可 reapply 恢复）', () async {
    await c.setPreset(Anime4kPreset.standard);
    sent.clear();
    await c.clearForSwitch();
    expect(sent.single.sublist(0, 3), ['change-list', 'glsl-shaders', 'clr']);
    expect(c.preset, Anime4kPreset.standard); // 档位不变
    expect(c.hasShaders, isTrue); // 仍可被 reapply 恢复
  });

  test('clearForSwitch 吞掉 runner 异常', () async {
    final throwing = Anime4kController(runner: (args) async => throw StateError('x'))
      ..setShaderDir(r'C:\sh');
    await expectLater(throwing.clearForSwitch(), completes);
  });

  test('setPreset 不因 runner 抛异常而冒泡（记录而非崩溃）', () async {
    final throwing = Anime4kController(runner: (args) async => throw StateError('mpv down'))
      ..setShaderDir(r'C:\sh');
    await expectLater(throwing.setPreset(Anime4kPreset.standard), completes);
  });

  test('reapply 同样吞掉 runner 异常', () async {
    final throwing = Anime4kController(runner: (args) async => throw StateError('x'))
      ..setShaderDir(r'C:\sh');
    await expectLater(throwing.reapply(), completes);
  });

  group('Anime4K-Ultra 方案（用户「仅保留anime4k包括u」）', () {
    test('切到 Anime4K-Ultra：按方案文件 set，路径在注入的 shader 目录里', () async {
      await c.setSelection(const UpscaleSelection(schemeId: kAnime4kUltraSchemeId));
      final args = sent.single;
      expect(args.sublist(0, 3), ['change-list', 'glsl-shaders', 'set']);
      expect(args[3], r'C:\sh\Anime4K-Ultra_DbL.glsl');
      expect(c.isOff, isFalse);
      expect(c.hasShaders, isTrue);
      expect(c.schemeId, kAnime4kUltraSchemeId);
    });

    test('Anime4K-Ultra 只有一条 set，不带任何 mpv 属性（缩放器已删）', () async {
      await c.setSelection(const UpscaleSelection(schemeId: kAnime4kUltraSchemeId));
      expect(sent, hasLength(1));
      expect(sent.where((a) => a.first == 'set'), isEmpty);
      expect(sent.single[1], 'glsl-shaders');
    });

    test('Anime4K-Ultra → 关：只 clr', () async {
      await c.setSelection(const UpscaleSelection(schemeId: kAnime4kUltraSchemeId));
      sent.clear();
      await c.setSelection(UpscaleSelection.off);
      expect(sent.single.sublist(0, 3), ['change-list', 'glsl-shaders', 'clr']);
      expect(c.isOff, isTrue);
    });

    test('Anime4K-Ultra → Anime4K：直接换成 Anime4K 链', () async {
      await c.setSelection(const UpscaleSelection(schemeId: kAnime4kUltraSchemeId));
      sent.clear();
      await c.setSelection(const UpscaleSelection(preset: Anime4kPreset.standard));
      expect(sent, hasLength(1));
      expect(sent.single[3].split(';').length,
          anime4kShaderChain(Anime4kPreset.standard).length);
      expect(c.selection.schemeId, kAnime4kSchemeId);
    });

    test('已被否掉的方案 id 不再存在：选它回退 Anime4K（不会假装生效）', () async {
      await c.setSelection(const UpscaleSelection(schemeId: 'acnet'));
      expect(c.schemeId, 'acnet');
      expect(c.hasShaders, isFalse, reason: '未知方案解析成 Anime4K/off → 没有链');
      expect(sent.single.sublist(0, 3), ['change-list', 'glsl-shaders', 'clr']);
    });

    test('扩展方案（带 dir）用方案自己的目录，不用注入的 anime4k 目录', () async {
      c.setSchemes([
        ...builtinUpscaleSchemes(),
        const UpscaleScheme(
          id: 'ext-demo',
          name: '扩展示例',
          shortName: 'DEMO',
          kind: UpscaleSchemeKind.glslPack,
          files: ['demo.glsl'],
          dir: r'C:\ext',
        ),
      ]);
      await c.setSelection(const UpscaleSelection(schemeId: 'ext-demo'));
      expect(sent.single[3], r'C:\ext\demo.glsl');
    });
  });

  group('换片保护窗口（set 撞 VO 重建 → 原生崩溃的防护）', () {
    test('窗口内 setPreset 不下发 set，exit 补发最新档位', () async {
      final token = c.enterSwitchWindow();
      await c.setPreset(Anime4kPreset.standard);
      expect(sent, isEmpty); // set 被押下
      await c.exitSwitchWindow(token);
      expect(sent.single[2], 'set');
      expect(sent.single[3].split(';').length,
          anime4kShaderChain(Anime4kPreset.standard).length);
    });

    test('窗口内连切多档，exit 只按最新档补发一次', () async {
      final token = c.enterSwitchWindow();
      await c.setPreset(Anime4kPreset.light);
      await c.setPreset(Anime4kPreset.standard);
      expect(sent, isEmpty);
      await c.exitSwitchWindow(token);
      expect(sent, hasLength(1));
      expect(sent.single[3].split(';').length,
          anime4kShaderChain(Anime4kPreset.standard).length);
    });

    test('窗口内关超分：clr 立即放行，exit 不再补发', () async {
      await c.setPreset(Anime4kPreset.standard); // 窗口外先开
      sent.clear();
      final token = c.enterSwitchWindow();
      await c.setPreset(Anime4kPreset.off);
      expect(sent.single[2], 'clr'); // clr 任意时刻安全
      sent.clear();
      await c.exitSwitchWindow(token);
      expect(sent, isEmpty);
    });

    test('进入时已开超分（换片恢复场景）：clearForSwitch 后 exit 恢复原档', () async {
      await c.setPreset(Anime4kPreset.standard);
      sent.clear();
      final token = c.enterSwitchWindow();
      await c.clearForSwitch();
      expect(sent.single[2], 'clr');
      sent.clear();
      await c.exitSwitchWindow(token);
      expect(sent.single[2], 'set'); // 档位自动恢复
    });

    test('exit(reapply:false) 只解除窗口不补发；此后切档恢复直发', () async {
      final token = c.enterSwitchWindow();
      await c.setPreset(Anime4kPreset.standard);
      await c.exitSwitchWindow(token, reapply: false);
      expect(sent, isEmpty);
      await c.setPreset(Anime4kPreset.light); // 窗口已解除 → 正常下发
      expect(sent.single[2], 'set');
    });

    test('旧票据 exit 无效（重叠换片由新窗口接管）', () async {
      final t1 = c.enterSwitchWindow();
      await c.setPreset(Anime4kPreset.standard);
      final t2 = c.enterSwitchWindow(); // 第二次换片：旧票据失效
      await c.exitSwitchWindow(t1);
      expect(sent, isEmpty);
      await c.exitSwitchWindow(t2);
      expect(sent.single[2], 'set');
    });

    test('重复 exit 幂等（catch 与 reconfig 续程可能都调一次）', () async {
      final token = c.enterSwitchWindow();
      await c.setPreset(Anime4kPreset.standard);
      await c.exitSwitchWindow(token);
      await c.exitSwitchWindow(token);
      expect(sent, hasLength(1)); // 只补发一次
    });
  });

  // 画面调节扩展包：宿主按滑块值渲染出一份 .glsl，作为**叠加链**挂在方案后面。
  // 判据的重点不是"能不能挂"，而是"关超分时不许 clr 掉画面调节"和"顺序在方案之后"。
  group('画面调节叠加链（extraChain）', () {
    const String picture = r'C:\cache\picture_demo_ab12.glsl';

    test('setExtraChain 只记状态、不下发（一次操作只发一条命令）', () {
      c.setExtraChain(<String>[picture]);
      expect(sent, isEmpty);
      expect(c.extraChain, <String>[picture]);
    });

    test('关超分 + 画面调节 → set 只带画面调节（绝不 clr）', () async {
      c.setExtraChain(<String>[picture]);
      await c.setPreset(Anime4kPreset.off);
      expect(sent.single.sublist(0, 3), ['change-list', 'glsl-shaders', 'set']);
      expect(sent.single[3], picture);
      expect(c.hasEffect, isTrue);
      expect(c.hasShaders, isTrue);
    });

    test('开着方案 + 画面调节 → 方案链在前、画面调节在后', () async {
      c.setExtraChain(<String>[picture]);
      await c.setSelection(const UpscaleSelection(preset: Anime4kPreset.standard));
      final List<String> paths = sent.single[3].split(';');
      expect(paths.last, picture);
      expect(paths.first, isNot(picture));
      expect(paths.where((String x) => x == picture), hasLength(1));
      expect(paths.length, anime4kShaderChain(Anime4kPreset.standard).length + 1);
    });

    test('画面调节叠在扩展方案上：两种来源的绝对路径都在，扩展包自己的目录不被改', () async {
      final c3 = Anime4kController(runner: (args) async => sent.add(args))
        ..setShaderDir(r'C:\sh');
      c3.setExtraChain(<String>[picture]);
      c3.setSchemes(<UpscaleScheme>[
        const UpscaleScheme(
          id: 'ext-pack',
          name: '扩展包',
          shortName: 'EXT',
          kind: UpscaleSchemeKind.glslPack,
          files: <String>['a.glsl', 'b.glsl'],
          dir: r'C:\ext\ext-pack\shaders',
        ),
      ]);
      await c3.setSelection(const UpscaleSelection(schemeId: 'ext-pack'));
      final List<String> paths = sent.single[3].split(';');
      expect(paths, <String>[
        r'C:\ext\ext-pack\shaders\a.glsl',
        r'C:\ext\ext-pack\shaders\b.glsl',
        picture,
      ]);
    });

    test('清掉叠加链后回关 → clr；hasEffect/hasShaders 跟着回到 false', () async {
      c.setExtraChain(<String>[picture]);
      await c.setPreset(Anime4kPreset.off);
      sent.clear();
      c.setExtraChain(const <String>[]);
      await c.reapply();
      expect(sent.single[2], 'clr');
      expect(c.hasEffect, isFalse);
      expect(c.hasShaders, isFalse);
    });

    test('空白路径被丢掉（避免拼出 "a;;b" 这种让 mpv 读不到文件的值）', () {
      c.setExtraChain(<String>[picture, '  ', '']);
      expect(c.extraChain, <String>[picture]);
    });

    test('换片保护窗口内改叠加链：记账，exit 时按最新链补发一次', () async {
      final token = c.enterSwitchWindow();
      c.setExtraChain(<String>[picture]);
      await c.setPreset(Anime4kPreset.off);
      expect(sent, isEmpty, reason: '窗口内不 set');
      await c.exitSwitchWindow(token);
      expect(sent.single[2], 'set');
      expect(sent.single[3], picture);
    });
  });
}
