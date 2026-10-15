import 'dart:io';
import 'package:path/path.dart' as p;

/// Disk logger for ShikiiN. One session file per app launch. Never throws:
/// every write is guarded; a failed [open] degrades to an in-memory no-op so
/// the logger can never become a new crash source (spec §4.3).
class Diag {
  Diag({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  IOSink? _sink;
  File? _file;
  final List<String> _pending = <String>[]; // lines logged before open()
  static const int _maxPending = 500;

  static const int maxBreadcrumbs = 200;

  /// 保留的会话日志份数（用户 2026-10-11：保留最近 10 个）。
  static const int maxSessions = 10;

  /// `logs/` 里全部会话日志的**总量上限**（用户 2026-10-11：最多 20MB）。
  static const int maxTotalBytes = 20 * 1024 * 1024;

  final List<String> _breadcrumbs = <String>[];

  /// Snapshot of the breadcrumb ring buffer (for tests / inspection).
  List<String> get breadcrumbs => List.unmodifiable(_breadcrumbs);

  /// Record a short event in the in-memory ring buffer (dumped on the next error).
  void breadcrumb(String event) {
    final line = '${_clock().toIso8601String()} $event';
    _breadcrumbs.add(line);
    if (_breadcrumbs.length > maxBreadcrumbs) _breadcrumbs.removeAt(0);
  }

  /// Record a breadcrumb and force it to disk now (use before high-risk native
  /// ops — slice / aspect change / super-res / heavy thumbnail use).
  Future<void> breadcrumbFlushed(String event) async {
    breadcrumb(event);
    _write('BREADCRUMB', 'app', event, null, null);
    await flush();
  }

  /// The current session log file (null before [open] or after a failed open).
  File? get currentFile => _file;

  /// Open (or re-open) the session log. [supportDir] is the application support
  /// directory; logs live under `<supportDir>/logs/`. Safe to call once.
  Future<void> open(Directory supportDir) async {
    try {
      final logsDir = Directory(p.join(supportDir.path, 'logs'));
      logsDir.createSync(recursive: true);
      _prune(logsDir);
      final name = 'shikiin-${_stamp(_clock())}.log';
      _file = File(p.join(logsDir.path, name));
      _file!.createSync(); // materialize now (openWrite is lazy until first write)
      _sink = _file!.openWrite(mode: FileMode.writeOnlyAppend);
      for (final line in _pending) {
        _sink!.writeln(line);
      }
      _pending.clear();
    } catch (_) {
      _sink = null;
      _file = null; // degrade to no-op
    }
  }

  void error(String source, String msg, [Object? e, StackTrace? st]) =>
      _write('ERROR', source, msg, e, st, dumpCrumbs: true);
  void warn(String source, String msg, [Object? e, StackTrace? st]) =>
      _write('WARN', source, msg, e, st);
  void info(String source, String msg) => _write('INFO', source, msg, null, null);

  /// Force-flush the async sink to disk (call before a risky native op or exit).
  Future<void> flush() async {
    try {
      await _sink?.flush();
    } catch (_) {
      /* logger must never throw */
    }
  }

  /// Flush and close the sink, releasing the file handle. Call on shutdown
  /// (and in tests, so the temp log file can be deleted on Windows).
  Future<void> close() async {
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {
      /* logger must never throw */
    }
    _sink = null;
  }

  void _write(
    String level,
    String source,
    String msg,
    Object? e,
    StackTrace? st, {
    bool dumpCrumbs = false,
  }) {
    try {
      final b = StringBuffer('${_clock().toIso8601String()} $level $source $msg');
      if (e != null) b.write('\n$e');
      if (st != null) b.write('\n$st');
      if (dumpCrumbs && _breadcrumbs.isNotEmpty) {
        b.write('\n--- breadcrumbs (${_breadcrumbs.length}) ---');
        for (final c in _breadcrumbs) {
          b.write('\n$c');
        }
        b.write('\n--- end breadcrumbs ---');
      }
      final line = b.toString();
      final sink = _sink;
      if (sink != null) {
        sink.writeln(line);
      } else {
        _pending.add(line);
        if (_pending.length > _maxPending) _pending.removeAt(0);
      }
    } catch (_) {
      /* logger must never throw */
    }
  }

  static String _stamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  void _prune(Directory logsDir) {
    try {
      final files =
          logsDir
              .listSync()
              .whereType<File>()
              .where((f) => p.basename(f.path).startsWith('shikiin-') && f.path.endsWith('.log'))
              .toList()
            ..sort((a, b) => b.path.compareTo(a.path)); // newest first (name sorts by time)
      // Keep maxSessions-1 existing; the about-to-be-created file is the maxSessions-th.
      for (var i = maxSessions - 1; i < files.length; i++) {
        files[i].deleteSync();
      }
      // 体积上限（用户 2026-10-11 的第二阶段要求：保留 10 个 / 最多 20MB）：
      // 条数达标不代表体积达标 —— 一场长会话里 mpv 的 error/警告能写出几十 MB，
      // 光按条数删会把 20MB 撑爆。从**最旧**的一端继续删到线下（files 新的在前，
      // 所以从尾部删）。
      var total = 0;
      for (final f in files) {
        if (f.existsSync()) total += f.lengthSync();
      }
      for (var i = files.length - 1; i >= 0 && total > maxTotalBytes; i--) {
        final f = files[i];
        if (!f.existsSync()) continue;
        total -= f.lengthSync();
        f.deleteSync();
      }
    } catch (_) {
      /* pruning is best-effort */
    }
  }
}

/// Global logger instance. `main()` calls [Diag.open]; everything else logs here.
final Diag diag = Diag();
