/// 压缩包条目守卫（`package_guard.dart`）的离线判据（1.1.0 M3 / T13）。
///
/// 守卫在"读 zip 头之后、写任何字节之前"跑，所以测试只用内存里手搓的条目表：
/// 恶意名字、重复条目、夹带、缺文件、条目数/大小/压缩比超限。
/// 断言精确到 [PackageIssue.code] 与被点名的 [PackageIssue.entry]。
library;

import 'package:dsanima_core/dsanima_core.dart';
import 'package:flutter_test/flutter_test.dart';

// ── 夹具 ────────────────────────────────────────────────────────────────────

/// 一个普通文件条目（默认 100 字节，压缩后 10 字节）。
PackageEntry _file(String name, {int size = 100, int compressed = 10}) =>
    PackageEntry(name: name, uncompressedSize: size, compressedSize: compressed);

/// 一个目录条目（`name` 以 `/` 结尾，`isDirectory: true`）。
PackageEntry _dir(String name) =>
    PackageEntry(name: name, uncompressedSize: 0, compressedSize: 0, isDirectory: true);

PackageCheck _check(
  List<PackageEntry> entries, {
  Set<String> expectedFiles = const <String>{'manifest.json'},
  PackageLimits limits = const PackageLimits(),
}) =>
    checkExtensionPackage(entries, expectedFiles: expectedFiles, limits: limits);

List<String> _codes(PackageCheck check) =>
    <String>[for (final PackageIssue issue in check.issues) issue.code];

PackageIssue _issue(PackageCheck check, String code) {
  final Iterable<PackageIssue> matching =
      check.issues.where((PackageIssue issue) => issue.code == code);
  expect(matching, hasLength(1), reason: 'issues: ${check.issues}');
  return matching.single;
}

// ── 路径判据的样例表 ────────────────────────────────────────────────────────

/// 危险条目名 → 理由里必须出现的关键词。
final List<({String path, String reason})> _unsafeCases = <({String path, String reason})>[
  (path: '', reason: '路径为空'),
  (path: '/etc/passwd', reason: '绝对路径'),
  (path: '//server/share/x', reason: '绝对路径'),
  (path: r'\server\share\x', reason: '反斜杠'),
  (path: r'a\b', reason: '反斜杠'),
  (path: 'C:/Windows/x', reason: '盘符'),
  (path: 'c:x', reason: '盘符'),
  (path: 'a:b', reason: '盘符'),
  (path: 'ab:c', reason: '冒号'),
  (path: 'a/b:c', reason: '冒号'),
  (path: '../evil', reason: '..'),
  (path: 'a/../b', reason: '..'),
  (path: '..', reason: '..'),
  (path: '.', reason: '.'),
  (path: 'a/./b', reason: '.'),
  (path: 'a//b', reason: '空路径段'),
  (path: 'a/', reason: '空路径段'),
  (path: ' padded.txt', reason: '首尾有空格'),
  (path: 'a /b', reason: '首尾有空格'),
  (path: 'a/b ', reason: '首尾有空格'),
  (path: 'a./b', reason: '以点结尾'),
  (path: 'a.b./x', reason: '以点结尾'),
  (path: 'a<b', reason: '不允许的字符'),
  (path: 'a>b', reason: '不允许的字符'),
  (path: 'a"b', reason: '不允许的字符'),
  (path: 'a|b', reason: '不允许的字符'),
  (path: 'a?b', reason: '不允许的字符'),
  (path: 'a*b', reason: '不允许的字符'),
  (path: 'a\u0001b', reason: '不允许的字符'),
  (path: 'CON', reason: '保留设备名'),
  (path: 'con.txt', reason: '保留设备名'),
  (path: 'NUL.txt', reason: '保留设备名'),
  (path: 'com1.log', reason: '保留设备名'),
  (path: 'lpt9', reason: '保留设备名'),
  (path: 'aux.glsl', reason: '保留设备名'),
  (path: 'prn', reason: '保留设备名'),
  (path: 'a' * 201, reason: '路径段太长'),
  (path: 'a' * 221, reason: '路径太长'),
];

