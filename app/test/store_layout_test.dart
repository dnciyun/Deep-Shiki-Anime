/// 便携式数据根目录 + 旧位置清理的测试。
///
/// 用户 2026-10-11：「我刚解压的按理说应该是重置的，不在本地留垃圾，一套文件夹一套设置，
/// 重新解压出来的就是初始化的程序」。
///
/// 只碰临时目录（`Directory.systemTemp`），不读写真实用户数据。
library;

import 'dart:io';

import 'package:dsanima/state/store_layout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Directory _tempDir(String name) {
  final Directory dir = Directory.systemTemp.createTempSync('dsanima_$name');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

void main() {
  group('resolveDataRoot：便携式优先', () {
    test('默认把数据放在 exe 同目录的 DSAnima-data 下（解压一份 = 一套设置）', () async {
      final Directory root = _tempDir('portable');
      final Directory exe = Directory(p.join(root.path, 'app'))..createSync(recursive: true);

      final DataRoot data = await resolveDataRoot(exeDir: exe);

      expect(data.portable, isTrue);
      expect(data.fallbackReason, isNull);
      expect(data.path, p.join(exe.path, kPortableDataDirName));
      expect(Directory(data.path).existsSync(), isTrue, reason: '同一份文件夹复制两份 → 设置各自独立');
      expect(storeDirOf(Directory(data.path)).path, p.join(data.path, 'store'));
      expect(playerStoreDirOf(Directory(data.path)).path,
          p.join(data.path, 'player-store'));
    });

    test('DSANIMA_DATA_DIR 优先于一切（CI / 探针 / 多实例）', () async {
      final Directory root = _tempDir('env');
      final Directory exe = Directory(p.join(root.path, 'app'))..createSync(recursive: true);
      final String override = p.join(root.path, 'elsewhere', 'data');

      final DataRoot data = await resolveDataRoot(exeDir: exe, envOverride: override);

      expect(data.portable, isFalse);
      expect(data.path, override);
      expect(Directory(override).existsSync(), isTrue);
      expect(data.fallbackReason, contains(kDataDirEnvVar));
    });

    test('程序目录不可写 → 回落到给的支持目录，并说明原因', () async {
      final Directory root = _tempDir('readonly');
      // 用一个**文件**当"程序目录的父级"：在它下面建目录必然失败（等价于装到
      // Program Files 那种写不进去的情形，且不用改 ACL）。
      final File blocker = File(p.join(root.path, 'blocker'))..writeAsStringSync('x');
      final Directory fallback = Directory(p.join(root.path, 'fallback'));

      final DataRoot data = await resolveDataRoot(
        exeDir: Directory(p.join(blocker.path, 'app')),
        fallbackDir: fallback,
      );

      expect(data.portable, isFalse);
      expect(data.path, fallback.path);
      expect(data.fallbackReason, contains('不可写'));
    });
  });

  group('cleanupLegacyDataLocations：新版不读的旧位置都清掉', () {
    test('清 %APPDATA%\\com.dsanima\\*、文档\\DSAnima、rqbit 的 DHT 缓存', () async {
      final Directory root = _tempDir('legacy');
      final Directory dataRoot = Directory(p.join(root.path, 'portable', 'DSAnima-data'))
        ..createSync(recursive: true);
      File(p.join(dataRoot.path, 'keep.txt')).writeAsStringSync('mine');

      final Directory roaming = Directory(p.join(root.path, 'roaming'))..createSync(recursive: true);
      final Directory vendor = Directory(p.join(roaming.path, 'com.dsanima'))
        ..createSync(recursive: true);
      final Directory oldSupport = Directory(p.join(vendor.path, 'dsanima'))
        ..createSync(recursive: true);
      File(p.join(oldSupport.path, 'engine.log')).writeAsStringSync('stale');
      final Directory documents = Directory(p.join(root.path, 'documents'))..createSync(recursive: true);
      final Directory oldHive = Directory(p.join(documents.path, 'DSAnima'))
        ..createSync(recursive: true);
      File(p.join(oldHive.path, 'dsanima.hive')).writeAsStringSync('old');
      final Directory local = Directory(p.join(root.path, 'local'))..createSync(recursive: true);
      final File dht = File(p.join(local.path, 'rqbit', 'dht', 'cache', 'dht.json'));
      dht.createSync(recursive: true);
      dht.writeAsStringSync('{}');

      final LegacyCleanup cleanup = await cleanupLegacyDataLocations(
        dataRoot: dataRoot,
        roamingDir: roaming,
        documentsDir: documents,
        localDir: local,
      );

      expect(cleanup.changed, isTrue);
      expect(oldSupport.existsSync(), isFalse);
      expect(oldHive.existsSync(), isFalse);
      expect(dht.existsSync(), isFalse);
      expect(Directory(p.join(local.path, 'rqbit')).existsSync(), isFalse,
          reason: '空掉的 rqbit 目录也该收掉');
      expect(vendor.existsSync(), isFalse, reason: '厂商目录空了就一起删');
      expect(File(p.join(dataRoot.path, 'keep.txt')).readAsStringSync(), 'mine');
    });

    test('数据根目录就在旧位置里时：一个字都不能删', () async {
      final Directory root = _tempDir('self');
      final Directory roaming = Directory(p.join(root.path, 'roaming'))..createSync(recursive: true);
      // 数据根目录 == %APPDATA%\com.dsanima\dsanima（legacy 清理的目标之一）
      final Directory dataRoot = Directory(p.join(roaming.path, 'com.dsanima', 'dsanima'))
        ..createSync(recursive: true);
      File(p.join(dataRoot.path, 'dsanima.hive')).writeAsStringSync('live');
      final Directory documents = Directory(p.join(root.path, 'documents'))..createSync(recursive: true);
      final Directory local = Directory(p.join(root.path, 'local'))..createSync(recursive: true);

      final LegacyCleanup cleanup = await cleanupLegacyDataLocations(
        dataRoot: dataRoot,
        roamingDir: roaming,
        documentsDir: documents,
        localDir: local,
      );

      expect(cleanup.removed, isEmpty);
      expect(File(p.join(dataRoot.path, 'dsanima.hive')).readAsStringSync(), 'live');
    });

    test('绝不删数据根目录的祖先目录', () async {
      final Directory root = _tempDir('ancestor');
      // 数据根目录 = <roaming>/com.dsanima/dsanima，于是 com.dsanima 是它的祖先。
      final Directory roaming = Directory(p.join(root.path, 'roaming'))..createSync(recursive: true);
      final Directory dataRoot = Directory(p.join(roaming.path, 'com.dsanima', 'dsanima'))
        ..createSync(recursive: true);
      File(p.join(dataRoot.path, 'x')).writeAsStringSync('live');
      final Directory sibling = Directory(p.join(roaming.path, 'com.dsanima', 'other'))
        ..createSync(recursive: true);
      File(p.join(sibling.path, 'y')).writeAsStringSync('other');

      await cleanupLegacyDataLocations(
        dataRoot: dataRoot,
        roamingDir: roaming,
        documentsDir: Directory(p.join(root.path, 'documents'))..createSync(recursive: true),
        localDir: Directory(p.join(root.path, 'local'))..createSync(recursive: true),
      );

      expect(dataRoot.existsSync(), isTrue);
      expect(Directory(p.join(roaming.path, 'com.dsanima')).existsSync(), isTrue,
          reason: '祖先目录不能删');
    });

    test('旧位置本来就没有 → 安静返回（不报错、不瞎建目录）', () async {
      final Directory root = _tempDir('none');
      final Directory dataRoot = Directory(p.join(root.path, 'portable'))..createSync(recursive: true);

      final LegacyCleanup cleanup = await cleanupLegacyDataLocations(
        dataRoot: dataRoot,
        roamingDir: Directory(p.join(root.path, 'roaming')),
        documentsDir: Directory(p.join(root.path, 'documents')),
        localDir: Directory(p.join(root.path, 'local')),
      );

      expect(cleanup.changed, isFalse);
      expect(Directory(p.join(root.path, 'roaming')).existsSync(), isFalse);
    });
  });
}
