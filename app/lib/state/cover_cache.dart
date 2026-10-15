/// 封面图磁盘缓存（spec §7.5 / §7.6）。
///
/// 为什么需要它：mikan 首页一次就有几十张封面，Bangumi 的封面在 `http://lain.bgm.tv`
/// 上；每次开列表都打图床既慢又容易被限流。这里把图落到
/// `<支持目录>/cache/covers/<key>.<ext>`，命中就直接给本地文件。
///
/// 三条硬要求（都是实测踩过的坑）：
/// 1. **扩展名按响应真实格式判定**：mikan 的 URL 写着 `format=webp`，实测返回的
///    也确实是 WebP（RIFF 头），当 `.jpg` 写会让别的解码器炸；
/// 2. **任何失败都返回 null**：无网络 / 超时 / 403 / 不是图片 → 由 UI 降级成灰框
///    「无封面」，绝不抛异常拖慢列表，更不阻断首启向导；
/// 3. **原子落盘**：先写 `.part` 再 rename，避免中途失败留下半个文件被当成缓存命中。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show immutable;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../domain/mikan_cover.dart' show isLegacySquareMikanCoverUrl;
import '../domain/ports.dart';

/// 与源层一致的 UA（mikan 图床对空 UA 会 403）。
const String coverUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) DSAnima/0.1';

/// 认得的图片扩展名（按响应格式判定后落盘用的）。
const List<String> coverFileExtensions = <String>['webp', 'jpg', 'png', 'gif', 'bmp', 'avif'];

/// 从字节头判断图片格式 → 缓存扩展名；判断不出来返回 null（**不落盘**）。
///
/// 纯函数，单测直接喂真实图片头（含 `RIFF....WEBP`）即可，不联网。
String? imageExtensionOf(List<int> bytes) {
  bool at(List<int> sig, int offset) {
    if (bytes.length < offset + sig.length) return false;
    for (int i = 0; i < sig.length; i++) {
      if (bytes[offset + i] != sig[i]) return false;
    }
    return true;
  }

  // WebP: 'RIFF' .... 'WEBP'（mikan 图床的 `format=webp` 真的走这条）
  if (at(<int>[0x52, 0x49, 0x46, 0x46], 0) && at(<int>[0x57, 0x45, 0x42, 0x50], 8)) {
    return 'webp';
  }
  if (at(<int>[0xFF, 0xD8, 0xFF], 0)) return 'jpg';
  if (at(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], 0)) return 'png';
  if (at(<int>[0x47, 0x49, 0x46, 0x38], 0)) return 'gif';
  if (at(<int>[0x42, 0x4D], 0)) return 'bmp';
  // AVIF/HEIF: 'ftyp' 在偏移 4
  if (at(<int>[0x66, 0x74, 0x79, 0x70], 4)) return 'avif';
  return null;
}

/// URL → 稳定文件名（不含扩展名）。
///
/// 直接用 URL 的 base64url：**不会撞车**（哈希撞车会显示错封面，属于可见错误）。
/// URL 太长（>180 字节，Windows 文件名上限 255）时退回 FNV-1a 折叠。
String coverCacheStem(String url) {
  final String encoded = base64Url.encode(utf8.encode(url)).replaceAll('=', '');
  if (encoded.length <= 180) return encoded;
  int hash = 0x811c9dc5;
  for (final int byte in utf8.encode(url)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return 'fnv${hash.toRadixString(16).padLeft(8, '0')}';
}

/// 封面缓存的落盘目录（**唯一出处**：装配根与设置页都用它，别各写一份路径）。
Directory coverCacheDirOf(Directory supportDir) =>
    Directory(p.join(supportDir.path, 'dsanima', 'cache', 'covers'));

/// 缓存占用（给设置页显示"现在占了多少"）。
@immutable
class CoverCacheUsage {
  const CoverCacheUsage({required this.files, required this.bytes});

  final int files;
  final int bytes;

  static const CoverCacheUsage empty = CoverCacheUsage(files: 0, bytes: 0);
}

/// 一次清理的结果（"释放了多少"必须说得出来，否则用户点了也没底）。
@immutable
class CoverCacheSweep {
  const CoverCacheSweep({required this.deleted, required this.bytes});

  final int deleted;
  final int bytes;

  static const CoverCacheSweep none = CoverCacheSweep(deleted: 0, bytes: 0);
}

/// 数一下缓存目录里现在有多少张、多少字节。
Future<CoverCacheUsage> coverCacheUsage(Directory dir) async {
  if (!await dir.exists()) return CoverCacheUsage.empty;
  int files = 0;
  int bytes = 0;
  try {
    await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      try {
        files++;
        bytes += await entity.length();
      } catch (_) {
        // 单个文件读不到（正被占用/半个写入）就跳过，不影响整体统计。
      }
    }
  } catch (_) {
    return CoverCacheUsage.empty;
  }
  return CoverCacheUsage(files: files, bytes: bytes);
}

