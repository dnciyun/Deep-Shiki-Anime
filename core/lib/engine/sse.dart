/// SSE（`text/event-stream`）增量分帧与事件解码（spec §3.9 / §4.1）。
///
/// 分帧实现遵循 WHATWG EventSource 规则，并能抗住真实网络的三种恶劣情况：
/// * **跨 chunk 截断**：`data:` 行、甚至 `\r\n` 被切成两半；
/// * **多行 data**：多行 `data:` 用 `\n` 拼接后再解析 JSON；
/// * **注释行 / 未知字段**：`:` 开头的心跳注释、`retry:` 一律忽略。
library;

import 'dart:convert';

import 'json_tools.dart';
import 'models.dart';

/// 一个已分帧的 SSE 事件。
class SseFrame {
  const SseFrame({this.event, required this.data, this.id});

  /// `event:` 字段（缺省为 `null`，按 EventSource 语义等价于 `message`）。
  final String? event;

  /// `data:` 字段（多行以 `\n` 连接）。
  final String data;

  /// `id:` 字段（本实现不发送 `Last-Event-ID`，仅保留供诊断）。
  final String? id;

  @override
  String toString() => 'SseFrame(event: $event, data: ${data.length} chars)';
}

/// 增量 SSE 解析器：把字节流解码后的字符串碎片喂进来，吐出完整帧。
///
/// 用法：`for (final frame in decoder.add(chunk)) { ... }`；
/// 流结束时调用 [close] 冲刷最后一行（对端最后一帧没有空行收尾的情况）。
class SseDecoder {
  String _buffer = '';
  String? _event;
  String? _id;
  final List<String> _dataLines = <String>[];
  bool _bomChecked = false;
  bool _pendingCrLfSuffix = false;

  /// 喂入一段解码后的文本，返回本次凑齐的完整帧。
  List<SseFrame> add(String chunk) {
    if (chunk.isEmpty) return const <SseFrame>[];
    if (_pendingCrLfSuffix) {
      // 上一个 chunk 以孤立 '\r' 结尾（已被当作行尾处理）。按 SSE 规则
      // '\r\n' 是一个行尾：如果这个 chunk 正好以 '\n' 开头，它是那半个 '\r\n'，
      // 必须吞掉，不能当成一个额外的空行。
      _pendingCrLfSuffix = false;
      if (chunk.startsWith('\n')) chunk = chunk.substring(1);
      if (chunk.isEmpty) return const <SseFrame>[];
    }
    _buffer += chunk;
    return _drain(finalFlush: false);
  }

  /// 流结束：把缓冲里剩余的一行当作完整行处理，并冲刷挂起的事件。
  List<SseFrame> close() => _drain(finalFlush: true);

  /// 清空全部状态（重连后复用实例时调用）。
  void reset() {
    _buffer = '';
    _event = null;
    _id = null;
    _dataLines.clear();
    _bomChecked = false;
    _pendingCrLfSuffix = false;
  }

  List<SseFrame> _drain({required bool finalFlush}) {
    final frames = <SseFrame>[];
    if (!_bomChecked) {
      _bomChecked = true;
      if (_buffer.startsWith('\uFEFF')) _buffer = _buffer.substring(1);
    }
    while (true) {
      final terminator = _findTerminator(_buffer, finalFlush);
      if (terminator == null) break;
      final line = _buffer.substring(0, terminator.$1);
      _buffer = _buffer.substring(terminator.$2);
      _handleLine(line, frames);
    }
    if (finalFlush) {
      // 对端最后一帧没有行尾收尾：把残留内容当作最后一行处理，再冲刷事件。
      if (_buffer.isNotEmpty) {
        final line = _buffer;
        _buffer = '';
        _handleLine(line, frames);
      }
      _dispatch(frames);
    }
    return frames;
  }

  /// 找到第一个完整的行尾，返回 `(行结束位置, 下一行起始位置)`。
  ///
  /// `\r` 落在缓冲区末尾时按行尾处理（否则 CRLF 服务端在 chunk 边界处会把帧
  /// 一直拖到下一个 chunk 才派发），同时记下 `_pendingCrLfSuffix`，
  /// 以便下一个 chunk 以 `\n` 开头时把那个 `\n` 吞掉。
  (int, int)? _findTerminator(String buffer, bool finalFlush) {
    for (var i = 0; i < buffer.length; i++) {
      final char = buffer[i];
      if (char == '\n') return (i, i + 1);
      if (char == '\r') {
        if (i == buffer.length - 1) {
          if (!finalFlush) _pendingCrLfSuffix = true;
          return (i, i + 1);
        }
        if (buffer[i + 1] == '\n') return (i, i + 2);
        return (i, i + 1);
      }
    }
    return null;
  }

