/// `.torrent` 本地预览（bencode 解析）的测试。
///
/// 拖入种子后用户要先看清"要下什么、多大"，再决定下不下 —— 这份预览就是那个依据，
/// 所以它必须**对得上**（名字/文件/大小/infoHash），而且**永不把坏种子解析成半成品**。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' show sha1;
import 'package:dsanima/domain/torrent_file.dart';
import 'package:flutter_test/flutter_test.dart';

// ── bencode 夹具（测试自己造种子字节，不碰磁盘、不联网）─────────────────────────

List<int> _bc(Object? value) {
  if (value is int) return utf8.encode('i${value}e');
  if (value is String) {
    final List<int> bytes = utf8.encode(value);
    return <int>[...utf8.encode('${bytes.length}:'), ...bytes];
  }
  if (value is List) {
    return <int>[0x6C, for (final Object? v in value) ..._bc(v), 0x65]; // l…e
  }
  if (value is Map) {
    final List<String> keys = value.keys.map((Object? k) => k.toString()).toList()..sort();
    return <int>[
      0x64, // d
      for (final String k in keys) ...<int>[..._bc(k), ..._bc(value[k])],
      0x65, // e
    ];
  }
  throw ArgumentError('不支持的 bencode 值：$value');
}

/// 拼一份 `.torrent` 字节（info 单独编码一次，好让测试自己也能算 infoHash）。
List<int> _torrent({
  Object? info,
  String? announce,
  List<List<String>> announceList = const <List<String>>[],
  String? comment,
}) {
  final List<int> infoBytes = _bc(info);
  final List<int> out = <int>[0x64, ...utf8.encode('4:info'), ...infoBytes]; // d4:info…
  if (announce != null) {
    out.addAll(_bc('announce'));
    out.addAll(_bc(announce));
  }
  if (announceList.isNotEmpty) {
    out.addAll(_bc('announce-list'));
    out.addAll(_bc(announceList));
  }
  if (comment != null) {
    out.addAll(_bc('comment'));
    out.addAll(_bc(comment));
  }
  out.add(0x65); // e
  return out;
}

Map<String, Object?> _multiFileInfo({
  String name = 'Show',
  List<List<Object?>> files = const <List<Object?>>[
    <Object?>[1000, <String>['01.mkv']],
    <Object?>[10, <String>['01.ass']],
    <Object?>[5, <String>['info.nfo']],
  ],
}) => <String, Object?>{
  'name': name,
  'piece length': 262144,
  'pieces': 'x' * 20,
  'files': <Map<String, Object?>>[
    for (final List<Object?> f in files)
      <String, Object?>{'length': f[0], 'path': f[1]},
  ],
};