/// 清理封面缓存（用户 2026-10-11 第二阶段清单第 7 项）。
///
/// * `maxAge` 给正数：只删**超过这个时长没被碰过**的封面（默认一个月）；
/// * `maxAge == null`（或 [Duration.zero]）：**全清**（给"立即清空"那条路）。
///
/// 为什么需要它：`HttpCoverCache.maxAge`（7 天）只管"缓存过期就重新下载"，
/// **过期文件从来不删** —— 一年下来 `<支持目录>/cache/covers` 会一直涨。
/// 清理是尽力而为：任何单个文件删不掉都跳过，绝不抛异常打断启动/设置页。
Future<CoverCacheSweep> sweepCoverCache(
  Directory dir, {
  Duration? maxAge,
  DateTime Function()? clock,
}) async {
  if (!await dir.exists()) return CoverCacheSweep.none;
  final DateTime now = (clock ?? DateTime.now)();
  int deleted = 0;
  int bytes = 0;
  try {
    await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      try {
        final FileStat stat = await entity.stat();
        if (maxAge != null && maxAge > Duration.zero && now.difference(stat.modified) <= maxAge) {
          continue; // 还新鲜
        }
        bytes += stat.size;
        await entity.delete();
        deleted++;
      } catch (_) {
        // 删不掉就算了（被解码器占着/权限），下次启动再试。
      }
    }
  } catch (_) {
    return CoverCacheSweep(deleted: deleted, bytes: bytes);
  }
  return CoverCacheSweep(deleted: deleted, bytes: bytes);
}

/// 这个缓存文件名是不是**再也不会被请求的旧封面**。
///
/// 缓存文件名是原始 URL 的 base64url（见 [coverCacheStem]），所以能反解回 URL。
/// 三类都算：
/// * `/r/100/pic/cover/…` —— 新接口 `images.grid`（100px，第二十轮换掉）；
/// * `/pic/cover/g/…` —— **旧搜索接口**给的 `images.grid`，实测只有 **48×48**
///   （第二十一轮把这个形状也归一化到 `/r/<档>/pic/cover/l/…`，于是它也成了死重量）；
/// * **带 `height` 的 mikan 封面** —— 第三十一轮起一律去掉 `height`（带它会按正方形裁），
///   所以盘上那些 400×400 的方图再也不会有人请求（用户 2026-10-15：
///   「今日更新的封面图还是显示不全」）。
///
/// 反解不出来（URL 太长走了 FNV 折叠、或不是我们的命名）一律**不动**。
bool isLegacyThumbnailCoverFile(String fileName) {
  String stem = fileName;
  final int dot = stem.indexOf('.');
  if (dot > 0) stem = stem.substring(0, dot);
  if (stem.isEmpty) return false;
  try {
    final String padded = stem.padRight((stem.length + 3) ~/ 4 * 4, '=');
    final String url = utf8.decode(base64Url.decode(padded));
    if (isLegacySquareMikanCoverUrl(url)) return true;
    if (!url.contains('/pic/cover/')) return false;
    return url.contains('/r/100/pic/cover/') || url.contains('/pic/cover/g/');
  } catch (_) {
    return false; // 不是 base64 / 不是 UTF-8：不是我们写的名字
  }
}

