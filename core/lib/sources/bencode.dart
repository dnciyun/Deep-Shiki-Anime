/// BitTorrent `.torrent` 元信息的 bencode 工具（只为算 infohash）。
///
/// 为什么需要它（用户 2026-10-12 第 9 轮：「加入源 https://acg.rip/…」）：
/// **ACG.RIP 全站不提供 magnet** —— 列表页与详情页实测 `magnet:` 出现 **0** 次，
/// 只有一个 `/t/<id>.torrent` 直链；而引擎加种只认 magnet 或 40 位 hex infohash
/// （`AddTorrentRequest.magnet`：`magnet:` 开头或 40 位 hex 二选一）。
///
/// infohash 的定义就是 **`sha1(bencode(info dict))`**，所以这里下载那个 .torrent
/// （实测 20–50 KB），按规范算出 infohash，再交给引擎用 DHT + 会话 tracker 找 peer。
/// 这不是猜：实测互证 —— `https://acg.rip/t/365077.torrent` 算出来
/// `0c6e76513b0f145f17220ee80de45b870d922b15`，与 ACGNX 上**同一条种子**的
/// infohash（RSS 的 magnet 里）逐字一致（见 `test/fixtures/acgrip_365077.torrent`）。
///
/// ## 为什么手写而不用现成包
/// 依赖表里已经有 `crypto`（RSS 的 shortHash 在用），但没有任何 bencode 实现；
/// 这里只需要「找到 `info` 值在原始字节里的**精确区间**」这一件事 —— 注意必须对
/// **原始字节切片**做 sha1，**不能**先解码再重新编码（键序/整数写法一变 hash 就全错）。
///
/// 所有函数**永不抛异常**：不是合法种子、被截断、缺 `info` → 一律返回 null，
/// 调用方据此给用户一句可行动的话（而不是伪造一个 hash）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// `info` 字典在原始字节里的区间（半开区间 `[start, end)`）。
class BencodeRange {
  const BencodeRange(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start;
}

/// 从 `.torrent` 原始字节算 infohash（40 位小写 hex）；任何不合法都返回 null。
String? infoHashFromTorrentBytes(List<int> bytes) {
  final range = infoDictRange(bytes);
  if (range == null) return null;
  final data = _asBytes(bytes);
  return sha1.convert(Uint8List.sublistView(data, range.start, range.end)).toString();
}

/// `info` 字典的字节区间；不是合法 bencode 或缺 `info` 时返回 null。
BencodeRange? infoDictRange(List<int> bytes) {
  final data = _asBytes(bytes);
  final start = _skipLeadingNoise(data);
  if (start >= data.length || data[start] != _dict) return null;
  final info = _dictValue(data, start, 'info');
  return info == null ? null : BencodeRange(info.start, info.end);
}

/// `info.name`（单文件是文件名，多文件是目录名）；缺失或非 UTF-8 时按 latin1 读。
String? torrentNameFromBytes(List<int> bytes) {
  final info = infoDictRange(bytes);
  if (info == null) return null;
  final data = _asBytes(bytes);
  final name = _dictValue(data, info.start, 'name');
  if (name == null) return null;
  final raw = _readBytes(data, name.start);
  if (raw == null) return null;
  try {
    return utf8.decode(raw);
  } catch (_) {
    return latin1.decode(raw, allowInvalid: true);
  }
}

/// 这个种子要下多少字节：`info.length`（单文件）或 `info.files[*].length` 之和。
///
/// 用途：ACG.RIP 列表页给的是站点口径的「225.2 MB」（十进制、已四舍五入），
/// 种子内部才是精确字节数（ACG.RIP 源的 detail 用它覆盖列表页那个近似值）。
/// 算不出来时返回 null —— **不编 0**。
int? torrentTotalBytesFromBytes(List<int> bytes) {
  final info = infoDictRange(bytes);
  if (info == null) return null;
  final data = _asBytes(bytes);

  final single = _dictValue(data, info.start, 'length');
  if (single != null) return _readInt(data, single.start);

  final files = _dictValue(data, info.start, 'files');
  if (files == null || files.start >= data.length || data[files.start] != _list) {
    return null;
  }
  var total = 0;
  var any = false;
  var cursor = files.start + 1;
  while (cursor < data.length && data[cursor] != _end) {
    if (data[cursor] != _dict) return null;
    final length = _dictValue(data, cursor, 'length');
    final value = length == null ? null : _readInt(data, length.start);
    if (value == null) return null; // 有一条读不出长度就整体放弃，不给半份答案
    total += value;
    any = true;
    cursor = _skipValue(data, cursor);
    if (cursor < 0) return null;
  }
  return any ? total : null;
}

// ── bencode 底层 ────────────────────────────────────────────────────────────

const int _dict = 0x64; // d
const int _list = 0x6C; // l
const int _int = 0x69; // i
const int _end = 0x65; // e
const int _colon = 0x3A; // :

Uint8List _asBytes(List<int> bytes) =>
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

/// 容忍开头的 BOM 与空白（真实种子是紧凑 bencode，但有些工具会塞 BOM）。
int _skipLeadingNoise(Uint8List b) {
  var i = 0;
  const Set<int> noise = <int>{0xEF, 0xBB, 0xBF, 0x20, 0x0A, 0x0D, 0x09};
  while (i < b.length && noise.contains(b[i])) {
    i++;
  }
  return i;
}

/// 值区间（`[start, end)`）。
class _Span {
  const _Span(this.start, this.end);

