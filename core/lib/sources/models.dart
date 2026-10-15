/// 源层数据模型。
///
/// 字段名与语义**冻结**在 `docs/specs/2026-10-09-dsanima-design.md` §4.2，
/// 任何字段改名都必须先改 spec 再改代码。
library;

/// 源所在的**分区**（用户 2026-10-12 第十四轮：「聚合搜索……可切换聚合 / 动漫和全集」）。
///
/// 为什么是「注册时声明」而不是「从 id 里猜」：注册表在第 9/10 轮就已经把每个站点
/// 注册成**两个实例**（动漫 / 全集），哪一次注册是哪个分区是注册表**知道的事实**
/// （见 `registry.dart` 的注册顺序注释），从 id 字符串里反推（`endsWith('-batch')`）
/// 会在下一个源改名时悄悄错档，而错档的表现是「聚合结果里少了几个站」——
/// 用户看不出来，正是最难查的那种。
///
/// * [anime] = 各站的「动漫 / 動畫」分区（以及 mikan / nyaa 动漫区 / 自定义 RSS）；
/// * [collection] = 各站的「季度全集 / 合集」分区；
/// * [other] = 既不算动漫正片也不算合集（例如 sukebei 成人区）。
enum SourcePartition { anime, collection, other }

/// 一个可下载条目（种子 / 磁力）。
///
/// 所有字段除 [id] / [sourceId] 外都可能为 null —— 站点字段缺失时必须留 null，
/// **不允许用 0 / '' / 假数据填充**。
class SourceItem {
  const SourceItem({
    required this.id,
    required this.sourceId,
    this.title,
    this.detailUrl,
    this.torrentUrl,
    this.magnet,
    this.infoHash,
    this.sizeBytes,
    this.seeders,
    this.leechers,
    this.downloads,
    this.publishedAt,
    this.category,
    this.group,
    this.episodeHints = const <String>[],
    this.extra = const <String, dynamic>{},
  });

  /// 稳定唯一：`nyaa:2171209` / `mikan:<guid或episode hash>` / `rss:<feedId>:<guid>`。
  final String id;

  /// 展示标题。站点没有标题时为 null。
  final String? title;

  /// `nyaa` | `mikan` | `rss:<订阅id>`。
  final String sourceId;

  /// 详情页 URL。
  final Uri? detailUrl;

  /// `.torrent` 直链。
  final String? torrentUrl;

  /// 无 [torrentUrl] 时使用的磁力链接。
  final String? magnet;

  /// 40 位小写 hex info hash。
  final String? infoHash;

  final int? sizeBytes;
  final int? seeders;
  final int? leechers;
  final int? downloads;
  final DateTime? publishedAt;

  /// 站点分类，如 `Anime - English-translated`。
  final String? category;

  /// 字幕组 / 发布组（尽量解析，解析不到为 null）。
  final String? group;

  /// 从标题提取的集数提示：`01`、`S01E02`、`03v2` 等（见 [TitleParser]）。
  final List<String> episodeHints;

  /// 源特有字段（分辨率、语言、字幕、可信标记等），必须可 JSON 编码。
  final Map<String, dynamic> extra;

  /// 是否具备下载能力（磁力或 infoHash 至少有一个）。
  bool get isDownloadable => magnet != null || infoHash != null;

  /// 用于「加磁力」的最佳链接：优先 [magnet]，否则由 [infoHash] 拼出。
  String? get bestMagnet {
    final m = magnet;
    if (m != null && m.isNotEmpty) return m;
    final h = infoHash;
    if (h != null && h.isNotEmpty) return 'magnet:?xt=urn:btih:$h';
    return null;
  }

