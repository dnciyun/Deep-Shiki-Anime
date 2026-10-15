/// 键值存储的关闭语义（用户 2026-10-11 第二阶段清单第 3 项：
/// 「关窗时主动释放 Hive 占位锁」）。
///
/// 为什么值得单测：Hive 对同一个 box 是**排他锁**（`<box>.lock`）。子窗口"彻底关闭"
/// 时如果不主动关 box，锁要等引擎拆除才释放 —— 而引擎拆除正是历史崩溃/卡死发生的地方。
/// 这条测试证明：`close()` 之后**同名 box 还能重新打开**（锁真的放掉了），
/// 而且数据没丢。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shikiin/infra/persistence.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('shikiin_hive_store_');
    Hive.init(tmp.path);
  });

  tearDown(() async {
    await Hive.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('close() 放掉锁：关掉之后同名 box 还能开，且数据还在', () async {
    final HiveStore store = await HiveStore.open('lock_probe');
    await store.put('resume:abc', 1234);
    expect(store.get('resume:abc'), 1234);

    await store.close();

    // 重新打开同名 box：锁没放掉的话这里会抛（"already open"/PathAccessException）。
    final HiveStore again = await HiveStore.open('lock_probe');
    expect(again.get('resume:abc'), 1234, reason: '关 box 不该丢数据');
    await again.close();
  });

  test('close() 之后读/写都是安全的空操作（收尾期别的代码路径还在读设置）', () async {
    final HiveStore store = await HiveStore.open('double_close');
    await store.put('k', 'v');
    await store.close();
    await store.close(); // 可重复调用，不抛
    expect(store.get('k'), isNull, reason: '存储已放掉 = 没有值（不该抛 HiveError）');
    await store.put('k2', 'v2'); // 空操作，不抛
  });
}
