/// 「画面调节」当前选择与滑杆取值的落盘：`<数据根>/dsanima/picture-settings.json`。
///
/// 为什么需要它：`PictureController` 只在内存里记 `PictureSettings`，关掉播放窗口就没了 ——
/// 每次开窗都回到包的默认值，用户调过的锐度/对比/色温全白调（第四轮交付时列在
/// 「已知没做」里，用户 2026-10-18 指到这一轮）。
///
/// 为什么单独一份文件，而不是塞进 `extension-settings.json`：
/// * **写者不同**：那份由扩展页（主窗口）写"关掉哪些预设 / 上次的目录地址"，这一份由
///   **播放子窗口**在每次松手/点重置后写。两个进程写同一份文件必然互相覆盖
///   （子窗口拿的是开窗那一刻的旧设置，一写就把主窗口刚改的预设开关抹掉）；
/// * **语义不同**：那份是"我对扩展的偏好"，这份是"画面现在长什么样"（关掉画面调节 =
///   写一份空的）。混在一起的话，卸载扩展时"清扩展设置"会顺手把画面状态清掉。
///
/// 写盘策略：**串行 + 原子**（先 `.tmp` 再 rename）。
/// * 串行：面板的 apply 是 220ms 防抖，拖完滑杆立刻点「重置」会连来两次；并发写同一个
///   `.tmp` 会互相踩（rename 时对方还没写完）。
/// * 原子：mpv 是另一个进程，播放子窗口随时可能读这份文件；半截 json 会被 `fromJson`
///   当成"没有设置"，表现为"调好的画面又回默认了"。
///
/// 读失败**永不抛**：文件坏了只该退回默认（画面等于原样），不能拖垮播放窗口。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'picture_pack.dart';

/// 文件名（与 `extension-settings.json` 同层：`<数据根>/dsanima/`）。
const String kPictureSettingsFileName = 'picture-settings.json';

/// 文件的完整路径（测试与诊断共用一份口径）。
File pictureSettingsFileOf(Directory supportDir) =>
    File(p.join(supportDir.path, 'dsanima', kPictureSettingsFileName));

/// 读 / 写画面调节设置的唯一入口（一个数据根一个实例）。
///
/// 为什么是类而不是两个自由函数：写要**排队**。`PictureController` 的保存回调是
/// fire-and-forget（界面不等落盘），两次快速操作会并发进来；把队列封在这里，
/// 调用方（`main.dart` 一个、测试若干）不需要知道这件事。
class PictureSettingsStore {
  PictureSettingsStore(this.supportDir);

  final Directory supportDir;

  /// 上一次写盘的完成信号（新写入排在它后面）。
  Future<void> _tail = Future<void>.value();

  File get file => pictureSettingsFileOf(supportDir);

  /// 读回上次的设置。文件不在 / 是坏 json / 目录不可读 → [PictureSettings.off]。
  Future<PictureSettings> load() async {
    try {
      if (!await file.exists()) return PictureSettings.off;
      final String text = await file.readAsString();
      if (text.trim().isEmpty) return PictureSettings.off;
      return PictureSettings.fromJson(jsonDecode(text));
    } catch (error) {
      debugPrint('[picture] 上次的画面设置读不出来（按没设置过处理）：$error');
      return PictureSettings.off;
    }
  }

  /// 保存（排队；本方法永不抛 —— 存不下来最坏是这次没记住，不该打断调画面）。
  Future<void> save(PictureSettings settings) {
    _tail = _tail.then((_) => _write(settings));
    return _tail;
  }

  Future<void> _write(PictureSettings settings) async {
    try {
      await file.parent.create(recursive: true);
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(settings.toJson()), flush: true);
      await tmp.rename(file.path);
    } catch (error) {
      debugPrint('[picture] 画面设置没存下来（下次改再试）：$error');
    }
  }
}