  void _handleLine(String line, List<SseFrame> frames) {
    if (line.isEmpty) {
      _dispatch(frames);
      return;
    }
    if (line.startsWith(':')) return; // 注释行（常见于代理心跳）
    final colon = line.indexOf(':');
    final String field;
    String value;
    if (colon < 0) {
      field = line;
      value = '';
    } else {
      field = line.substring(0, colon);
      value = line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
    }
    switch (field) {
      case 'event':
        _event = value;
      case 'data':
        _dataLines.add(value);
      case 'id':
        _id = value;
      case 'retry':
        break; // 重连间隔由客户端退避策略决定，不接受服务端改写
      default:
        break; // 未知字段按 EventSource 规则忽略
    }
  }

  void _dispatch(List<SseFrame> frames) {
    if (_dataLines.isEmpty) {
      // EventSource 规则：data 为空则丢弃该事件，并重置事件名。
      _dataLines.clear();
      _event = null;
      return;
    }
    frames.add(SseFrame(event: _event, data: _dataLines.join('\n'), id: _id));
    _dataLines.clear();
    _event = null;
  }
}

/// 把 [SseFrame] 解码成 [EngineEvent]。
///
/// 返回 `null` 表示「这个帧不该被上层看见」：未知事件名、缺 event 名、
/// 空 data（heartbeat 除外）、非法 JSON、缺少必要字段。
/// 调用方应当记日志/回调，而不是让整条 SSE 流断掉。
class EngineEventCodec {
  const EngineEventCodec._();

  /// 解码单帧；无法识别返回 `null`。
  static EngineEvent? decode(SseFrame frame) {
    final name = frame.event;
    if (name == null || name.isEmpty) return null;
    if (name == 'heartbeat') return const EngineHeartbeat();
    final data = frame.data.trim();
    if (data.isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      return null;
    }
    final map = jsonMap(decoded);
    if (map == null) return null;
    switch (name) {
      case 'snapshot':
        final torrents = <EngineTorrent>[];
        for (final raw in jsonList(map['torrents'])) {
          final item = jsonMap(raw);
          if (item != null) torrents.add(EngineTorrent.fromJson(item));
        }
        return EngineSnapshot(List<EngineTorrent>.unmodifiable(torrents));
      case 'torrent_added':
        final torrent = jsonMap(map['torrent']);
        if (torrent == null) return null;
        return EngineTorrentAdded(EngineTorrent.fromJson(torrent));
      case 'progress':
        if (!_hasId(map)) return null;
        return EngineProgress.fromJson(map);
      case 'state':
        if (!_hasId(map)) return null;
        return EngineStateChanged.fromJson(map);
      case 'torrent_removed':
        if (!_hasId(map)) return null;
        return EngineTorrentRemoved(jsonInt(map['id']));
      default:
        return null; // 未知事件：向前兼容，静默丢弃由上层回调记录
    }
  }

  static bool _hasId(Map<String, dynamic> map) {
    final id = map['id'];
    return id is num || (id is String && int.tryParse(id.trim()) != null);
  }
}

/// SSE 断线重连的指数退避：默认 1s → 2s → 4s → … → 上限 30s。
///
/// 与 `next()` 配套的 `peek()` 用于「预计多久后重连」的日志/事件回调。
class EngineBackoff {
  EngineBackoff({
    this.initial = const Duration(seconds: 1),
    this.max = const Duration(seconds: 30),
    this.factor = 2,
  }) : assert(factor > 1, 'factor 必须大于 1');

  /// 首次重连等待时间。
  final Duration initial;

  /// 等待时间上限。
  final Duration max;

  /// 每次重连的放大系数。
  final num factor;

  Duration? _next;

  /// 下一次重连将等待的时间（不推进状态）。
  Duration get peek => _next ?? initial;

  /// 返回本次重连应等待的时间并推进到下一次。
  Duration next() {
    final value = _next ?? initial;
    final scaled = (value.inMicroseconds * factor).round();
    _next = scaled >= max.inMicroseconds ? max : Duration(microseconds: scaled);
    return value;
  }

  /// 连接恢复正常后重置退避。
  void reset() => _next = null;
}

/// 可注入的「等待」能力：测试注入假实现以避免真实等待。
typedef EngineSleep = Future<void> Function(Duration duration);

/// 默认等待实现。
Future<void> defaultEngineSleep(Duration duration) =>
    Future<void>.delayed(duration);
