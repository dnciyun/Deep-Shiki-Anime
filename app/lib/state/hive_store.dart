/// 持久化与系统选择器的真实实现（app 层负责，注入给 core）。
library;

import 'package:dsanima_core/sources/kv.dart' show KeyValueStore;
import 'package:file_picker/file_picker.dart';
import 'package:hive/hive.dart';

import '../domain/ports.dart';

/// Hive 实现的 [KeyValueStore]（core 的持久化端口正本）。
///
/// core 的 `subscriptions` / `queue` / `cached sources` 与宿主的设置都落在这里；
/// 宿主决定 box 名，core 只认接口。
class HiveKeyValueStore implements KeyValueStore {
  HiveKeyValueStore(this._box);

  final Box<Object?> _box;

  static Future<HiveKeyValueStore> open(String boxName) async {
    final Box<Object?> box = await Hive.openBox<Object?>(boxName);
    return HiveKeyValueStore(box);
  }

  /// 关闭 box：**把待写内容刷出去 + 放掉 `<box>.lock`**。
  ///
  /// 为什么退出流程要显式调它（用户 2026-10-12 第 10 轮：「关闭程序时会卡一会儿才关掉」
  /// 的配套修复）：Hive 的 `<box>.lock` 是**进程持有的排他锁**，不关就一直占着。
  /// 窗口改成"点 X 秒关"之后，进程还会活一两秒（在后台等 rqbit 边车优雅退出），
  /// 这段时间里用户双击重开会撞 `PathAccessException: lock failed`。
  /// 提前放锁之后"关掉马上重开"是安全的；顺带 `close()` 会把异步写排队的内容落盘，
  /// 比 `exit(0)` 直接掐掉进程更稳。
  Future<void> close() async {
    if (!_box.isOpen) return;
    await _box.close();
  }

  /// box 是否还开着（测试/诊断用）。
  bool get isOpen => _box.isOpen;

  @override
  Object? get(String key) => _box.get(key);

  @override
  Future<void> put(String key, Object? value) => _box.put(key, value);

  @override
  Future<void> delete(String key) => _box.delete(key);

  @override
  Iterable<String> get keys => _box.keys.map((Object? k) => k.toString());

  @override
  Future<void> clear() async {
    await _box.clear();
  }
}

/// `file_picker` 实现（选下载目录 / 选引擎 exe）。
class FilePickerPort implements PickerPort {
  const FilePickerPort();

  @override
  Future<String?> pickDirectory({String? title}) =>
      FilePicker.platform.getDirectoryPath(dialogTitle: title ?? '选择目录');

  @override
  Future<String?> pickFile({
    String? title,
    List<String> extensions = const <String>[],
  }) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      dialogTitle: title ?? '选择文件',
      type: extensions.isEmpty ? FileType.any : FileType.custom,
      allowedExtensions: extensions.isEmpty ? null : extensions,
    );
    return result == null || result.files.isEmpty ? null : result.files.first.path;
  }
}
