/// 封面缓存清理测试（用户 2026-10-11 第二阶段清单第 7 项：「一个月自动清，
/// 设置里可选清除周期 / 不清除 / 立即清一次」）。
///
/// 背景：`HttpCoverCache.maxAge`（7 天）只决定"过期就重新下载"，**过期文件从不删除**
/// ⇒ `<支持目录>/cache/covers` 只涨不减。所以清理规则要单独钉住：
/// 只删"超过周期没被碰过"的，新鲜的必须留着（否则每次启动都在重下封面）。
library;

import 'dart:io';

import 'package:dsanima/state/cover_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 造一个指定修改时间的缓存文件。
File _cover(Directory dir, String name, {required DateTime modifiedAt}) {
  final File f = File(p.join(dir.path, name))..createSync(recursive: true);
  f.writeAsBytesSync(List<int>.filled(1024, 0x42));
  f.setLastModifiedSync(modifiedAt);
  return f;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dsanima_cover_gc_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('sweepCoverCache：只删过期的，新鲜的留着', () async {
    final Directory dir = Directory(p.join(tmp.path, 'covers'))..createSync();
    final DateTime now = DateTime(2026, 10, 11, 12);
    final File fresh = _cover(dir, 'fresh.webp', modifiedAt: now.subtract(const Duration(days: 3)));
    final File old = _cover(dir, 'old.jpg', modifiedAt: now.subtract(const Duration(days: 40)));
    final File old2 = _cover(dir, 'old2.png', modifiedAt: now.subtract(const Duration(days: 90)));

    final CoverCacheSweep sweep = await sweepCoverCache(
      dir,
      maxAge: const Duration(days: 30),
      clock: () => now,
    );

    expect(sweep.deleted, 2);
    expect(sweep.bytes, 2048);
    expect(fresh.existsSync(), isTrue, reason: '新鲜的封面必须留着，否则每次启动都在重下');
    expect(old.existsSync(), isFalse);
    expect(old2.existsSync(), isFalse);
  });

  test('sweepCoverCache：maxAge = null = 全清（「清空缓存」那条路）', () async {
    final Directory dir = Directory(p.join(tmp.path, 'covers'))..createSync();
    final DateTime now = DateTime(2026, 10, 11, 12);
    _cover(dir, 'a.webp', modifiedAt: now);
    _cover(dir, 'b.webp', modifiedAt: now);

    final CoverCacheSweep sweep = await sweepCoverCache(dir, maxAge: null, clock: () => now);

    expect(sweep.deleted, 2);
    expect(dir.listSync(), isEmpty);
  });

  test('sweepCoverCache：目录不存在/空目录都不报错（启动时天天跑）', () async {
    final Directory missing = Directory(p.join(tmp.path, 'nope'));
    expect((await sweepCoverCache(missing, maxAge: const Duration(days: 30))).deleted, 0);

    final Directory empty = Directory(p.join(tmp.path, 'empty'))..createSync();
    expect((await sweepCoverCache(empty, maxAge: const Duration(days: 30))).deleted, 0);
  });

  test('coverCacheUsage：数得到张数与字节（设置页显示"当前占用"用）', () async {
    final Directory dir = Directory(p.join(tmp.path, 'covers'))..createSync();
    final DateTime now = DateTime(2026, 10, 11, 12);
    _cover(dir, 'a.webp', modifiedAt: now);
    _cover(dir, 'b.webp', modifiedAt: now);

    final CoverCacheUsage usage = await coverCacheUsage(dir);
    expect(usage.files, 2);
    expect(usage.bytes, 2048);

    expect((await coverCacheUsage(Directory(p.join(tmp.path, 'nope')))).files, 0);
  });

  test('coverCacheDirOf：装配根与设置页用同一个路径（唯一出处）', () {
    final Directory support = Directory(p.join(tmp.path, 'support'));
    expect(coverCacheDirOf(support).path, p.join(support.path, 'dsanima', 'cache', 'covers'));
  });

  // ── 用户 2026-10-12 第二十轮：「顺手清掉旧的 100px 缓存」────────────────────
  //
  // 缓存文件名是 URL 的 base64url（`coverCacheStem`），所以能反解回原始 URL 判断宽度档。
  group('清掉旧的 100px 封面（第二十轮）', () {
    const String grid =
        'https://lain.bgm.tv/r/100/pic/cover/l/8a/b2/312427_D2ZNm.jpg';
    const String common =
        'https://lain.bgm.tv/r/400/pic/cover/l/8a/b2/312427_D2ZNm.jpg';
    const String mikan =
        'https://mikanani.me/images/Bangumi/202610/abc.jpg?format=webp';

    test('判据：反解得回 Bangumi 的 /r/100/ 才算旧封面', () {
      expect(isLegacyThumbnailCoverFile('${coverCacheStem(grid)}.jpg'), isTrue);
      expect(isLegacyThumbnailCoverFile('${coverCacheStem(grid)}.webp.part'), isTrue,
          reason: '半截下载留下的 .part 也算（名字里同样带着那个 URL）');
      expect(isLegacyThumbnailCoverFile('${coverCacheStem(common)}.jpg'), isFalse,
          reason: '400 档是这一轮在用的');
      expect(isLegacyThumbnailCoverFile('${coverCacheStem(mikan)}.webp'), isFalse,
          reason: 'mikan 不是 Bangumi 图床，别碰');
      expect(isLegacyThumbnailCoverFile('fnv1a2b3c4d.jpg'), isFalse,
          reason: '反解不出来（URL 太长走了 FNV 折叠）→ 一律不动');
    });

    test('sweepLegacyThumbnailCovers：只删旧的 100px，其余一张不动', () async {
      final Directory dir = Directory(p.join(tmp.path, 'covers'))..createSync();
      final DateTime now = DateTime(2026, 10, 12, 20);
      final File old100 = _cover(dir, '${coverCacheStem(grid)}.jpg', modifiedAt: now);
      final File current = _cover(dir, '${coverCacheStem(common)}.jpg', modifiedAt: now);
      final File other = _cover(dir, '${coverCacheStem(mikan)}.webp', modifiedAt: now);

      final CoverCacheSweep sweep = await sweepLegacyThumbnailCovers(dir);

      expect(sweep.deleted, 1);
      expect(sweep.bytes, 1024);
      expect(old100.existsSync(), isFalse);
      expect(current.existsSync(), isTrue, reason: '正在用的档位必须留着');
      expect(other.existsSync(), isTrue, reason: '别的图的封面不归这条规则管');
    });

    test('sweepLegacyThumbnailCovers：目录不存在 / 空目录都不报错（每次启动都跑）', () async {
      final Directory missing = Directory(p.join(tmp.path, 'nope'));
      expect((await sweepLegacyThumbnailCovers(missing)).deleted, 0);

      final Directory empty = Directory(p.join(tmp.path, 'empty'))..createSync();
      expect((await sweepLegacyThumbnailCovers(empty)).deleted, 0);
    });
  });
}
