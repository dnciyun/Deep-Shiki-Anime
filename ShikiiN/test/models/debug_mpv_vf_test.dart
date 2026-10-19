import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/debug_mpv_vf.dart';

/// 「临时验证 NV-VSR」那一轮的调试开关（见 docs/specs/2026-10-19-nv-vsr-spike.md）。
///
/// 它不是产品功能：两种来源（环境变量 / 同目录 txt）都没有时，行为必须与之前**逐字一致**。
///
/// 为什么要有第二种来源：真实反馈是「双击 exe 启动 → 环境变量没进进程 → 开关没生效，
/// 而界面上看不出来」。txt 跟着目录走，双击就有，不依赖启动方式。
void main() {
  group('debugMpvVf（纯函数）', () {
    test('两种来源都没有 → 空串', () {
      expect(debugMpvVf(), isEmpty);
    });

    test('只有环境变量 → 用它', () {
      expect(
        debugMpvVf(
          env: const <String, String>{
            'DSANIMA_MPV_VF': 'd3d11vpp=format=nv12:scale=2:scaling-mode=nvidia',
          },
        ),
        'd3d11vpp=format=nv12:scale=2:scaling-mode=nvidia',
      );
    });

    test('只有 txt 内容 → 用它（去首尾空白）', () {
      expect(
        debugMpvVf(fileText: '  d3d11vpp=format=nv12:scale=2:scaling-mode=nvidia \r\n'),
        'd3d11vpp=format=nv12:scale=2:scaling-mode=nvidia',
      );
    });

    test('两者都有 → 环境变量优先（便于临时覆盖目录里的 txt）', () {
      expect(
        debugMpvVf(
          env: const <String, String>{'DSANIMA_MPV_VF': 'env-win'},
          fileText: 'txt-lose',
        ),
        'env-win',
      );
    });

    test('环境变量是空白 → 退回 txt', () {
      expect(
        debugMpvVf(env: const <String, String>{'DSANIMA_MPV_VF': '   '}, fileText: 'txt-win'),
        'txt-win',
      );
    });

    test('含换行/回车 → 空串（一条 mpv 命令不许被注入成多条）', () {
      expect(debugMpvVf(env: const <String, String>{'DSANIMA_MPV_VF': 'vf a\nvf b'}), isEmpty);
      expect(debugMpvVf(fileText: 'vf a\nvf b'), isEmpty);
      expect(debugMpvVf(fileText: 'vf a\rvf b'), isEmpty);
    });

    test('纯空白 txt → 空串', () {
      expect(debugMpvVf(fileText: ' \t \n'), isEmpty);
    });

    test('只有编译期烘焙值（--dart-define）→ 用它', () {
      expect(
        debugMpvVf(baked: 'd3d11vpp=format=nv12:scale=2:scaling-mode=nvidia'),
        'd3d11vpp=format=nv12:scale=2:scaling-mode=nvidia',
      );
    });

    test('优先级：环境变量 > 文件 > 烘焙值', () {
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
    });

    test('烘焙值含换行 → 空串（同样不许注入）', () {
      expect(debugMpvVf(baked: 'vf a\nvf b'), isEmpty);
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
        nvVsrVfCommand('d3d11vpp=format=nv12:scale=2:scaling-mode=nvidia', enabled: true),
        <String>['set', 'vf', 'd3d11vpp=format=nv12:scale=2:scaling-mode=nvidia'],
      );
    });

    test('关 → set vf 空串（清空链，不是发一条假的滤镜）', () {
      expect(
        nvVsrVfCommand('d3d11vpp=format=nv12:scale=2:scaling-mode=nvidia', enabled: false),
        <String>['set', 'vf', ''],
      );
    });
  });
}
