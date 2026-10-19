/// 「NV-VSR 能不能在真实渲染链上跑」的**临时**调试开关（2026-10-19 spike）。
///
/// 背景：`docs/specs/2026-10-19-nv-vsr-spike.md` 已证明 NVIDIA RTX VSR 在 mpv CLI
/// （`vo=gpu` + `gpu-context=d3d11`）上能实时跑；但我们的播放器走 media_kit 的
/// ANGLE/GLES 纹理链，`d3d11vpp` 输出的 D3D11 纹理能不能被这条链接住**没有验证过**。
/// 验证需要：换一个带 NVIDIA 模式的 libmpv，再在 app 里下发一次真实的 `vf`。
///
/// 所以这个开关只做一件事：把环境变量 [_envVar] 里的 mpv `vf` 串读出来。
/// **没有这个变量 = 空串 = 调用方什么都不做**，行为与之前逐字一致。
///
/// 判据（宁可不加，也不发一条会炸的滤镜串）：
/// * 空/纯空白 → 空串；
/// * 含换行或回车 → 空串（一条 mpv 命令不许被注入成多条）；
/// * 其余原样返回（去首尾空白）。滤镜串本身是否合法由 mpv 判定，这里不猜。
library;

import 'dart:io';

/// 环境变量名：值是 mpv 的 `vf` 滤镜串（例：`d3d11vpp=format=nv12:scale=2:scaling-mode=nvidia`）。
const String kDebugMpvVfEnvVar = 'DSANIMA_MPV_VF';

/// 读 [kDebugMpvVfEnvVar]；[env] 只给单测注入，生产调用不传。
String debugMpvVf([Map<String, String>? env]) {
  final String raw = (env ?? Platform.environment)[kDebugMpvVfEnvVar] ?? '';
  final String spec = raw.trim();
  if (spec.isEmpty) return '';
  if (spec.contains('\n') || spec.contains('\r')) return '';
  return spec;
}
