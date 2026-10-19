/// NV-VSR（NVIDIA RTX Super Resolution）的滤镜串与开关判据。
///
/// 2026-10-19 起这是**内置能力**：随程序发布的 libmpv 是带 NVIDIA 模式的构建
/// （`d3d11vpp` 的 `scaling-mode=nvidia`），所以默认就在用；右键菜单里可以关掉。
/// 详情与实测数据见 `docs/specs/2026-10-19-nv-vsr-spike.md`。
///
/// 三档覆盖（优先级从高到低，只给调试/排障用）：
/// 1. 环境变量 [kDebugMpvVfEnvVar]；
/// 2. 程序目录下的 [kDebugMpvVfFileName] 文本文件（**只有一行滤镜串**）；
/// 3. 编译期烘焙值（`--dart-define=DSANIMA_MPV_VF=...`，探针版用过，正式构建不带）。
///
/// 三档都没有时用 [kNvVsrDefaultSpec]（= 内置默认）。注意：**能不能用不由这里决定**，
/// 而是运行时回读 `vf` 判断（libmpv 不认识这条滤镜时 `vf-now` 里没有 d3d11vpp），
/// 见 `PlayerController.nvVsrAvailable`。
///
/// 判据（宁可不加，也不发一条会炸的滤镜串）：
/// * 空/纯空白 → 落到下一档；
/// * 含换行或回车 → 空串（一条 mpv 命令不许被注入成多条）。
library;

import 'dart:io';

/// 环境变量名：值是 mpv 的 `vf` 滤镜串（调试覆盖）。
const String kDebugMpvVfEnvVar = 'DSANIMA_MPV_VF';

/// 程序目录下的文件名：内容同上（与环境变量同时存在时环境变量优先）。
const String kDebugMpvVfFileName = 'DSANIMA_MPV_VF.txt';

/// 内置默认：NVIDIA RTX VSR，2× 放大，要求 nv12 硬解帧。
const String kNvVsrDefaultSpec = 'd3d11vpp=format=nv12:scale=2:scaling-mode=nvidia';

/// VSR 开关的持久化键（播放器 store；右键菜单里的「关闭/开启 NV-VSR」）。
const String kNvVsrEnabledStoreKey = 'nv-vsr-enabled';

/// 编译期烘焙值（探针版用过；正式构建为空）。
const String _kBakedMpvVf = String.fromEnvironment('DSANIMA_MPV_VF');

/// 解析实际要用的滤镜串：[env] / [fileText] / [baked] 只给单测注入，生产调用不传。
///
/// 优先级：环境变量 > 程序目录 txt > 编译期烘焙 > 内置默认。
/// 空白值 = 这一档没有覆盖（落到下一档）；**含换行 = 明确的"别加滤镜"**（返回空串，
/// 不退回默认）——覆盖串写坏时宁可什么都不加，也不能把默认滤镜当成用户想要的东西。
String debugMpvVf({Map<String, String>? env, String? fileText, String? baked}) {
  final Map<String, String> values = env ?? Platform.environment;
  for (final String raw in <String>[
    values[kDebugMpvVfEnvVar] ?? '',
    fileText ?? '',
    baked ?? _kBakedMpvVf,
  ]) {
    final String? spec = _specOrNull(raw);
    if (spec == null) continue; // 这一档没覆盖
    return spec; // 命中（也可能是空串 = 明确不加）
  }
  return kNvVsrDefaultSpec;
}

/// 读程序目录下的 [kDebugMpvVfFileName]；不存在/读不出 → 空串（永不抛）。
String debugMpvVfFile([String? path]) {
  try {
    final String target = path ?? defaultDebugMpvVfPath();
    final File file = File(target);
    if (!file.existsSync()) return '';
    return file.readAsStringSync();
  } catch (_) {
    // 调试覆盖读不到就是「没有覆盖」，不能因为它让开播失败。
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

/// 开/关这条滤镜链要下发的 mpv 命令（`set vf` 用空串 = 清空链）。
///
/// 提成纯函数是为了能离线测：`set vf` 的两种取值（滤镜串 / 空串）一旦写反，
/// 表现是「点了关闭画面没变」而不是报错，很难在真机上定位。
List<String> nvVsrVfCommand(String spec, {required bool enabled}) =>
    <String>['set', 'vf', enabled ? spec : ''];

/// 一档覆盖值的判定：null = 没覆盖（空白）；'' = 写坏了（含换行，明确别加）；其余原样。
String? _specOrNull(String raw) {
  final String spec = raw.trim();
  if (spec.isEmpty) return null;
  if (spec.contains('\n') || spec.contains('\r')) return '';
  return spec;
}
