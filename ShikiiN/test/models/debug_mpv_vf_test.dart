import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/debug_mpv_vf.dart';

/// 「临时验证 NV-VSR」那一轮的调试开关（见 docs/specs/2026-10-19-nv-vsr-spike.md）。
///
/// 它不是产品功能：没有这个环境变量时，行为必须与之前**逐字一致**。
void main() {
  test('没有环境变量 → 空串（不加任何滤镜）', () {
    expect(debugMpvVf(const <String, String>{}), isEmpty);
  });

  test('空白值 → 空串（不把空白当滤镜串发下去）', () {
    expect(debugMpvVf(const <String, String>{'DSANIMA_MPV_VF': '   '}), isEmpty);
  });

  test('正常值 → 原样（去首尾空白）', () {
    expect(
      debugMpvVf(const <String, String>{
        'DSANIMA_MPV_VF': '  d3d11vpp=format=nv12:scale=2:scaling-mode=nvidia ',
      }),
      'd3d11vpp=format=nv12:scale=2:scaling-mode=nvidia',
    );
  });

  test('含换行/回车 → 空串（一条 mpv 命令不许被注入成多条）', () {
    expect(
      debugMpvVf(const <String, String>{'DSANIMA_MPV_VF': 'vf a\nvf b'}),
      isEmpty,
    );
    expect(
      debugMpvVf(const <String, String>{'DSANIMA_MPV_VF': 'vf a\rvf b'}),
      isEmpty,
    );
  });

  test('没有显式 env 时读 Platform.environment（生产路径）', () {
    // 只钉「不传 env 也能调用、且当前进程没有这个变量时是空串」这两件事，
    // 不去设置进程环境（Flutter 测试里改不动 Platform.environment）。
    expect(debugMpvVf(), isEmpty);
  });
}