  SourceItem copyWith({
    String? id,
    String? sourceId,
    String? title,
    Uri? detailUrl,
    String? torrentUrl,
    String? magnet,
    String? infoHash,
    int? sizeBytes,
    int? seeders,
    int? leechers,
    int? downloads,
    DateTime? publishedAt,
    String? category,
    String? group,
    List<String>? episodeHints,
    Map<String, dynamic>? extra,
    bool clearMagnet = false,
    bool clearTorrentUrl = false,
  }) {
    return SourceItem(
      id: id ?? this.id,
      sourceId: sourceId ?? this.sourceId,
      title: title ?? this.title,
      detailUrl: detailUrl ?? this.detailUrl,
      torrentUrl: clearTorrentUrl ? null : (torrentUrl ?? this.torrentUrl),
      magnet: clearMagnet ? null : (magnet ?? this.magnet),
      infoHash: infoHash ?? this.infoHash,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      seeders: seeders ?? this.seeders,
      leechers: leechers ?? this.leechers,
      downloads: downloads ?? this.downloads,
      publishedAt: publishedAt ?? this.publishedAt,
      category: category ?? this.category,
      group: group ?? this.group,
      episodeHints: episodeHints ?? this.episodeHints,
      extra: extra ?? this.extra,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'sourceId': sourceId,
        if (title != null) 'title': title,
        if (detailUrl != null) 'detailUrl': detailUrl.toString(),
        if (torrentUrl != null) 'torrentUrl': torrentUrl,
        if (magnet != null) 'magnet': magnet,
        if (infoHash != null) 'infoHash': infoHash,
        if (sizeBytes != null) 'sizeBytes': sizeBytes,
        if (seeders != null) 'seeders': seeders,
        if (leechers != null) 'leechers': leechers,
        if (downloads != null) 'downloads': downloads,
        if (publishedAt != null) 'publishedAt': publishedAt!.toUtc().toIso8601String(),
        if (category != null) 'category': category,
        if (group != null) 'group': group,
        'episodeHints': episodeHints,
        'extra': extra,
      };

  factory SourceItem.fromJson(Map<String, dynamic> json) {
    return SourceItem(
      id: json['id'] as String,
      sourceId: json['sourceId'] as String,
      title: json['title'] as String?,
      detailUrl: _uriOrNull(json['detailUrl']),
      torrentUrl: json['torrentUrl'] as String?,
      magnet: json['magnet'] as String?,
      infoHash: json['infoHash'] as String?,
      sizeBytes: _intOrNull(json['sizeBytes']),
      seeders: _intOrNull(json['seeders']),
      leechers: _intOrNull(json['leechers']),
      downloads: _intOrNull(json['downloads']),
      publishedAt: _dateOrNull(json['publishedAt']),
      category: json['category'] as String?,
      group: json['group'] as String?,
      episodeHints: (json['episodeHints'] as List<dynamic>? ?? const <dynamic>[])
          .map((dynamic e) => e.toString())
          .toList(growable: false),
      extra: (json['extra'] as Map<dynamic, dynamic>? ?? const <dynamic, dynamic>{})
          .map((dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v)),
    );
  }

  @override
  String toString() => 'SourceItem($id, ${title ?? '<no title>'})';

  @override
  bool operator ==(Object other) => other is SourceItem && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// 一页结果。
class SourcePage {
  const SourcePage({
    required this.items,
    required this.fetchedAt,
    this.hasNext = false,
    this.page = 1,
    this.fromCache = false,
  });

  /// 空页（例如 RSS 源被请求第 2 页）。**不是**错误，也不会伪造数据。
  factory SourcePage.empty({required int page, required DateTime fetchedAt}) =>
      SourcePage(items: const <SourceItem>[], fetchedAt: fetchedAt, page: page);

  final List<SourceItem> items;
  final bool hasNext;

  /// 1-based。
  final int page;
  final DateTime fetchedAt;

  /// 是否来自缓存（含网络失败回落的 stale 缓存）。
  final bool fromCache;

  @override
  String toString() => 'SourcePage(page=$page, items=${items.length}, '
      'hasNext=$hasNext, fromCache=$fromCache)';
}

/// 源层统一异常。
///
/// 解析失败、HTTP 失败、格式不支持一律抛这个 —— **禁止静默返回假数据**。
class SourceException implements Exception {
  SourceException(
    this.message, {
    this.sourceId,
    this.url,
    this.statusCode,
    this.cause,
  });

  final String message;
  final String? sourceId;
  final Uri? url;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() {
    final b = StringBuffer('SourceException: $message');
    if (sourceId != null) b.write(' [source=$sourceId]');
    if (url != null) b.write(' [url=$url]');
    if (statusCode != null) b.write(' [status=$statusCode]');
    if (cause != null) b.write(' [cause=$cause]');
    return b.toString();
  }
}

Uri? _uriOrNull(Object? value) {
  if (value is Uri) return value;
  if (value is String && value.isNotEmpty) return Uri.tryParse(value);
  return null;
}

int? _intOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

DateTime? _dateOrNull(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}
