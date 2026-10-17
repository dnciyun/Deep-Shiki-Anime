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

  group('mpv 内置缩放器方案（2026-10-17：其他实时超分）', () {
    late List<List<String>> sent;
    late Map<String, String> props;
    late Anime4kController c;

    setUp(() {
      sent = [];
      props = {'scale': 'bilinear'};
      c = Anime4kController(
        runner: (args) async => sent.add(args),
        readProperty: (name) async => props[name] ?? '',
      )..setShaderDir(r'C:\sh');
    });

    test('切到 mpv 方案：先 clr 掉 shader，再 set scale；不挂 shader', () async {
      await c.setSelection(const UpscaleSelection(schemeId: 'mpv-ewa-lanczossharp'));
      expect(sent, hasLength(2));
      expect(sent[0].sublist(0, 3), ['change-list', 'glsl-shaders', 'clr']);
      expect(sent[1], ['set', 'scale', 'ewa_lanczossharp']);
      expect(c.isOff, isFalse);
      expect(c.hasShaders, isFalse, reason: 'mpv 缩放器不挂 shader 链');
      expect(c.hasEffect, isTrue);
    });

    test('关超分：clr + 把 scale 原值写回（media_kit 默认是 bilinear）', () async {
      await c.setSelection(const UpscaleSelection(schemeId: 'mpv-ewa-lanczossharp'));
      sent.clear();
      await c.setSelection(UpscaleSelection.off);
      expect(sent[0].sublist(0, 3), ['change-list', 'glsl-shaders', 'clr']);
      expect(
        sent.any((a) => a.length == 3 && a[0] == 'set' && a[1] == 'scale' && a[2] == 'bilinear'),
        isTrue,
        reason: '离开 mpv 方案要把原值写回（实际：$sent）',
      );
      expect(c.isOff, isTrue);
    });

    test('mpv 方案切回 Anime4K：先恢复原值，再挂链', () async {
      await c.setSelection(const UpscaleSelection(schemeId: 'mpv-spline36'));
      sent.clear();
      await c.setSelection(const UpscaleSelection(preset: Anime4kPreset.standard));
      expect(sent.first, ['set', 'scale', 'bilinear']);
      expect(sent.last.sublist(0, 3), ['change-list', 'glsl-shaders', 'set']);
      expect(sent.last[3].split(';').length, anime4kShaderChain(Anime4kPreset.standard).length);
    });

    test('换片窗口内切 mpv 方案被押下，exit 按最新选择补发', () async {
      final token = c.enterSwitchWindow();
      await c.setSelection(const UpscaleSelection(schemeId: 'mpv-ewa-lanczos'));
      expect(sent, isEmpty, reason: '窗口内不碰渲染上下文');
      await c.exitSwitchWindow(token);
      expect(sent, hasLength(2));
      expect(sent[1], ['set', 'scale', 'ewa_lanczos']);
    });

    test('读不到原值时不写猜的默认值（离开只 clr）', () async {
      props.clear();
      await c.setSelection(const UpscaleSelection(schemeId: 'mpv-bicubic'));
      sent.clear();
      await c.setSelection(UpscaleSelection.off);
      expect(sent.where((a) => a.isNotEmpty && a.first == 'set'), isEmpty);
    });
  });
}