/// 清掉盘上遗留的旧小封面（尽力而为，绝不抛）。
///
/// 和 [sweepCoverCache] 一样，返回"删了几张 / 多少字节"，供启动日志说清楚。
/// 与保鲜期无关：这是**一次升级迁移**，用户选没选"定期清理"都该做
/// （那批 `/r/100/` 与 `/pic/cover/g/` 的图再也不会有人请求）。
Future<CoverCacheSweep> sweepLegacyThumbnailCovers(Directory dir) async {
  if (!await dir.exists()) return CoverCacheSweep.none;
  int deleted = 0;
  int bytes = 0;
  try {
    await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      if (!isLegacyThumbnailCoverFile(p.basename(entity.path))) continue;
      try {
        bytes += await entity.length();
        await entity.delete();
        deleted++;
      } catch (_) {
        // 删不掉（正被解码器占着）就下次启动再试。
      }
    }
  } catch (_) {
    // 目录读不动：当作没做。
  }
  return CoverCacheSweep(deleted: deleted, bytes: bytes);
}

/// `http` 实现：命中读本地，未命中下载并落盘。
class HttpCoverCache implements CoverCachePort {
  HttpCoverCache({
    required this.cacheDir,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
    this.maxAge = const Duration(days: 7),
    DateTime Function()? clock,
  }) : _client = client ?? http.Client(),
       _clock = clock ?? DateTime.now;

  /// 落盘目录（`<支持目录>/cache/covers`）。
  final Directory cacheDir;
  final Duration timeout;

  /// 封面文件的最长保鲜期（spec §7.7：7 天）；超过就重新下载。
  final Duration maxAge;
  final http.Client _client;
  final DateTime Function() _clock;

  /// 同一 URL 并发请求只下一次（一屏几十张卡会同时触发）。
  final Map<String, Future<File?>> _inflight = <String, Future<File?>>{};

  /// **内存索引**：URL 的缓存名 → 盘上那个文件 + 它的修改时间（第三十七轮）。
  ///
  /// 为什么要有它（用户 2026-10-16：「动漫库的封面图保存缓存，不然每次都要加载」）：
  /// 封面**本来就是落盘缓存**的（本机实测盘上 167 张 / 8.6 MB，都在），但每次显示一张
  /// 都得过一次 `await`：`fileFor` → `_existing` → 最多 6 次 `File.exists()` 探扩展名 →
  /// 才把 `File` 交给 `Image.file`。于是**每一张卡、每一次进页面、每一次滚动回来看**
  /// 都会先空一帧灰底再"啪"地出现 —— 看上去就是"又要加载一次"。
  /// 有了这个索引，[cachedNow] 能在**同一帧内**把 File 交出去（`Image.file` 此时还能命中
  /// Flutter 自己的解码缓存，于是连解码都不用等），界面不再闪。
  ///
  /// 索引**只信自己扫到的东西**：启动时 [warmUp] 扫一遍目录，之后每次命中/下载都补进去；
  /// 清缓存（设置页「立即清理」/ 启动清扫）之后调 [invalidate] 清空，免得把已删的文件
  /// 交出去。
  final Map<String, _IndexedCover> _index = <String, _IndexedCover>{};

  /// 数一下索引里现在有多少张（探针 / 日志用）。
  int get indexedCount => _index.length;

  /// 扫一遍缓存目录，把**新鲜**的封面装进内存索引。
  ///
  /// 启动后调一次即可（167 张的 `stat`，几毫秒）；失败了就当没预热
  /// （[cachedNow] 一直返回 null，退化成以前那条异步路，功能不受影响）。
  Future<void> warmUp() async {
    if (!await cacheDir.exists()) return;
    int added = 0;
    try {
      await for (final FileSystemEntity entity in cacheDir.list(followLinks: false)) {
        if (entity is! File) continue;
        final String name = p.basename(entity.path);
        if (name.endsWith('.part')) continue; // 半个文件不是缓存（同 sweep 的规矩）
        final int dot = name.indexOf('.');
        if (dot <= 0) continue;
        final String stem = name.substring(0, dot);
        final String ext = name.substring(dot + 1);
        if (!coverFileExtensions.contains(ext)) continue;
        try {
          final FileStat stat = await entity.stat();
          if (stat.size == 0) continue;
          if (_clock().difference(stat.modified) > maxAge) continue; // 过期的不装
          final _IndexedCover? old = _index[stem];
          // 同一个 URL 盘上有多个扩展名（历史上的格式变化）时留**更新的**那一份。
          if (old == null || stat.modified.isAfter(old.modified)) {
            _index[stem] = _IndexedCover(entity, stat.modified);
            added++;
          }
        } catch (_) {
          // 单个文件读不到（正被占用）就跳过，不影响其它封面。
        }
      }
    } catch (_) {
      // 目录读不动：当作没预热（走异步路）。
    }
    if (added > 0) _warmCount = added;
  }

