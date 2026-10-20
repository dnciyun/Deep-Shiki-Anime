/// `.torrent` 文件的本地预览：拖进来之后**先看清楚再决定下不下**。
///
/// 为什么自己在本地解析（不交给引擎）：用户 2026-10-20 的要求是「拖入种子，显示要
/// 下载的东西与内容参数，然后选择是否下载」。要"先看再决定"就不能先 `addMagnet`
/// —— 那等于已经开始下载了。bencode 很小（这里 ~200 行纯函数），解析出来就能列出
/// 文件名/大小/tracker/infoHash，用户勾完再入队。
///
/// 也不依赖 `bencode` 包：只需要读「名字 / 文件清单 / tracker / info 原始字节」，
/// 自己写反而能顺手拿到 **info 字典的原始字节区间** —— infoHash 是它整体做 sha1，
/// 少了这一步就没法生成磁力链索引。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter/foundation.dart';

import 'local_media.dart' show kLocalSubtitleExtensions, kLocalVideoExtensions;
import 'models.dart' show SourceItemView;

/// 认的种子文件最大字节数（超过就不读：正常的 `.torrent` 撑死几 MB）。
const int kMaxTorrentFileBytes = 20 * 1024 * 1024;

/// 种子里一个文件属于哪一类（只用来决定**默认勾不勾**）。
enum TorrentEntryKind { video, subtitle, other }

/// 种子里的一条文件。
@immutable
class TorrentFileEntryView {
  const TorrentFileEntryView({
    required this.index,
    required this.path,
    required this.sizeBytes,
    required this.kind,
  });

  /// 在 `.torrent` 的 `files` 数组里的序号（引擎的 `onlyFiles` 就吃这个）。
  final int index;

  /// 相对路径（多文件种子形如 `Show/01.mkv`；单文件种子 = 名字）。
  final String path;
  final int sizeBytes;
  final TorrentEntryKind kind;

  String get fileName {
    final int at = path.lastIndexOf('/');
    return at < 0 ? path : path.substring(at + 1);
  }

  @override
  String toString() => 'TorrentFileEntryView($index, $path, $sizeBytes)';
}

/// 一份 `.torrent` 的本地预览。
@immutable
class TorrentPreview {
  const TorrentPreview({
    required this.name,
    required this.files,
    required this.trackers,
    required this.infoHashHex,
    this.comment,
    this.createdBy,
  });

  /// `info.name`（种子里的名字，多文件种子就是顶层文件夹名）。
  final String name;

  final List<TorrentFileEntryView> files;

  /// `announce` + `announce-list` 去重后的 tracker（只留 http/https/udp）。
  final List<String> trackers;

  /// info 字典原始字节的 sha1（40 位小写 hex）。
  final String infoHashHex;

  final String? comment;
  final String? createdBy;

  int get totalBytes => files.fold<int>(0, (int sum, TorrentFileEntryView f) => sum + f.sizeBytes);

  int get videoCount =>
      files.where((TorrentFileEntryView f) => f.kind == TorrentEntryKind.video).length;

  bool get isSingleFile => files.length == 1;

  /// 默认勾选：**视频 + 字幕**（nfo / 图片 / 样片默认不勾 —— 用户要的是片子）。
  ///
  /// 一个视频都没认出来时退回"全选"：那多半是命名特殊，硬猜不如让用户自己看着办。
  Set<int> get defaultSelection {
    final Set<int> picked = <int>{
      for (final TorrentFileEntryView f in files)
        if (f.kind != TorrentEntryKind.other) f.index,
    };
    return picked.isEmpty ? <int>{for (final TorrentFileEntryView f in files) f.index} : picked;
  }

  /// 选中这些序号一共要下多少字节。
  int bytesOf(Iterable<int> selected) {
    final Set<int> want = selected.toSet();
    return files
        .where((TorrentFileEntryView f) => want.contains(f.index))
        .fold<int>(0, (int sum, TorrentFileEntryView f) => sum + f.sizeBytes);
  }

