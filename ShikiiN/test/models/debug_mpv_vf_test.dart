import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/debug_mpv_vf.dart';

/// NV-VSR（NVIDIA RTX 超分）这一条：
///
/// * 它现在是**内置能力**（随程序带的 libmpv 就支持），不再是编译期烘焙的探针开关；
/// * 环境变量 / 程序目录 txt 只作为**调试覆盖**保留（临时换滤镜串，比如关掉/换 scale）；
/// * 能不能用由运行时探测决定（`vf` 回读里没有 d3d11vpp 就算不支持），见 PlayerController。
void main() {
  group('debugMpvVf（纯函数）', () {
    test('两种覆盖都没有 → 用内置默认滤镜串', () {
      expect(debugMpvVf(), kNvVsrDefaultSpec);
      expect(kNvVsrDefaultSpec, 'd3d11vpp=format=nv12:scale=2:scaling-mode=nvidia');
    });

    test('只有环境变量 → 用它（覆盖内置默认）', () {
      expect(
        debugMpvVf(env: const <String, String>{'DSANIMA_MPV_VF': 'd3d11vpp=scale=1.5'}),
        'd3d11vpp=scale=1.5',
      );
    });

    test('只有 txt 内容 → 用它（去首尾空白）', () {
      expect(
        debugMpvVf(fileText: '  d3d11vpp=format=nv12:scale=2 \r\n'),
        'd3d11vpp=format=nv12:scale=2',
      );
    });

    test('优先级：环境变量 > 文件 > 内置默认', () {
      expect(
        debugMpvVf(
          env: const <String, String>{'DSANIMA_MPV_VF': 'env'},
          fileText: 'file',
          baked: 'baked',
        ),
        'env',
      );
      expect(debugMpvVf(fileText: 'file', baked: 'baked'), 'file');
      expect(debugMpvVf(baked: 'baked'), 'baked');
      expect(debugMpvVf(), kNvVsrDefaultSpec);
    });

    test('环境变量是空白 → 退回文件/默认（不把空白当滤镜串）', () {
      expect(
        debugMpvVf(env: const <String, String>{'DSANIMA_MPV_VF': '   '}, fileText: 'file'),
        'file',
      );
      expect(debugMpvVf(env: const <String, String>{'DSANIMA_MPV_VF': '   '}), kNvVsrDefaultSpec);
    });

    test('含换行/回车 → 空串（一条 mpv 命令不许被注入成多条）', () {
      expect(debugMpvVf(env: const <String, String>{'DSANIMA_MPV_VF': 'vf a\nvf b'}), isEmpty);
      expect(debugMpvVf(fileText: 'vf a\nvf b'), isEmpty);
      expect(debugMpvVf(fileText: 'vf a\rvf b'), isEmpty);
      expect(debugMpvVf(baked: 'vf a\nvf b'), isEmpty);
    });

    test('纯空白 txt → 退回内置默认', () {
      expect(debugMpvVf(fileText: ' \t \n'), kNvVsrDefaultSpec);
    });
  });

  group('debugMpvVfFile（读文件）', () {
    test('文件不存在 → 空串，不抛', () {
      expect(debugMpvVfFile('Z:/definitely/not/here/DSANIMA_MPV_VF.txt'), isEmpty);
    });
  });

  group('nvVsrVfCommand（开/关下发什么）', () {
    test('开 → set vf <滤镜串>', () {
      expect(
        nvVsrVfCommand(kNvVsrDefaultSpec, enabled: true),
        <String>['set', 'vf', kNvVsrDefaultSpec],
      );
    });

    test('关 → set vf 空串（清空链，不是发一条假的滤镜）', () {
      expect(
        nvVsrVfCommand(kNvVsrDefaultSpec, enabled: false),
        <String>['set', 'vf', ''],
      );
    });
  });
}
