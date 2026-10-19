/// 「NV-VSR 能不能在真实渲染链上跑」的**临时**调试开关（2026-10-19 spike）。
///
/// 背景：`docs/specs/2026-10-19-nv-vsr-spike.md` 已证明 NVIDIA RTX VSR 在 mpv CLI
/// （`vo=gpu` + `gpu-context=d3d11`）上能实时跑；但我们的播放器走 media_kit 的
/// ANGLE/GLES 纹理链，`d3d11vpp` 输出的 D3D11 纹理能不能被这条链接住**没有验证过**。
///
/// 来源有两个（优先级从高到低）：
/// 1. 环境变量 [kDebugMpvVfEnvVar]；
/// 2. 程序目录下的 [kDebugMpvVfFileName] 文本文件（**只有一行滤镜串**）。
///
/// 为什么加第 2 个：第一次真机验证时，用户双击 `dsanima.exe` 启动 → 环境变量没进进程，
/// 开关静默不生效、界面上完全看不出来。txt 跟着程序目录走，双击就有。
///
/// **两种来源都没有 = 空串 = 调用方什么都不做**，行为与之前逐字一致。
///
/// 判据（宁可不加，也不发一条会炸的滤镜串）：
/// * 空/纯空白 → 空串；
/// * 含换行或回车 → 空串（一条 mpv 命令不许被注入成多条）；
/// * 其余原样返回（去首尾空白）。滤镜串本身是否合法由 mpv 判定，这里不猜。
library;

import 'dart:io';

/// 环境变量名：值是 mpv 的 `vf` 滤镜串。
const String kDebugMpvVfEnvVar = 'DSANIMA_MPV_VF';

/// 程序目录下的文件名：内容同上（与环境变量同时存在时环境变量优先）。
const String kDebugMpvVfFileName = 'DSANIMA_MPV_VF.txt';

/// 编译期烘焙值（`flutter build windows --release --dart-define=DSANIMA_MPV_VF=...`）。
///
/// 用途：探针版要「双击 exe 就生效」，不能依赖环境变量或目录里的文件；正式版不带这个
/// define，这里就是空串，行为不变。运行时环境变量 / 文件的优先级仍然高于它。
const String _kBakedMpvVf = String.fromEnvironment('DSANIMA_MPV_VF');

/// 解析开关：[env] / [fileText] / [baked] 只给单测注入，生产调用不传。
///
/// 优先级：环境变量 > 程序目录 txt > 编译期烘焙值；全空 → 空串。
String debugMpvVf({Map<String, String>? env, String? fileText, String? baked}) {
  final Map<String, String> values = env ?? Platform.environment;
  final String fromEnv = _clean(values[kDebugMpvVfEnvVar] ?? '');
  if (fromEnv.isNotEmpty) return fromEnv;
  final String fromFile = _clean(fileText ?? '');
  if (fromFile.isNotEmpty) return fromFile;
  return _clean(baked ?? _kBakedMpvVf);
}

/// 读程序目录下的 [kDebugMpvVfFileName]；不存在/读不出 → 空串（永不抛）。
String debugMpvVfFile([String? path]) {
  try {
    final String target = path ?? defaultDebugMpvVfPath();
    final File file = File(target);
    if (!file.existsSync()) return '';
    return file.readAsStringSync();
  } catch (_) {
    // 调试开关读不到就是「没开」，不能因为它让开播失败。
    return '';
  }
}

/// 默认路径：`<exe 目录>/DSANIMA_MPV_VF.txt`。
String defaultDebugMpvVfPath() {
  final String exe = Platform.resolvedExecutable;
  final int cut = exe.lastIndexOf(Platform.pathSeparator);
  if (cut <= 0) return kDebugMpvVfFileName;
  return '${exe.substring(0, cut)}${Platform.pathSeparator}$kDebugMpvVfFileName';
}

String _clean(String raw) {
  final String spec = raw.trim();
  if (spec.isEmpty) return '';
  if (spec.contains('\n') || spec.contains('\r')) return '';
  return spec;
}
