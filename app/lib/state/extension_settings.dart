/// 扩展**用户设置**（预设开关 / 官方目录地址）的落盘与内存状态。
///
/// 为什么要单独一份文件（而不是塞进 `extensions/state.json`）：state.json 是安装器的
/// 账本（装了什么、开没开、从哪儿装的），装卸/升级会整份重写；用户偏好写在同一份文件里
/// 迟早被覆盖。这里的位置是 `<数据根>/dsanima/extension-settings.json`，扩展目录
/// 怎么换、怎么卸，它都不动。
///
/// 为什么是 `Notifier` 而不是"页面里的一个 FutureBuilder"：装配点有两处 ——
/// 扩展页（改设置）与**播放子窗口**（开窗时读一次，决定右键菜单列哪些预设）。
/// 两份各自读盘会读到不同步的两份状态；收在一个 provider 里，页面改完即写盘、
/// 开新播放窗口时读到的就是最新的。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

/// 设置文件名（与数据根里其它文件同层：`<数据根>/dsanima/extension-settings.json`）。
const String kExtensionUserSettingsFileName = 'extension-settings.json';

/// 设置文件的完整路径（测试与诊断共用一份口径）。
File extensionUserSettingsFileOf(Directory supportDir) => File(
      p.join(supportDir.path, 'dsanima', kExtensionUserSettingsFileName),
    );

/// 读设置：**永不抛**（文件坏了只该退化，不能让扩展页/播放窗口起不来）。
Future<core.ExtensionUserSettings> loadExtensionUserSettings(Directory supportDir) async {
  final File file = extensionUserSettingsFileOf(supportDir);
  try {
    if (!await file.exists()) return core.ExtensionUserSettings.empty;
    final String text = await file.readAsString();
    if (text.trim().isEmpty) return core.ExtensionUserSettings.empty;
    return core.ExtensionUserSettings.fromJson(jsonDecode(text));
  } catch (error) {
    debugPrint('[ext-settings] 读不出来（按默认处理）：$error');
    return core.ExtensionUserSettings.empty;
  }
}

/// 写设置：原子替换（先写 `.tmp` 再 rename）。
///
/// 为什么必须原子：播放子窗口可能在主窗口写一半时读这个文件；半截 json 会被
/// `fromJson` 当成"没有设置"，表现为"关掉的预设又回来了"。
Future<void> saveExtensionUserSettings(
  Directory supportDir,
  core.ExtensionUserSettings settings,
) async {
  final File file = extensionUserSettingsFileOf(supportDir);
  await file.parent.create(recursive: true);
  final File tmp = File('${file.path}.tmp');
  await tmp.writeAsString(jsonEncode(settings.toJson()), flush: true);
  await tmp.rename(file.path);
}

/// 设置的内存状态：扩展页改它、播放子窗口开窗时读它。
class ExtensionUserSettingsController extends Notifier<core.ExtensionUserSettings> {
  Directory? _supportDir;
  bool _loaded = false;

  @override
  core.ExtensionUserSettings build() => core.ExtensionUserSettings.empty;

  /// 页面/窗口挂载时调一次（同一目录只读一次盘）。
  Future<void> ensureLoaded(Directory supportDir) async {
    if (_loaded && _supportDir?.path == supportDir.path) return;
    _supportDir = supportDir;
    _loaded = true;
    state = await loadExtensionUserSettings(supportDir);
  }

  /// 某个扩展的"关掉的预设"改掉（空集合 = 设置过、一个都不关）。
  Future<void> setHiddenPresets(String extensionId, Set<String> hiddenPresetIds) async {
    state = state.withHiddenPresets(extensionId, hiddenPresetIds);
    await _save();
  }

  /// 记下**上一次成功拉取**的目录地址（「官方插件库」按钮用它一键重载）。
  Future<void> rememberCatalogUrl(String? url) async {
    state = state.withCatalogUrl(url);
    await _save();
  }

  /// 扩展被卸载后清掉它的设置（不然状态文件会一直长）。
  Future<void> forgetExtension(String extensionId) async {
    state = state.withoutExtension(extensionId);
    await _save();
  }

  Future<void> _save() async {
    final Directory? dir = _supportDir;
    if (dir == null) return; // 还没 ensureLoaded：只在内存里改，不落盘
    try {
      await saveExtensionUserSettings(dir, state);
    } catch (error) {
      // 落盘失败不该打断交互：下一次改设置会再试一次，最坏是这次没记住。
      debugPrint('[ext-settings] 写不进去（这次不落盘）：$error');
    }
  }
}

/// 扩展用户设置入口（扩展页 watch 它；播放子窗口在 `main.dart` 里 read 一次）。
final NotifierProvider<ExtensionUserSettingsController, core.ExtensionUserSettings>
    extensionUserSettingsProvider =
    NotifierProvider<ExtensionUserSettingsController, core.ExtensionUserSettings>(
  ExtensionUserSettingsController.new,
);
