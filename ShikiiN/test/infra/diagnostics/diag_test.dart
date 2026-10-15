import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shikiin/infra/diagnostics/diag.dart';

void main() {
  late Directory tmp;
  DateTime fixed = DateTime(2026, 6, 22, 9, 8, 7);
  final List<Diag> opened = [];
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('shikiin_diag_');
    opened.clear();
  });
  tearDown(() async {
    for (final d in opened) {
      await d.close(); // release the file handle so Windows lets us delete
    }
    tmp.deleteSync(recursive: true);
  });

  Diag newDiag() {
    final d = Diag(clock: () => fixed);
    opened.add(d);
    return d;
  }

  String readLog(Diag d) => (d.currentFile!).readAsStringSync();

  test('open() creates a session file named by the clock under logs/', () async {
    final d = newDiag();
    await d.open(tmp);
    expect(d.currentFile, isNotNull);
    expect(p.basename(d.currentFile!.path), 'shikiin-20260622-090807.log');
    expect(File(d.currentFile!.path).existsSync(), isTrue);
    await d.flush();
  });

  test('error/warn/info write the documented line format', () async {
    final d = newDiag();
    await d.open(tmp);
    d.info('player', 'opened file');
    d.warn('mpv', 'vo glitch');
    await d.flush();
    final text = readLog(d);
    expect(text, contains('2026-06-22T09:08:07.000 INFO player opened file'));
    expect(text, contains('2026-06-22T09:08:07.000 WARN mpv vo glitch'));
  });

  test('error appends error + stack on following lines', () async {
    final d = newDiag();
    await d.open(tmp);
    d.error('zone', 'boom', StateError('bad'), StackTrace.fromString('FRAME0'));
    await d.flush();
    final text = readLog(d);
    expect(text, contains('ERROR zone boom'));
    expect(text, contains('Bad state: bad'));
    expect(text, contains('FRAME0'));
  });

  test('lines logged before open() are buffered then flushed on open()', () async {
    final d = newDiag();
    d.warn('player', 'early warning'); // before open
    await d.open(tmp);
    await d.flush();
    expect(readLog(d), contains('early warning'));
  });

  test('a never-opened Diag is a safe no-op (no file, never throws)', () {
    final d = newDiag();
    expect(d.currentFile, isNull);
    expect(() {
      d.info('player', 'x');
      d.warn('player', 'y');
      d.error('player', 'z', Exception('e'), StackTrace.current);
    }, returnsNormally);
  });

  test('breadcrumb ring buffer keeps only the most recent maxBreadcrumbs', () async {
    final d = newDiag();
    await d.open(tmp);
    for (var i = 0; i < Diag.maxBreadcrumbs + 50; i++) {
      d.breadcrumb('evt$i');
    }
    expect(d.breadcrumbs.length, Diag.maxBreadcrumbs);
    expect(d.breadcrumbs.first, contains('evt50')); // oldest 50 dropped
    expect(d.breadcrumbs.last, contains('evt${Diag.maxBreadcrumbs + 49}'));
  });

  test('error dumps the current breadcrumbs after the error block', () async {
    final d = newDiag();
    await d.open(tmp);
    d.breadcrumb('open: a.mkv');
    d.breadcrumb('seek: 00:30');
    d.error('player', 'native fault');
    await d.flush();
    final text = readLog(d);
    expect(text, contains('--- breadcrumbs'));
    expect(text, contains('open: a.mkv'));
    expect(text, contains('seek: 00:30'));
  });

  test('breadcrumbFlushed records and flushes', () async {
    final d = newDiag();
    await d.open(tmp);
    await d.breadcrumbFlushed('slice: b.mkv');
    expect(readLog(d), contains('slice: b.mkv')); // already on disk, no extra flush
    expect(d.breadcrumbs.last, contains('slice: b.mkv'));
  });

  test('open() prunes old sessions, keeping at most maxSessions', () async {
    final logs = Directory(p.join(tmp.path, 'logs'))..createSync(recursive: true);
    // Pre-seed 12 old session files with sortable timestamps.
    for (var i = 0; i < 12; i++) {
      File(
        p.join(logs.path, 'shikiin-202606${(10 + i).toString()}-000000.log'),
      ).writeAsStringSync('old');
    }
    final d = Diag(clock: () => DateTime(2026, 7, 1, 0, 0, 0));
    opened.add(d);
    await d.open(tmp);
    await d.flush();
    final remaining = logs
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.log'))
        .length;
    expect(remaining, Diag.maxSessions); // 10 (9 kept + new file)
  });

  test('open() 还会按体积清理：总量压到 maxTotalBytes 以下（旧的先删）', () async {
    final logs = Directory(p.join(tmp.path, 'logs'))..createSync(recursive: true);
    // 5 份「大体量」旧日志：每份 8MB（maxTotalBytes = 20MB）⇒ 只能留 2 份。
    const int chunk = 8 * 1024 * 1024;
    final List<String> names = <String>[];
    for (var i = 0; i < 5; i++) {
      final name = 'shikiin-202606${(10 + i).toString()}-000000.log';
      names.add(name);
      File(p.join(logs.path, name)).writeAsBytesSync(List<int>.filled(chunk, 0x41));
    }
    final d = Diag(clock: () => DateTime(2026, 7, 1, 0, 0, 0));
    opened.add(d);
    await d.open(tmp);
    await d.flush();

    final List<File> left = logs
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.log'))
        .toList();
    final int bytes = left.fold<int>(0, (int sum, File f) => sum + f.lengthSync());
    expect(bytes, lessThanOrEqualTo(Diag.maxTotalBytes), reason: '条数达标不等于体积达标：长会话的日志能把 20MB 撑爆');
    // 新的先留、旧的先删（新会话文件 + 最新那两份大文件）。
    expect(left.map((File f) => p.basename(f.path)), contains(names.last));
    expect(left.length, lessThan(5));
  });
}