  /// 由 infoHash + 名字 + tracker 拼出来的磁力链（入队/下载用）。
  String get magnet {
    final List<String> parts = <String>[
      'magnet:?xt=urn:btih:$infoHashHex',
      'dn=${Uri.encodeComponent(name)}',
    ];
    for (final String tracker in trackers) {
      parts.add('tr=${Uri.encodeComponent(tracker)}');
    }
    return parts.join('&');
  }
}

/// 预览 → 入队用的条目。
///
/// `sourceId = 'dropped'`：它不是任何一个源（mikan/nyaa…）的条目，但队列/播放只认
/// `magnet` + `infoHash`，所以拖进来的种子与搜索来的条目走同一条下载链路。
/// `id` 用 infoHash 派生：同一个种子拖两次 = 同一条（队列里不会出现两份）。
SourceItemView torrentPreviewSourceItem(TorrentPreview preview) => SourceItemView(
  id: 'dropped:${preview.infoHashHex}',
  sourceId: 'dropped',
  title: preview.name,
  magnet: preview.magnet,
  infoHash: preview.infoHashHex,
  sizeBytes: preview.totalBytes,
  extra: const <String, Object?>{'dropped': true},
);

/// 读一份 `.torrent` 的预览。**解析不了返回 null**（调用方给用户可读的提示），
/// 绝不抛异常给 UI。
TorrentPreview? readTorrentPreview(List<int> bytes) {
  if (bytes.isEmpty || bytes.length > kMaxTorrentFileBytes) return null;
  final Uint8List data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final _Val root;
  try {
    final _Reader reader = _Reader(data);
    root = reader.read();
    if (reader.i != data.length) return null; // 尾巴还有垃圾 → 不是合法种子
  } on FormatException {
    return null;
  }
  final Object? top = root.value;
  if (top is! Map<String, _Val>) return null;
  final _Val? info = top['info']?.value is Map<String, _Val> ? top['info'] : null;
  if (info == null) return null;
  final Map<String, _Val> infoDict = info.value! as Map<String, _Val>;

  final String name =
      _text(infoDict['name.utf-8']) ?? _text(infoDict['name']) ?? '未命名种子';

  final List<TorrentFileEntryView> files = <TorrentFileEntryView>[];
  final List<_Val>? rawFiles = infoDict['files']?.value as List<_Val>?;
  if (rawFiles == null) {
    // 单文件种子：只有 info.length。
    final int? length = _int(infoDict['length']);
    if (length == null) return null;
    files.add(
      TorrentFileEntryView(index: 0, path: name, sizeBytes: length, kind: _kindOf(name)),
    );
  } else {
    for (int index = 0; index < rawFiles.length; index++) {
      final Object? raw = rawFiles[index].value;
      if (raw is! Map<String, _Val>) continue;
      final int size = _int(raw['length']) ?? 0;
      final List<String> parts =
          _textList(raw['path.utf-8']) ?? _textList(raw['path']) ?? const <String>[];
      final String path = parts.isEmpty ? '$name/$index' : parts.join('/');
      files.add(
        TorrentFileEntryView(
          index: index,
          path: path,
          sizeBytes: size,
          kind: _kindOf(path),
        ),
      );
    }
    if (files.isEmpty) return null;
  }

  return TorrentPreview(
    name: name,
    files: List<TorrentFileEntryView>.unmodifiable(files),
    trackers: _trackersOf(top),
    infoHashHex: sha1.convert(data.sublist(info.start, info.end)).toString(),
    comment: _text(top['comment']) ?? _text(top['comment.utf-8']),
    createdBy: _text(top['created by']),
  );
}

TorrentEntryKind _kindOf(String path) {
  final int dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return TorrentEntryKind.other;
  final String ext = path.substring(dot + 1).toLowerCase();
  if (kLocalVideoExtensions.contains(ext)) return TorrentEntryKind.video;
  if (kLocalSubtitleExtensions.contains(ext)) return TorrentEntryKind.subtitle;
  return TorrentEntryKind.other;
}

