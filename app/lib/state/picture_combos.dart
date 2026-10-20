/// 「我的组合」的落盘：`<数据根>/dsanima/picture-combos.json`。
///
/// 为什么与 `picture-settings.json` 分开（而不是塞进同一份）：
/// * **写者只有一个**：这份只有主窗口的画面页写；播放窗口只读（列表进右键菜单）。
///   而 `picture-settings.json` 两个窗口都会写（播放窗口每次真正下发之后回写）。
///   合成一份 = 播放窗口一次 `apply` 就把用户刚存的组合抹掉；
/// * **语义不同**：那份是"现在长什么样"，这份是"用户攒下来的几套"。
///   卸载扩展时"清掉这个包的组合"与"画面回到默认"是两件事。
///
/// 写盘策略照 `picture_settings_io.dart`：**串行 + 原子**。
/// * 串行：保存之后紧跟一次删除（用户在对话框里手很快）会并发写同一个 `.tmp`，
///   谁先 rename 谁赢，另一边报 ENOENT；
/// * 原子：播放窗口随时可能来读（右键菜单现读），半截 json 会被当成"没有组合"，
///   表现为"我刚存的组合不见了"。
///
/// 读失败**永不抛**：文件坏了只该"没有自定义组合"，不能拖垮画面页或播放窗口。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../domain/picture_combo.dart';

/// 文件名（与 `picture-settings.json` / `extension-settings.json` 同层）。
const String kPictureCombosFileName = 'picture-combos.json';

/// 文件完整路径（测试与诊断共用一份口径）。
File pictureCombosFileOf(Directory supportDir) =>
    File(p.join(supportDir.path, 'dsanima', kPictureCombosFileName));

/// 读 / 写「我的组合」的唯一入口（一个数据根一个实例）。
///
/// 为什么是类而不是两个自由函数：写要**排队**（见文件头），把队列封在这里，
/// 调用方（画面页、播放窗口）不需要知道这件事。
class PictureCombosStore {
  PictureCombosStore(this.supportDir);

  final Directory supportDir;

  /// 上一次写盘的完成信号（新写入排在它后面）。
  Future<void> _tail = Future<void>.value();

  File get file => pictureCombosFileOf(supportDir);

  /// 读回全部组合。文件不在 / 坏 json / 目录不可读 → 空表。
  Future<Map<String, List<PictureCombo>>> load() async {
    try {
      if (!await file.exists()) return const <String, List<PictureCombo>>{};
      final String text = await file.readAsString();
      if (text.trim().isEmpty) return const <String, List<PictureCombo>>{};
      return combosFromJson(jsonDecode(text));
    } catch (error) {
      debugPrint('[picture] 「我的组合」读不出来（按没有自定义组合处理）：$error');
      return const <String, List<PictureCombo>>{};
    }
  }

  /// 保存（排队；本方法永不抛 —— 存不下来最坏是这次没记住，不该打断调画面）。
  Future<void> save(Map<String, List<PictureCombo>> byPack) {
    _tail = _tail.then((_) => _write(byPack));
    return _tail;
  }

  Future<void> _write(Map<String, List<PictureCombo>> byPack) async {
    try {
      await file.parent.create(recursive: true);
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(combosToJson(byPack)), flush: true);
      await tmp.rename(file.path);
    } catch (error) {
      debugPrint('[picture] 「我的组合」没存下来（下次再试）：$error');
    }
  }
}
