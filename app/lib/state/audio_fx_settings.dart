/// 音效（`audio-pack`）设置的**宿主侧**状态：扩展页改它、开播窗口时推给播放器。
///
/// 为什么状态放主窗口而不是播放窗口（用户 2026-10-19：「放设置里没用，就放扩展里」）：
/// 配置入口在扩展页，而播放窗口是独立 Flutter 引擎 —— 两边各存一份必然漂移。
/// 现在主窗口是唯一写入口：改完落盘 + 推给播放窗口；播放窗口右键切档时回推一份。
///
/// 落盘位置 `<数据根>/dsanima/audio-fx.json`，与 `extension-settings.json` 同层：
/// 扩展怎么换、怎么卸，它都不动。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shikiin/shikiin.dart' as shikiin;

/// 设置文件名。
const String kAudioFxSettingsFileName = 'audio-fx.json';

File audioFxSettingsFileOf(Directory supportDir) =>
    File(p.join(supportDir.path, 'dsanima', kAudioFxSettingsFileName));

/// 读设置：**永不抛**（文件坏了就退化成默认，不能让扩展页起不来）。
Future<shikiin.AudioFxState> loadAudioFxState(Directory supportDir) async {
  final File file = audioFxSettingsFileOf(supportDir);
  try {
    if (!await file.exists()) return const shikiin.AudioFxState();
    final String text = await file.readAsString();
    if (text.trim().isEmpty) return const shikiin.AudioFxState();
    return shikiin.AudioFxState.fromJson(jsonDecode(text));
  } catch (error) {
    debugPrint('[audio-fx] 读不出来（按默认处理）：$error');
    return const shikiin.AudioFxState();
  }
}

/// 写设置：原子替换（先写 `.tmp` 再 rename），播放窗口随时可能来读。
Future<void> saveAudioFxState(Directory supportDir, shikiin.AudioFxState state) async {
  final File file = audioFxSettingsFileOf(supportDir);
  await file.parent.create(recursive: true);
  final File tmp = File('${file.path}.tmp');
  await tmp.writeAsString(jsonEncode(state.toJson()), flush: true);
  await tmp.rename(file.path);
}

class AudioFxSettingsController extends Notifier<shikiin.AudioFxState> {
  Directory? _supportDir;
  bool _loaded = false;

  @override
  shikiin.AudioFxState build() => const shikiin.AudioFxState();

  /// 扩展页/装配根挂载时调一次（同一目录只读一次盘）。
  Future<void> ensureLoaded(Directory supportDir) async {
    if (_loaded && _supportDir?.path == supportDir.path) return;
    _supportDir = supportDir;
    _loaded = true;
    state = await loadAudioFxState(supportDir);
  }

  /// 整份替换（扩展页选档 / 调强度都走这里）。
  Future<void> update(shikiin.AudioFxState next) async {
    state = next;
    await _save();
  }

  /// 播放窗口右键切档后回推过来的状态（已经在那边生效，这边只落盘、不再回推）。
  Future<void> adopt(shikiin.AudioFxState next) async {
    state = next;
    await _save();
  }

  Future<void> _save() async {
    final Directory? dir = _supportDir;
    if (dir == null) return; // 还没 ensureLoaded：只在内存里改
    try {
      await saveAudioFxState(dir, state);
    } catch (error) {
      debugPrint('[audio-fx] 写不进去（这次不落盘）：$error');
    }
  }
}

final NotifierProvider<AudioFxSettingsController, shikiin.AudioFxState>
    audioFxSettingsProvider =
    NotifierProvider<AudioFxSettingsController, shikiin.AudioFxState>(
  AudioFxSettingsController.new,
);