List<String> _trackersOf(Map<String, _Val> top) {
  final Set<String> out = <String>{};
  void add(Object? raw) {
    if (raw is! String) return;
    final String t = raw.trim();
    final String lower = t.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://') && !lower.startsWith('udp://')) {
      return;
    }
    out.add(t);
  }

  add(_text(top['announce']));
  final Object? announceList = top['announce-list']?.value;
  if (announceList is List<_Val>) {
    for (final _Val tier in announceList) {
      final Object? value = tier.value;
      if (value is List<_Val>) {
        for (final _Val item in value) {
          add(_text(item));
        }
      } else {
        add(_text(tier));
      }
    }
  }
  return List<String>.unmodifiable(out);
}

String? _text(_Val? val) {
  final Object? value = val?.value;
  if (value is! Uint8List) return null;
  final String text = utf8.decode(value, allowMalformed: true).trim();
  return text.isEmpty ? null : text;
}

int? _int(_Val? val) {
  final Object? value = val?.value;
  return value is int ? value : null;
}

List<String>? _textList(_Val? val) {
  final Object? value = val?.value;
  if (value is! List<_Val>) return null;
  final List<String> out = <String>[];
  for (final _Val item in value) {
    final String? text = _text(item);
    if (text != null) out.add(text);
  }
  return out.isEmpty ? null : out;
}

// ─────────────────────────────────────────────────────────────────────────────
// bencode
// ─────────────────────────────────────────────────────────────────────────────

/// 一个解析出来的值 + 它在原始字节里的区间（`info` 的区间用来算 infoHash）。
class _Val {
  _Val(this.value, this.start, this.end);

  /// `int` | `Uint8List` | `List<_Val>` | `Map<String, _Val>`
  final Object? value;
  final int start;
  final int end;
}

class _Reader {
  _Reader(this.bytes);

  final Uint8List bytes;
  int i = 0;

  Never _fail(String message) => throw FormatException('bencode: $message @$i');

  _Val read() {
    if (i >= bytes.length) _fail('越界');
    final int c = bytes[i];
    if (c == 0x69) return _readInt(); // 'i'
    if (c == 0x6C) return _readList(); // 'l'
    if (c == 0x64) return _readDict(); // 'd'
    if (c >= 0x30 && c <= 0x39) return _readBytes(); // '0'–'9'
    _fail('未知前缀 ${String.fromCharCode(c)}');
  }

  _Val _readInt() {
    final int start = i;
    i++; // 'i'
    final int begin = i;
    while (i < bytes.length && bytes[i] != 0x65) {
      i++;
    }
    if (i >= bytes.length) _fail('整数没有结尾 e');
    final String text = ascii.decode(bytes.sublist(begin, i));
    i++; // 'e'
    final int? value = int.tryParse(text);
    if (value == null) _fail('整数内容非法：$text');
    return _Val(value, start, i);
  }

  _Val _readBytes() {
    final int start = i;
    final int begin = i;
    while (i < bytes.length && bytes[i] != 0x3A) {
      // ':'
      if (bytes[i] < 0x30 || bytes[i] > 0x39) _fail('字节串长度非法');
      i++;
    }
    if (i >= bytes.length) _fail('字节串缺冒号');
    final int length = int.parse(ascii.decode(bytes.sublist(begin, i)));
    i++; // ':'
    if (length < 0 || i + length > bytes.length) _fail('字节串越界');
    final Uint8List value = Uint8List.sublistView(bytes, i, i + length);
    i += length;
    return _Val(value, start, i);
  }

  _Val _readList() {
    final int start = i;
    i++; // 'l'
    final List<_Val> items = <_Val>[];
    while (true) {
      if (i >= bytes.length) _fail('列表没有结尾 e');
      if (bytes[i] == 0x65) {
        i++; // 'e'
        return _Val(items, start, i);
      }
      items.add(read());
    }
  }

  _Val _readDict() {
    final int start = i;
    i++; // 'd'
    final Map<String, _Val> items = <String, _Val>{};
    while (true) {
      if (i >= bytes.length) _fail('字典没有结尾 e');
      if (bytes[i] == 0x65) {
        i++; // 'e'
        return _Val(items, start, i);
      }
      final _Val key = _readBytes();
      final Object? rawKey = key.value;
      if (rawKey is! Uint8List) _fail('字典的键必须是字节串');
      final String name = utf8.decode(rawKey, allowMalformed: true);
      items[name] = read();
    }
  }
}