  final int start;
  final int end;
}

/// 在 `start` 处的字典里找键 [key]，返回它**值**的区间；没有则返回 null。
///
/// 只扫一层键，不递归解码值（按 bencode 规则跳过即可）。
_Span? _dictValue(Uint8List b, int start, String key) {
  if (start >= b.length || b[start] != _dict) return null;
  final wanted = ascii.encode(key);
  var cursor = start + 1;
  while (cursor < b.length && b[cursor] != _end) {
    final keyRaw = _readBytes(b, cursor);
    if (keyRaw == null) return null;
    final valueStart = _bytesEnd(b, cursor);
    if (valueStart < 0) return null;
    final valueEnd = _skipValue(b, valueStart);
    if (valueEnd < 0) return null;
    if (_bytesEqual(keyRaw, wanted)) return _Span(valueStart, valueEnd);
    cursor = valueEnd;
  }
  return null;
}

/// 读一个字节串值（`<len>:<bytes>`）；形状不对返回 null。
Uint8List? _readBytes(Uint8List b, int i) {
  final end = _bytesEnd(b, i);
  if (end < 0) return null;
  final colon = _colonIndex(b, i);
  if (colon < 0) return null;
  return Uint8List.sublistView(b, colon + 1, end);
}

/// 字节串值结束后的下标；形状不对返回 -1。
int _bytesEnd(Uint8List b, int i) {
  final colon = _colonIndex(b, i);
  if (colon < 0) return -1;
  final len = int.tryParse(ascii.decode(b.sublist(i, colon)));
  if (len == null || len < 0) return -1;
  final end = colon + 1 + len;
  return end <= b.length ? end : -1;
}

int _colonIndex(Uint8List b, int i) {
  var j = i;
  while (j < b.length && b[j] >= 0x30 && b[j] <= 0x39) {
    j++;
  }
  if (j == i || j >= b.length || b[j] != _colon) return -1;
  return j;
}

/// 读一个整数（`i<digits>e`）；形状不对返回 null。
int? _readInt(Uint8List b, int i) {
  if (i >= b.length || b[i] != _int) return null;
  final end = b.indexOf(_end, i + 1);
  if (end < 0) return null;
  return int.tryParse(ascii.decode(b.sublist(i + 1, end)));
}

/// 跳过 `i` 处的**任意** bencode 值，返回值结束后的下标；不合法返回 -1。
int _skipValue(Uint8List b, int i) {
  if (i < 0 || i >= b.length) return -1;
  final c = b[i];
  if (c == _int) {
    final end = b.indexOf(_end, i + 1);
    return end < 0 ? -1 : end + 1;
  }
  if (c == _dict || c == _list) {
    var depth = 0;
    var cursor = i;
    while (cursor < b.length) {
      final cur = b[cursor];
      if (cur == _dict || cur == _list) {
        depth++;
        cursor++;
        continue;
      }
      if (cur == _end) {
        depth--;
        cursor++;
        if (depth == 0) return cursor;
        continue;
      }
      if (cur == _int) {
        final end = b.indexOf(_end, cursor + 1);
        if (end < 0) return -1;
        cursor = end + 1;
        continue;
      }
      final next = _bytesEnd(b, cursor);
      if (next < 0) return -1;
      cursor = next;
    }
    return -1;
  }
  return _bytesEnd(b, i);
}

bool _bytesEqual(Uint8List a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
