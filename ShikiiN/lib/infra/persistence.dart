import 'package:hive_flutter/hive_flutter.dart';

/// 可替换的键值存储抽象，便于测试。
abstract class KeyValueStore {
  Object? get(String key);
  Future<void> put(String key, Object? value);

  /// 关掉底层存储、**放掉它占的锁**（可重复调用）。
  ///
  /// 用户 2026-10-11 第二阶段清单第 3 项：「关窗时主动释放 Hive 占位锁」。
  /// 注意语义边界：默认「关闭播放器」= **收起来**（引擎留着，box 还要用，**不能**关）；
  /// 只有子窗口**彻底关闭**（`_destroySelf`）时才关 —— 那时先把 box 放掉，
  /// 再让引擎/窗口消失，teardown 期手里就少一个文件句柄与锁。
  Future<void> close();
}

class HiveStore implements KeyValueStore {
  final Box _box;
  HiveStore(this._box);

  static Future<HiveStore> open(String boxName) async {
    final box = await Hive.openBox(boxName);
    return HiveStore(box);
  }

  /// 读：**关掉之后返回 null，不抛**。
  ///
  /// 为什么不让它抛：`close()` 是在"彻底关闭这一扇窗"的收尾里调的，而那一刻别的
  /// 代码路径（设置控制器、续播落盘、面板读设置）随时可能还在读 —— teardown 期
  /// 让一个无关的读抛出 `HiveError: Box has already been closed` 只会把日志搅乱、
  /// 甚至把收尾流程打断。语义上也说得通：存储已放掉 = 没有值。
  @override
  Object? get(String key) => _box.isOpen ? _box.get(key) : null;

  /// 写：关掉之后是空操作（同 [get] 的理由：收尾期不该有人因此报错）。
  @override
  Future<void> put(String key, Object? value) async {
    if (!_box.isOpen) return;
    await _box.put(key, value);
  }

  @override
  Future<void> close() async {
    if (_box.isOpen) await _box.close();
  }
}
