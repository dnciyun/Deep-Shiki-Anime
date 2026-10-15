/// 封面缓存**内存索引**（第三十七轮）。
///
/// 用户原话：「动漫库的封面图保存缓存，不然每次都要加载」。
///
/// 先把事实钉清楚：**封面本来就是落盘缓存的**（`HttpCoverCache` 把图写到
/// `<支持目录>/cache/covers/<base64url>.<真实扩展名>`，本机实测盘上 167 张 / 8.6 MB）——
/// 所以这一轮要修的不是"没缓存"，而是"缓存命中了还要等一次异步"：
/// 以前每次显示一张封面都要 `fileFor` → `_existing` → 最多 6 次 `File.exists()` 探扩展名，
/// 于是每一张卡、每一次进页面/滚动回来都会先空一帧灰底，看上去就是"又要加载一次"。
///
/// 这里钉住 [HttpCoverCache.warmUp] / [HttpCoverCache.cachedNow] /
/// [HttpCoverCache.invalidate] 三件事：**装什么、命中给什么、清缓存之后不许再给**。
library;

import 'dart:io';

import 'package:dsanima/state/cover_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

const String _url = 'https://lain.bgm.tv/r/400/pic/cover/l/8a/b2/312427_D2ZNm.jpg';

/// 在缓存目录里造一张"已经下载好"的封面（文件名就是 URL 的 base64url —— 与真实现一致）。
File _cachedCover(Directory dir, String url, {String ext = 'jpg', int bytes = 2048}) {
  final File f = File(p.join(dir.path, '${coverCacheStem(url)}.$ext'))
    ..createSync(recursive: true);
  f.writeAsBytesSync(List<int>.filled(bytes, 0x42));
  return f;
}

void main() {
  late Directory tmp;
  late Directory covers;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dsanima_cover_index_');
    covers = Directory(p.join(tmp.path, 'covers'))..createSync();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  HttpCoverCache cache({
    Duration maxAge = const Duration(days: 7),
    DateTime? now,
    http.Client? client,
  }) =>
      HttpCoverCache(
        cacheDir: covers,
        maxAge: maxAge,
        clock: now == null ? null : () => now,
        // 单测**绝不联网**：默认给一个"什么都 404"的客户端，
        // 于是"盘上没有 ⇒ 返回 null"这条能被确定地测到。
        client: client ?? MockClient((http.Request request) async => http.Response('', 404)),
      );

  test('预热之前 cachedNow 一律 null（不碰磁盘，退化成以前那条异步路）', () {
    _cachedCover(covers, _url);
    final HttpCoverCache c = cache();
    expect(c.cachedNow(_url), isNull, reason: '没预热就什么都不知道 —— 不是错误，是"没有索引"');
    expect(c.indexedCount, 0);
  });

  test('warmUp 之后：cachedNow 当帧给出那个文件（这就是"第一帧直接画"的来源）', () async {
    final File onDisk = _cachedCover(covers, _url);
    final HttpCoverCache c = cache();
    await c.warmUp();

    expect(c.indexedCount, 1);
    expect(c.cachedNow(_url)?.path, onDisk.path);
    // 另一张没缓存过的：不许乱给。
    expect(c.cachedNow('https://lain.bgm.tv/r/400/pic/cover/l/ff/ff/1_x.jpg'), isNull);
    // 不是 URL / 空串：也不许给（否则全站共用一个"命中"）。
    expect(c.cachedNow(''), isNull);
    expect(c.cachedNow('nonsense'), isNull);
  });

  test('没预热也不影响 fileFor：盘上有就照旧命中（同步索引只是加速，不是新依赖）', () async {
    final File onDisk = _cachedCover(covers, _url);
    final HttpCoverCache c = cache();
    final File? got = await c.fileFor(_url);
    expect(got?.path, onDisk.path);
    // 而且这一次探测会顺手把它记进索引 —— 下一次显示（重开页面/滚动回来）就当帧直出。
    expect(c.cachedNow(_url)?.path, onDisk.path);
  });

  test('过期的封面不装进索引（保鲜期与 fileFor 一致）', () async {
    final File old = _cachedCover(covers, _url);
    old.setLastModifiedSync(DateTime(2026, 1, 1));
    final HttpCoverCache c = cache(now: DateTime(2026, 2, 1)); // 31 天 > 7 天
    await c.warmUp();
    expect(c.indexedCount, 0);
    expect(c.cachedNow(_url), isNull, reason: '过期就该走下载那条路（会覆盖它）');
  });

  test('0 字节 / .part / 不认识的扩展名都不算缓存', () async {
    _cachedCover(covers, _url, bytes: 0); // 半个下载
    _cachedCover(covers, 'https://lain.bgm.tv/r/400/pic/cover/l/aa/aa/2_y.jpg', ext: 'part');
    _cachedCover(covers, 'https://lain.bgm.tv/r/400/pic/cover/l/bb/bb/3_z.jpg', ext: 'txt');
    final HttpCoverCache c = cache();
    await c.warmUp();
    expect(c.indexedCount, 0);
    expect(c.cachedNow(_url), isNull);
  });

  test('同一个 URL 盘上有两个扩展名（历史遗留）⇒ 留更新的那一份', () async {
    final File older = _cachedCover(covers, _url, ext: 'webp');
    older.setLastModifiedSync(DateTime(2026, 1, 10));
    final File newer = _cachedCover(covers, _url, ext: 'jpg');
    newer.setLastModifiedSync(DateTime(2026, 1, 20));
    final HttpCoverCache c = cache(now: DateTime(2026, 1, 21));
    await c.warmUp();
    expect(c.indexedCount, 1);
    expect(c.cachedNow(_url)?.path, newer.path);
  });

  test('清过缓存目录之后 invalidate ⇒ 不许再把已删的文件交出去', () async {
    final File onDisk = _cachedCover(covers, _url);
    final HttpCoverCache c = cache();
    await c.warmUp();
    expect(c.cachedNow(_url), isNotNull);

    onDisk.deleteSync(); // 设置页「立即清理」干的就是这个
    c.invalidate();
    expect(c.cachedNow(_url), isNull, reason: '文件没了还说"本地有"，那一格就会变灰框');
    expect(await c.fileFor(_url), isNull,
        reason: '而且重新查也不会硬给（探不到就回 null，交给 UI 降级）');
  });

  test('warmUp 是可重入的：再扫一遍不会把索引搞乱（启动清扫后重热一遍）', () async {
    final File onDisk = _cachedCover(covers, _url);
    final HttpCoverCache c = cache();
    await c.warmUp();
    _cachedCover(covers, 'https://lain.bgm.tv/r/400/pic/cover/l/cc/cc/4_w.jpg');
    await c.warmUp();
    expect(c.indexedCount, 2);
    expect(c.cachedNow(_url)?.path, onDisk.path);
  });
}