void main() {
  test('多文件种子：名字 / 文件清单 / 大小 / 类型 / 默认勾选', () {
    final List<int> bytes = _torrent(
      info: _multiFileInfo(),
      announce: 'http://tracker.example/announce',
      announceList: <List<String>>[
        <String>['http://tracker.example/announce', 'udp://t2.example:6969/announce'],
        <String>['https://t3.example/announce'],
      ],
      comment: '2026 秋',
    );
    final TorrentPreview? preview = readTorrentPreview(bytes);
    expect(preview, isNotNull);
    expect(preview!.name, 'Show');
    expect(preview.files.map((TorrentFileEntryView f) => f.path), <String>[
      '01.mkv',
      '01.ass',
      'info.nfo',
    ]);
    expect(preview.files.map((TorrentFileEntryView f) => f.index), <int>[0, 1, 2]);
    expect(preview.files.map((TorrentFileEntryView f) => f.kind), <TorrentEntryKind>[
      TorrentEntryKind.video,
      TorrentEntryKind.subtitle,
      TorrentEntryKind.other,
    ]);
    expect(preview.totalBytes, 1015);
    expect(preview.videoCount, 1);
    expect(preview.isSingleFile, isFalse);
    // 默认只勾视频 + 字幕（nfo/图片默认不下）。
    expect(preview.defaultSelection, <int>{0, 1});
    expect(preview.bytesOf(preview.defaultSelection), 1010);
    expect(preview.comment, '2026 秋');
    // tracker 去重 + 只留认得的协议。
    expect(preview.trackers, <String>[
      'http://tracker.example/announce',
      'udp://t2.example:6969/announce',
      'https://t3.example/announce',
    ]);
  });

  test('infoHash = info 字典原始字节的 sha1（磁力链也用它）', () {
    final Object info = _multiFileInfo();
    final List<int> bytes = _torrent(info: info, announce: 'udp://t.example:80/announce');
    final TorrentPreview preview = readTorrentPreview(bytes)!;
    final String expected = sha1.convert(_bc(info)).toString();
    expect(preview.infoHashHex, expected);
    expect(preview.magnet, contains('xt=urn:btih:$expected'));
    expect(preview.magnet, contains('dn=Show'));
    expect(preview.magnet, contains('tr=udp%3A%2F%2Ft.example%3A80%2Fannounce'));
  });

  test('单文件种子：没有 files 数组，只有 info.length', () {
    final TorrentPreview? preview = readTorrentPreview(
      _torrent(
        info: <String, Object?>{
          'name': 'Movie [1080p].mkv',
          'length': 4242,
          'piece length': 262144,
          'pieces': 'y' * 20,
        },
      ),
    );
    expect(preview, isNotNull);
    expect(preview!.isSingleFile, isTrue);
    expect(preview.files.single.path, 'Movie [1080p].mkv');
    expect(preview.files.single.sizeBytes, 4242);
    expect(preview.files.single.kind, TorrentEntryKind.video);
    expect(preview.defaultSelection, <int>{0});
    expect(preview.trackers, isEmpty);
  });

  test('中文名：优先 name.utf-8 / path.utf-8', () {
    final TorrentPreview? preview = readTorrentPreview(
      _torrent(
        info: <String, Object?>{
          'name': 'fallback',
          'name.utf-8': '转生重骑士',
          'piece length': 262144,
          'pieces': 'z' * 20,
          'files': <Map<String, Object?>>[
            <String, Object?>{'length': 10, 'path': <String>['a.mkv'], 'path.utf-8': <String>['第01话.mkv']},
          ],
        },
      ),
    );
    expect(preview!.name, '转生重骑士');
    expect(preview.files.single.path, '第01话.mkv');
  });

  test('一个视频都没认出来时默认全选（不硬猜）', () {
    final TorrentPreview preview = readTorrentPreview(
      _torrent(
        info: _multiFileInfo(
          files: const <List<Object?>>[
            <Object?>[1, <String>['a.bin']],
            <Object?>[2, <String>['b.dat']],
          ],
        ),
      ),
    )!;
    expect(preview.defaultSelection, <int>{0, 1});
  });

  test('坏数据一律返回 null（不抛、不造半成品）', () {
    expect(readTorrentPreview(const <int>[]), isNull);
    expect(readTorrentPreview(utf8.encode('not a torrent')), isNull);
    // 合法 bencode 但没有 info。
    expect(readTorrentPreview(_bc(<String, Object?>{'announce': 'http://x/a'})), isNull);
    // info 里既没 files 也没 length。
    expect(
      readTorrentPreview(_torrent(info: <String, Object?>{'name': 'x'})),
      isNull,
    );
    // 截断。
    final List<int> full = _torrent(info: _multiFileInfo());
    expect(readTorrentPreview(full.sublist(0, full.length - 4)), isNull);
    // 尾巴有垃圾。
    expect(readTorrentPreview(<int>[...full, 0x41]), isNull);
  });

  test('种子文件太大直接不读（上限保护）', () {
    expect(
      readTorrentPreview(List<int>.filled(kMaxTorrentFileBytes + 1, 0x64)),
      isNull,
    );
  });
}