void main() {
  group('unsafeRelativePathReason：可用的相对路径', () {
    test('普通相对路径（含 . / 非 ASCII / 内部点）放行', () {
      for (final String path in <String>[
        'manifest.json',
        'shaders/a.glsl',
        'a/b/c.txt',
        'A-B_c.1.glsl',
        'dir.with.dots/file.glsl',
        'a..b/c.glsl',
        'com0/x',
        'lpt10',
        'comifer/x',
        'my.con',
        'contact.foo',
        '着色器/动画.glsl',
      ]) {
        expect(unsafeRelativePathReason(path), isNull, reason: 'path=$path');
      }
    });

    test('单段 200 字符与整条 220 字符恰好都在界内', () {
      final String segment200 = 'a' * 200;
      expect(unsafeRelativePathReason(segment200), isNull);
      final String path220 = '${'a' * 110}/${'b' * 109}';
      expect(path220.length, 220);
      expect(unsafeRelativePathReason(path220), isNull);
    });

    test('保留设备名只认第一段：my.con / console 放行，con.anything 拒绝', () {
      expect(unsafeRelativePathReason('my.con'), isNull);
      expect(unsafeRelativePathReason('console'), isNull);
      expect(unsafeRelativePathReason('con.anything'), isNotNull);
      expect(unsafeRelativePathReason('dir/con.txt'), isNotNull);
    });
  });

  group('unsafeRelativePathReason：拒绝并说明原因', () {
    test('危险路径逐条拒绝，理由对得上', () {
      for (final ({String path, String reason}) item in _unsafeCases) {
        final String? reason = unsafeRelativePathReason(item.path);
        expect(reason, isNotNull, reason: '应拒绝：${item.path}');
        expect(reason, contains(item.reason), reason: '路径 ${item.path} 的理由');
      }
    });

    test('空串的文案精确为「路径为空」', () {
      expect(unsafeRelativePathReason(''), '路径为空');
    });

    test('超长路径的文案带其实测长度与 220 上限', () {
      final String reason = unsafeRelativePathReason('a' * 221)!;
      expect(reason, contains('221'));
      expect(reason, contains('220'));
    });

    test('检查顺序：反斜杠先于 .. 报（打包工具用错分隔符时优先说这个）', () {
      final String reason = unsafeRelativePathReason(r'..\evil')!;
      expect(reason, contains('反斜杠'));
      expect(reason, isNot(contains('..')));
    });

    test('目录条目的尾斜杠必须先剥掉：直接喂 "shaders/" 会被判空路径段', () {
      final String reason = unsafeRelativePathReason('shaders/')!;
      expect(reason, contains('空路径段'));
    });
  });

  group('checkExtensionPackage：合法包', () {
    test('最小合法包：无 issue，fileCount 与总字节正确', () {
      final PackageCheck check = _check(
        <PackageEntry>[
          _file('manifest.json', size: 100, compressed: 10),
          _file('a.glsl', size: 200, compressed: 20),
        ],
        expectedFiles: const <String>{'manifest.json', 'a.glsl'},
      );
      expect(check.ok, isTrue);
      expect(check.issues, isEmpty);
      expect(check.fileCount, 2);
      expect(check.totalUncompressedBytes, 300);
    });

    test('expectedFiles 与条目名都大小写不敏感', () {
      final PackageCheck check = _check(
        <PackageEntry>[
          _file('Manifest.JSON', size: 10, compressed: 1),
          _file('shaders/A.glsl', size: 20, compressed: 2),
        ],
        expectedFiles: const <String>{'manifest.json', 'SHADERS/a.GLSL'},
      );
      expect(check.ok, isTrue);
      expect(check.fileCount, 2);
      expect(check.totalUncompressedBytes, 30);
    });

    test('目录条目不计文件数、不计总字节、不过白名单，但会跟随创建目录', () {
      final PackageCheck check = _check(
        <PackageEntry>[
          _dir('shaders/'),
          _file('manifest.json', size: 100, compressed: 10),
          _file('shaders/a.glsl', size: 200, compressed: 20),
        ],
        expectedFiles: const <String>{'manifest.json', 'shaders/a.glsl'},
      );
      expect(check.ok, isTrue);
      expect(check.fileCount, 2);
      expect(check.totalUncompressedBytes, 300);
    });

    test('isDirectory=true 但名字不以 / 结尾：照常按目录处理（不计数、不过白名单）', () {
      final PackageCheck check = _check(
        <PackageEntry>[_dir('assets')],
        expectedFiles: const <String>{'manifest.json'},
      );
      expect(check.fileCount, 0);
      expect(check.totalUncompressedBytes, 0);
      expect(_codes(check), <String>['missing-file']);
    });

    test('只有目录条目 + 空 expectedFiles → 通过（目录本身不是文件）', () {
      final PackageCheck check = _check(
        <PackageEntry>[_dir('shaders/')],
        expectedFiles: const <String>{},
      );
      expect(check.ok, isTrue);
      expect(check.fileCount, 0);
      expect(check.totalUncompressedBytes, 0);
    });
  });

  group('checkExtensionPackage：危险条目名与重复', () {
    test('每个危险条目名 → unsafe-path，entry 保留原始写法，不计文件数/总字节', () {
      for (final String name in <String>[
        '/etc/passwd',
        'C:/Windows/x.dll',
        r'a\b.txt',
        '../evil',
        'a//b',
        'CON',
        'nul.txt',
        'bad?.txt',
        'trailing.',
        ' padded.txt',
      ]) {
        final PackageCheck check = _check(
          <PackageEntry>[_file(name, size: 999)],
          expectedFiles: const <String>{},
        );
        expect(check.ok, isFalse, reason: 'name=$name');
        expect(_codes(check), <String>['unsafe-path'], reason: 'name=$name');
        expect(_issue(check, 'unsafe-path').entry, name);
        expect(check.fileCount, 0, reason: 'name=$name');
        expect(check.totalUncompressedBytes, 0, reason: 'name=$name');
      }
    });

    test('目录条目名先剥掉尾斜杠再校验；问题条目保留原始带斜杠写法', () {
      final PackageCheck check = _check(
        <PackageEntry>[_dir('../evil/')],
        expectedFiles: const <String>{},
      );
      expect(_codes(check), <String>['unsafe-path']);
      expect(_issue(check, 'unsafe-path').entry, '../evil/');
      expect(check.fileCount, 0);
    });

    test('isDirectory=false 但名字以 / 结尾：不当目录，直接报 unsafe-path', () {
      final PackageCheck check = _check(
        <PackageEntry>[_file('shaders/')],
        expectedFiles: const <String>{},
      );
      expect(_codes(check), <String>['unsafe-path']);
      expect(_issue(check, 'unsafe-path').entry, 'shaders/');
      expect(check.fileCount, 0);
    });

    test('重复条目（仅大小写不同）→ duplicate-entry；后一个不计文件数/总字节', () {
      final PackageCheck check = _check(
        <PackageEntry>[
          _file('Shaders/A.glsl', size: 10, compressed: 1),
          _file('shaders/a.glsl', size: 20, compressed: 2),
        ],
        expectedFiles: const <String>{'shaders/a.glsl'},
      );
      expect(_codes(check), <String>['duplicate-entry']);
      expect(_issue(check, 'duplicate-entry').entry, 'shaders/a.glsl');
      expect(check.fileCount, 1);
      expect(check.totalUncompressedBytes, 10);
    });

    test('重复的目录条目（仅大小写不同）也报 duplicate-entry', () {
      final PackageCheck check = _check(
        <PackageEntry>[_dir('Shaders/'), _dir('shaders/')],
        expectedFiles: const <String>{},
      );
      expect(_codes(check), <String>['duplicate-entry']);
      expect(check.fileCount, 0);
    });

    test('不安全条目不计入文件数与总字节（先到先得）', () {
      final PackageCheck check = _check(
        <PackageEntry>[
          _file('/abs', size: 999),
          _file('a.glsl', size: 50, compressed: 5),
        ],
        expectedFiles: const <String>{'a.glsl'},
      );
      expect(_codes(check), <String>['unsafe-path']);
      expect(check.fileCount, 1);
      expect(check.totalUncompressedBytes, 50);
    });
  });

  group('checkExtensionPackage：白名单（夹带 / 缺失）', () {
    test('清单外多一个文件 → unexpected-file，entry 点名它', () {
      final PackageCheck check = _check(
        <PackageEntry>[
          _file('manifest.json', size: 100, compressed: 10),
          _file('evil.exe', size: 50, compressed: 5),
        ],
        expectedFiles: const <String>{'manifest.json'},
      );
      expect(_codes(check), <String>['unexpected-file']);
      expect(_issue(check, 'unexpected-file').entry, 'evil.exe');
      expect(check.fileCount, 2);
      // 与 PackageCheck.totalUncompressedBytes 的注释同口径：只排除"名字校验失败"
      // 的条目，没在清单里的文件仍然计入（保守）。
      expect(check.totalUncompressedBytes, 150);
    });

    test('清单声明但包里没有 → missing-file，entry 用清单里的原始路径', () {
      final PackageCheck check = _check(
        <PackageEntry>[_file('manifest.json', size: 100, compressed: 10)],
        expectedFiles: const <String>{'manifest.json', 'a.glsl'},
      );
      expect(_codes(check), <String>['missing-file']);
      expect(_issue(check, 'missing-file').entry, 'a.glsl');
      expect(check.fileCount, 1);
      expect(check.totalUncompressedBytes, 100);
    });

    test('危险条目 + 夹带 + 缺失可以同时报出来', () {
      final PackageCheck check = _check(
        <PackageEntry>[
          _file('/abs', size: 999),
          _file('manifest.json', size: 100, compressed: 10),
          _file('evil.exe', size: 5, compressed: 1),
        ],
        expectedFiles: const <String>{'manifest.json', 'a.glsl'},
      );
      expect(
        _codes(check),
        containsAll(<String>['unsafe-path', 'unexpected-file', 'missing-file']),
      );
      expect(check.fileCount, 2);
    });

    test('目录条目不在白名单里不算夹带', () {
      final PackageCheck check = _check(
        <PackageEntry>[_dir('assets/')],
        expectedFiles: const <String>{'manifest.json'},
      );
      expect(_codes(check), <String>['missing-file']);
      expect(check.fileCount, 0);
      expect(check.totalUncompressedBytes, 0);
    });

    test('空条目表 → empty（连白名单都不用看）', () {
      final PackageCheck check = _check(
        const <PackageEntry>[],
        expectedFiles: const <String>{},
      );
      expect(check.ok, isFalse);
      expect(_codes(check), <String>['empty']);
      expect(check.fileCount, 0);
      expect(check.totalUncompressedBytes, 0);
    });
  });

  group('checkExtensionPackage：条目数 / 单文件 / 总大小限制', () {
    test('单文件解压后超上限 → too-large；恰好等于上限通过', () {
      final PackageCheck atLimit = _check(
        <PackageEntry>[_file('manifest.json', size: 10, compressed: 1)],
        expectedFiles: const <String>{'manifest.json'},
        limits: const PackageLimits(maxEntryBytes: 10),
      );
      expect(atLimit.ok, isTrue);

      final PackageCheck over = _check(
        <PackageEntry>[_file('manifest.json', size: 11, compressed: 1)],
        expectedFiles: const <String>{'manifest.json'},
        limits: const PackageLimits(maxEntryBytes: 10),
      );
      expect(_codes(over), <String>['too-large', 'missing-file']);
      expect(_issue(over, 'too-large').entry, 'manifest.json');
      // 超限条目仍计入 fileCount，但不计入总字节（先 continue 了）。
      expect(over.fileCount, 1);
      expect(over.totalUncompressedBytes, 0);
    });

    test('整包解压后超上限 → too-large；恰好等于上限通过', () {
      final PackageCheck atLimit = _check(
        <PackageEntry>[
          _file('manifest.json', size: 6, compressed: 1),
          _file('a.glsl', size: 4, compressed: 1),
        ],
        expectedFiles: const <String>{'manifest.json', 'a.glsl'},
        limits: const PackageLimits(maxTotalBytes: 10),
      );
      expect(atLimit.ok, isTrue);
      expect(atLimit.totalUncompressedBytes, 10);

      final PackageCheck over = _check(
        <PackageEntry>[
          _file('manifest.json', size: 6, compressed: 1),
          _file('a.glsl', size: 5, compressed: 1),
        ],
        expectedFiles: const <String>{'manifest.json', 'a.glsl'},
        limits: const PackageLimits(maxTotalBytes: 10),
      );
      expect(_codes(over), <String>['too-large']);
      expect(_issue(over, 'too-large').message, contains('整包上限'));
      expect(over.totalUncompressedBytes, 11);
    });

    test('文件条目数超上限 → too-large；恰好等于上限通过，目录条目不占名额', () {
      final List<PackageEntry> atLimit = <PackageEntry>[
        _file('manifest.json', size: 1, compressed: 1),
        _file('a.glsl', size: 1, compressed: 1),
        _dir('shaders/'),
        _dir('other/'),
      ];
      final PackageCheck ok = _check(
        atLimit,
        expectedFiles: const <String>{'manifest.json', 'a.glsl'},
        limits: const PackageLimits(maxEntries: 2),
      );
      expect(ok.ok, isTrue);
      expect(ok.fileCount, 2);

      final PackageCheck over = _check(
        <PackageEntry>[
          _file('manifest.json', size: 1, compressed: 1),
          _file('a.glsl', size: 1, compressed: 1),
          _file('b.glsl', size: 1, compressed: 1),
        ],
        expectedFiles: const <String>{'manifest.json', 'a.glsl', 'b.glsl'},
        limits: const PackageLimits(maxEntries: 2),
      );
      expect(_codes(over), <String>['too-large']);
      expect(_issue(over, 'too-large').message, contains('文件条目 3 个'));
      expect(over.fileCount, 3);
    });

    test('负数大小（zip 头坏了）→ too-large，且不计总字节', () {
      for (final PackageEntry bad in <PackageEntry>[
        _file('manifest.json', size: -1, compressed: 1),
        _file('manifest.json', size: 100, compressed: -1),
      ]) {
        final PackageCheck check = _check(
          <PackageEntry>[bad],
          expectedFiles: const <String>{'manifest.json'},
        );
        expect(_codes(check), <String>['too-large', 'missing-file'],
            reason: 'size=${bad.uncompressedSize}/${bad.compressedSize}');
        expect(check.totalUncompressedBytes, 0);
      }
    });

    test('默认上限就是导出常量（512 条目 / 32MB 单文件 / 96MB 整包 / 200 倍压缩比）', () {
      const PackageLimits limits = PackageLimits();
      expect(limits.maxEntries, kPackageMaxEntries);
      expect(limits.maxEntryBytes, kPackageMaxEntryBytes);
      expect(limits.maxTotalBytes, kPackageMaxTotalBytes);
      expect(limits.maxCompressionRatio, kPackageMaxCompressionRatio);
      expect(kPackageMaxEntries, 512);
      expect(kPackageMaxEntryBytes, 32 * 1024 * 1024);
      expect(kPackageMaxTotalBytes, 96 * 1024 * 1024);
      expect(kPackageMaxCompressionRatio, 200);
    });

    test('默认上限下 513 个文件条目被拒（512 是上限）', () {
      final List<PackageEntry> entries = <PackageEntry>[
        for (int i = 0; i < kPackageMaxEntries + 1; i++)
          _file('f$i.bin', size: 1, compressed: 1),
      ];
      final Set<String> expected = <String>{for (final PackageEntry entry in entries) entry.name};
      final PackageCheck check = _check(entries, expectedFiles: expected);
      expect(_codes(check), <String>['too-large']);
      expect(_issue(check, 'too-large').message, contains('文件条目 513 个'));
      expect(check.fileCount, kPackageMaxEntries + 1);
      expect(check.totalUncompressedBytes, kPackageMaxEntries + 1);
    });
  });

  group('checkExtensionPackage：压缩比（解压炸弹）', () {
    test('解压后有内容但压缩后 0 字节 → ratio', () {
      final PackageCheck check = _check(
        <PackageEntry>[_file('manifest.json', size: 100, compressed: 0)],
        expectedFiles: const <String>{'manifest.json'},
      );
      expect(_codes(check), <String>['ratio']);
      expect(_issue(check, 'ratio').entry, 'manifest.json');
      expect(_issue(check, 'ratio').message, contains('压缩比异常'));
    });

    test('压缩比超过上限 → ratio；恰好等于上限通过', () {
      final PackageCheck over = _check(
        <PackageEntry>[_file('manifest.json', size: 21, compressed: 10)],
        expectedFiles: const <String>{'manifest.json'},
        limits: const PackageLimits(maxCompressionRatio: 2),
      );
      expect(_codes(over), <String>['ratio']);
      expect(_issue(over, 'ratio').message, contains('2'));

      final PackageCheck atLimit = _check(
        <PackageEntry>[_file('manifest.json', size: 20, compressed: 10)],
        expectedFiles: const <String>{'manifest.json'},
        limits: const PackageLimits(maxCompressionRatio: 2),
      );
      expect(atLimit.ok, isTrue);
    });

    test('空文件（0/0）不做压缩比判定', () {
      final PackageCheck check = _check(
        <PackageEntry>[_file('manifest.json', size: 0, compressed: 0)],
        expectedFiles: const <String>{'manifest.json'},
      );
      expect(check.ok, isTrue);
      expect(check.fileCount, 1);
      expect(check.totalUncompressedBytes, 0);
    });

    test('压缩后为负 → too-large（负数判据先于压缩比）', () {
      final PackageCheck check = _check(
        <PackageEntry>[_file('manifest.json', size: 100, compressed: -1)],
        expectedFiles: const <String>{'manifest.json'},
      );
      expect(_codes(check), <String>['too-large', 'missing-file']);
      expect(_issue(check, 'too-large').message, contains('负数'));
    });

    test('没在清单里的炸弹只报 unexpected-file（白名单判定先行）', () {
      final PackageCheck check = _check(
        <PackageEntry>[_file('bomb.bin', size: 10000, compressed: 0)],
        expectedFiles: const <String>{},
      );
      expect(_codes(check), <String>['unexpected-file']);
    });
  });

  group('PackageIssue / PackageCheck 辅助', () {
    test('PackageIssue.toString 带不带 entry 两种写法', () {
      expect(
        const PackageIssue('ratio', '疑似解压炸弹', entry: 'a.glsl').toString(),
        'ratio(a.glsl): 疑似解压炸弹',
      );
      expect(const PackageIssue('empty', '压缩包是空的').toString(), 'empty: 压缩包是空的');
    });

    test('PackageCheck.ok 只在 issues 为空时为 true', () {
      expect(
        const PackageCheck(
          issues: <PackageIssue>[],
          totalUncompressedBytes: 0,
          fileCount: 0,
        ).ok,
        isTrue,
      );
      expect(
        const PackageCheck(
          issues: <PackageIssue>[PackageIssue('empty', '压缩包是空的')],
          totalUncompressedBytes: 0,
          fileCount: 0,
        ).ok,
        isFalse,
      );
    });
  });

  group('条目总数上限（含目录条目，第六十三轮补）', () {
    test('目录条目也吃条目总数上限：超过 maxTotalEntries 直接拒', () {
      final List<PackageEntry> entries = <PackageEntry>[
        for (int i = 0; i < 4; i++)
          PackageEntry(
            name: 'shaders/d$i/',
            uncompressedSize: 0,
            compressedSize: 0,
            isDirectory: true,
          ),
        const PackageEntry(
          name: 'manifest.json',
          uncompressedSize: 10,
          compressedSize: 10,
        ),
      ];
      final PackageCheck check = checkExtensionPackage(
        entries,
        expectedFiles: <String>{'manifest.json'},
        limits: const PackageLimits(maxTotalEntries: 4),
      );
      expect(check.ok, isFalse);
      expect(check.issues.single.code, 'too-large');
      expect(check.issues.single.message, contains('条目总数'));
    });

    test('默认上限是 2048（只数文件的上限仍是 512）', () {
      expect(const PackageLimits().maxTotalEntries, kPackageMaxTotalEntries);
      expect(const PackageLimits().maxTotalEntries, 2048);
      expect(const PackageLimits().maxEntries, kPackageMaxEntries);
    });
  });
}
