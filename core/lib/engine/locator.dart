/// 定位 `rqbit-engine.exe`（spec §1 布局 / task-3）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';

/// 查找边车可执行文件。
///
/// 查找顺序（先命中先用）：
/// 1. 调用方显式传入的路径（`exePath`）；
/// 2. 环境变量 `DSANIMA_ENGINE`；
/// 3. `<当前可执行文件目录>/rqbit-engine.exe`（打包后与宿主同目录）；
/// 4. 从当前工作目录 / 宿主目录逐级向上找 `engine/target/release/rqbit-engine.exe`
///    （开发期 `cargo build --release` 的产物）。
///
/// 传了显式路径或环境变量、但文件不存在时**立刻报错**，不会静默回退到别的候选
/// ——配置错了必须看得见。
///
/// 全部候选来源都可注入，因此单测不需要真文件系统。
class EngineLocator {
  EngineLocator({
    Map<String, String>? environment,
    String? currentDirectory,
    String? resolvedExecutable,
    String? engineFileName,
    bool Function(String path)? fileExists,
    this.maxParentLevels = 6,
  }) : _environment = environment ?? Platform.environment,
       _currentDirectory = currentDirectory ?? Directory.current.path,
       _resolvedExecutable = resolvedExecutable ?? Platform.resolvedExecutable,
       engineFileName = engineFileName ?? defaultEngineFileName,
       _fileExists = fileExists ?? _defaultFileExists;

  /// 平台默认文件名（Windows 带 `.exe`）。
  static String get defaultEngineFileName =>
      Platform.isWindows ? 'rqbit-engine.exe' : 'rqbit-engine';

  /// 环境变量名。
  static const String envVarName = 'DSANIMA_ENGINE';

  /// 开发期相对仓库根的产物目录。
  static String get repoRelativePath => p.join('engine', 'target', 'release');

  static bool _defaultFileExists(String path) => File(path).existsSync();

  final Map<String, String> _environment;
  final String _currentDirectory;
  final String _resolvedExecutable;

  /// 目标文件名。
  final String engineFileName;

  final bool Function(String path) _fileExists;

  /// 向上搜索仓库产物的最大层数。
  final int maxParentLevels;

  final List<String> _searched = <String>[];

  /// 本次查找中尝试过的全部路径（失败信息里回显）。
  List<String> get searched => List<String>.unmodifiable(_searched);

  /// 执行查找；失败抛 [EngineException]（含全部候选路径与修复建议）。
  String locate({String? exePath}) {
    _searched.clear();

    final explicit = exePath?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      _searched.add(explicit);
      if (_fileExists(explicit)) return explicit;
      throw EngineException(
        '指定的引擎可执行文件不存在：$explicit\n'
        '提示：检查设置里的「引擎路径」，或先执行 `cd engine && cargo build --release`。',
      );
    }

    final fromEnv = _environment[envVarName]?.trim();
    if (fromEnv != null && fromEnv.isNotEmpty) {
      _searched.add(fromEnv);
      if (_fileExists(fromEnv)) return fromEnv;
      throw EngineException(
        '环境变量 $envVarName 指向的文件不存在：$fromEnv\n'
        '提示：清掉该变量（回退到自动查找），或指向真实的 rqbit-engine 可执行文件。',
      );
    }

    final roots = <String>[_currentDirectory, p.dirname(_resolvedExecutable)];
    final besideHost = p.join(roots[1], engineFileName);
    _searched.add(besideHost);
    if (_fileExists(besideHost)) return besideHost;

    for (final root in roots) {
      var directory = root;
      for (var level = 0; level <= maxParentLevels; level++) {
        final candidate = p.join(directory, repoRelativePath, engineFileName);
        if (!_searched.contains(candidate)) {
          _searched.add(candidate);
          if (_fileExists(candidate)) return candidate;
        }
        final parent = p.dirname(directory);
        if (parent == directory) break;
        directory = parent;
      }
    }

    throw EngineException(
      '找不到引擎可执行文件 `$engineFileName`。已尝试：\n'
      '${_searched.map((path) => '  • $path').join('\n')}\n'
      '修复方式（任选其一）：\n'
      '  1) 构建边车：`cd engine && cargo build --release`；\n'
      '  2) 设置环境变量 $envVarName=<rqbit-engine 完整路径>；\n'
      '  3) 启动时显式传入 exePath。',
    );
  }
}