  int _warmCount = 0;

  /// 上一次 [warmUp] 装进来多少张（日志里说清楚"预热有没有用"）。
  int get warmedCount => _warmCount;

  /// 丢掉内存索引（清过缓存目录之后必须调，否则会把已删的文件交出去）。
  void invalidate() {
    _index.clear();
    _warmCount = 0;
  }

  @override
  File? cachedNow(String url) {
    final _IndexedCover? hit = _index[_stemOf(url)];
    if (hit == null) return null;
    // 保鲜期与 [fileFor] 一致：过期的不给，让它走下载那条路（会覆盖它）。
    if (_clock().difference(hit.modified) > maxAge) return null;
    return hit.file;
  }

  /// URL → 缓存名（与 [fileFor] 完全同一条算法：trim → 必须是带 scheme 的 URI）。
  String _stemOf(String url) {
    final String trimmed = url.trim();
    if (trimmed.isEmpty) return '';
    final Uri? uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme) return '';
    return coverCacheStem(trimmed);
  }

  /// 索引里那条（过期的不算）。
  File? _fromIndex(String stem) {
    final _IndexedCover? hit = _index[stem];
    if (hit == null) return null;
    if (_clock().difference(hit.modified) > maxAge) return null;
    return hit.file;
  }

  @override
  Future<File?> fileFor(String url, {String? referer}) {
    final String trimmed = url.trim();
    if (trimmed.isEmpty) return Future<File?>.value();
    final Uri? uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme) return Future<File?>.value();

    final String stem = coverCacheStem(trimmed);
    return _inflight.putIfAbsent(
      '$stem|${referer ?? ''}',
      () => _load(uri, stem, referer).whenComplete(() {
        // 失败不缓存，下次还能重试。
      }),
    );
  }

  Future<File?> _load(Uri uri, String stem, String? referer) async {
    final File? cached = await _existing(stem);
    if (cached != null) return cached;
    try {
      final http.Response res = await _client
          .get(
            uri,
            headers: <String, String>{
              'User-Agent': coverUserAgent,
              if (referer != null && referer.isNotEmpty) 'Referer': referer,
            },
          )
          .timeout(timeout);
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      final String? ext = imageExtensionOf(res.bodyBytes);
      if (ext == null) return null; // 不是图片（错误页/HTML）→ 不污染缓存
      await cacheDir.create(recursive: true);
      final File part = File(p.join(cacheDir.path, '$stem.$ext.part'));
      await part.writeAsBytes(res.bodyBytes, flush: true);
      final File out = File(p.join(cacheDir.path, '$stem.$ext'));
      if (await out.exists()) await out.delete();
      await part.rename(out.path);
      // 落盘成功就补进内存索引：这一次之后的显示（换页、滚动回来、重开页面）
      // 都能当帧拿到它，不必再等一次磁盘探测。
      _index[stem] = _IndexedCover(out, _clock());
      return out;
    } catch (_) {
      // 超时 / DNS 失败 / 磁盘满：一律降级（封面不是功能主路径）。
      return null;
    } finally {
      _inflight.remove('$stem|${referer ?? ''}');
    }
  }

  Future<File?> _existing(String stem) async {
    // ① 内存索引（同步、零 IO）——这条是常态。
    final File? indexed = _fromIndex(stem);
    if (indexed != null) return indexed;
    // ② 索引里没有（刚启动还没预热 / 是别的进程写的）：按扩展名挨个探一次磁盘。
    for (final String ext in coverFileExtensions) {
      final File file = File(p.join(cacheDir.path, '$stem.$ext'));
      try {
        if (!await file.exists() || await file.length() == 0) continue;
        // 超过保鲜期按 miss 处理（下次下载会覆盖它）。
        final DateTime modified = await file.lastModified();
        if (_clock().difference(modified) > maxAge) continue;
        _index[stem] = _IndexedCover(file, modified); // 探到了就记住，下次不用再探
        return file;
      } catch (_) {
        // 单个扩展名查不到就算了。
      }
    }
    return null;
  }

  void dispose() => _client.close();
}

/// 内存索引里的一条：盘上的文件 + 它的修改时间（保鲜期判据）。
class _IndexedCover {
  const _IndexedCover(this.file, this.modified);

  final File file;
  final DateTime modified;
}
