/// 订阅规则与订阅模型（spec §4.3）。
///
/// `SubsRule` = 一条过滤/自动下载规则；`Subscription` = 一个源 + 若干规则 + 运行状态。
/// 字段名与 spec §4.3 完全一致（字段本身可变，便于 UI 直接编辑）。
library;

import '../sources/kv.dart';
import '../sources/models.dart';

/// 规则本身配置非法（例如正则写错）时抛出 —— **不静默返回 false**。
class SubsRuleException implements Exception {
  SubsRuleException(this.message, {this.ruleId});

  final String message;
  final String? ruleId;

  @override
  String toString() =>
      'SubsRuleException: $message${ruleId == null ? '' : ' [rule=$ruleId]'}';
}

/// 一条过滤/自动下载规则。
class SubsRule {
  SubsRule({
    required this.id,
    required this.name,
    this.sourceId,
    this.includeRegex = '',
    this.excludeRegex = defaultExcludeRegex,
    this.groupAllow,
    this.minSeeders = 0,
    this.minSizeMB = 0,
    this.maxSizeMB = 0,
    this.preferResolution,
    this.autoDownload = false,
    this.saveSubFolder = '',
  });

  /// spec §4.3 的默认排除模式。
  static const String defaultExcludeRegex = '(合集|全集|BDRip|HEVC.*10bit|招募|招新)';

  String id;
  String name;

  /// null = 全部源；否则必须与 `SourceItem.sourceId` 完全一致
  /// （`nyaa` / `mikan` / `rss:<订阅id>`）。
  String? sourceId;

  String includeRegex;

  String excludeRegex;

  /// 字幕组白名单（逗号分隔，空 = 不限）。
  String? groupAllow;

  int? minSeeders;

  /// 0 = 不限。
  int minSizeMB;

  /// 0 = 不限。
  int maxSizeMB;

  /// null | 720 | 1080 | 2160。
  int? preferResolution;

  bool autoDownload;

  /// 相对下载目录，支持 `{title}` / `{year}` 占位。
  String saveSubFolder;

  List<String> get groupAllowList => (groupAllow ?? '')
      .split(RegExp(r'[,，]'))
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toList(growable: false);

  /// 配置校验；返回人类可读错误，null = 合法。
  String? validate() {
    if (id.trim().isEmpty) return '规则 id 不能为空';
    try {
      RegExp(includeRegex);
    } on FormatException catch (e) {
      return 'includeRegex 不是合法正则: ${e.message}';
    }
    try {
      RegExp(excludeRegex);
    } on FormatException catch (e) {
      return 'excludeRegex 不是合法正则: ${e.message}';
    }
    final r = preferResolution;
    if (r != null && r != 720 && r != 1080 && r != 2160) {
      return 'preferResolution 只能是 null/720/1080/2160（收到 $r）';
    }
    if (maxSizeMB > 0 && minSizeMB > 0 && maxSizeMB < minSizeMB) {
      return 'maxSizeMB($maxSizeMB) 小于 minSizeMB($minSizeMB)';
    }
    if (minSizeMB < 0 || maxSizeMB < 0) return '体积限制不能为负数';
    if ((minSeeders ?? 0) < 0) return 'minSeeders 不能为负数';
    return null;
  }

  /// 命中判定。
  ///
  /// 语义要点（spec §4.3）：
  /// * [sourceId] 非 null 时必须与条目 sourceId 完全相等；
  /// * [includeRegex] 非空时必须命中标题；[excludeRegex] 非空时命中即排除；
  /// * [groupAllow] 非空时必须命中字幕组（**条目没有 group 时判为不命中**，fail closed）；
  /// * [minSeeders]：做种数未知按 0 处理（mikan RSS 就没有做种数）；
  /// * 体积上下限非 0 时，**体积未知的条目判为不命中**（避免误判自动下载）。
  bool matches(SourceItem item) {
    final error = validate();
    if (error != null) throw SubsRuleException(error, ruleId: id);

    final src = sourceId;
    if (src != null && src.trim().isNotEmpty && item.sourceId != src) {
      return false;
    }

    final title = item.title ?? '';
    if (includeRegex.isNotEmpty &&
        !RegExp(includeRegex, caseSensitive: false).hasMatch(title)) {
      return false;
    }
    if (excludeRegex.isNotEmpty &&
        RegExp(excludeRegex, caseSensitive: false).hasMatch(title)) {
      return false;
    }

    final allow = groupAllowList;
    if (allow.isNotEmpty) {
      final g = item.group;
      if (g == null || g.isEmpty) return false;
      if (!allow.any((String a) => a.toLowerCase() == g.toLowerCase())) {
        return false;
      }
    }

    final needSeeders = minSeeders ?? 0;
    if (needSeeders > 0 && (item.seeders ?? 0) < needSeeders) return false;

    if (minSizeMB > 0 || maxSizeMB > 0) {
      final size = item.sizeBytes;
      if (size == null) return false;
      final mb = size / (1024 * 1024);
      if (minSizeMB > 0 && mb < minSizeMB) return false;
      if (maxSizeMB > 0 && mb > maxSizeMB) return false;
    }

    return true;
  }

  /// 候选排序（spec §4.3）：分辨率优先 → 做种数 → 体积接近 `minSizeMB`。
  ///
  /// * 分辨率：等于 [preferResolution] 的排最前，然后按数值从高到低，
  ///   未知分辨率排最后；
  /// * 做种数：未知按 0 处理，从多到少；
  /// * 体积：与 `minSizeMB` 的差值从小到大（未知体积排最后）。
  int compareCandidates(SourceItem a, SourceItem b) {
    final byResolution = _resRank(b).compareTo(_resRank(a));
    if (byResolution != 0) return byResolution;

    final bySeeders = (b.seeders ?? 0).compareTo(a.seeders ?? 0);
    if (bySeeders != 0) return bySeeders;

    return _sizeDistance(a).compareTo(_sizeDistance(b));
  }

  int _resRank(SourceItem item) {
    final res = (item.extra['resolution'] as num?)?.toInt();
    if (res == null) return -1;
    final prefer = preferResolution;
    if (prefer == null) return res;
    return res == prefer ? 1000000 + res : res;
  }

  double _sizeDistance(SourceItem item) {
    final size = item.sizeBytes;
    if (size == null) return double.infinity;
    return (size / (1024 * 1024) - minSizeMB).abs();
  }

  /// 命中并按优先级排序的候选列表。
  List<SourceItem> rank(Iterable<SourceItem> items) {
    final matched = items.where(matches).toList(growable: true);
    matched.sort(compareCandidates);
    return matched;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        if (sourceId != null) 'sourceId': sourceId,
        'includeRegex': includeRegex,
        'excludeRegex': excludeRegex,
        if (groupAllow != null) 'groupAllow': groupAllow,
        'minSeeders': minSeeders,
        'minSizeMB': minSizeMB,
        'maxSizeMB': maxSizeMB,
        if (preferResolution != null) 'preferResolution': preferResolution,
        'autoDownload': autoDownload,
        'saveSubFolder': saveSubFolder,
      };

  factory SubsRule.fromJson(Map<String, dynamic> json) => SubsRule(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        sourceId: json['sourceId'] as String?,
        includeRegex: json['includeRegex'] as String? ?? '',
        excludeRegex: json['excludeRegex'] as String? ?? defaultExcludeRegex,
        groupAllow: json['groupAllow'] as String?,
        minSeeders: (json['minSeeders'] as num?)?.toInt() ?? 0,
        minSizeMB: (json['minSizeMB'] as num?)?.toInt() ?? 0,
        maxSizeMB: (json['maxSizeMB'] as num?)?.toInt() ?? 0,
        preferResolution: (json['preferResolution'] as num?)?.toInt(),
        autoDownload: json['autoDownload'] == true,
        saveSubFolder: json['saveSubFolder'] as String? ?? '',
      );

  SubsRule copyWith({
    String? id,
    String? name,
    String? sourceId,
    String? includeRegex,
    String? excludeRegex,
    String? groupAllow,
    int? minSeeders,
    int? minSizeMB,
    int? maxSizeMB,
    int? preferResolution,
    bool? autoDownload,
    String? saveSubFolder,
  }) =>
      SubsRule(
        id: id ?? this.id,
        name: name ?? this.name,
        sourceId: sourceId ?? this.sourceId,
        includeRegex: includeRegex ?? this.includeRegex,
        excludeRegex: excludeRegex ?? this.excludeRegex,
        groupAllow: groupAllow ?? this.groupAllow,
        minSeeders: minSeeders ?? this.minSeeders,
        minSizeMB: minSizeMB ?? this.minSizeMB,
        maxSizeMB: maxSizeMB ?? this.maxSizeMB,
        preferResolution: preferResolution ?? this.preferResolution,
        autoDownload: autoDownload ?? this.autoDownload,
        saveSubFolder: saveSubFolder ?? this.saveSubFolder,
      );

  @override
  String toString() => 'SubsRule($id, "$name")';
}

/// 一个订阅 = 一个源 + 若干规则 + 运行状态。
class Subscription {
  Subscription({
    required this.id,
    required this.name,
    required this.feedUrl,
    this.sourceKind = 'rss',
    Map<String, String>? sourceParams,
    List<SubsRule>? rules,
    this.refreshInterval = const Duration(minutes: 30),
    this.enabled = true,
    this.lastRefreshAt,
    this.lastError,
    Map<String, bool>? seededIds,
  })  : sourceParams = sourceParams ?? <String, String>{},
        rules = rules ?? <SubsRule>[],
        seededIds = seededIds ?? <String, bool>{};

  static const Set<String> sourceKinds = <String>{'rss', 'nyaa', 'mikan'};

  String id;
  String name;
  String feedUrl;

  /// `rss` | `nyaa` | `mikan`。
  String sourceKind;

  /// 如 `{'category': '1_2'}`。
  Map<String, String> sourceParams;

  List<SubsRule> rules;

  Duration refreshInterval;

  bool enabled;

  DateTime? lastRefreshAt;

  String? lastError;

  /// 首次抓取只做「已读」标记，不倒灌历史剧集（值恒为 true）。
  Map<String, bool> seededIds;

  /// 该订阅对应的 `SourceItem.sourceId`。
  String get sourceId =>
      sourceKind == 'rss' ? 'rss:$id' : sourceKind;

  /// 是否已经完成首次抓取（倒灌保护）。
  bool get isSeeded => seededIds.isNotEmpty;

  /// 命中该订阅任一规则的条目（按规则排序规则逐个排序）。
  List<SourceItem> matchAll(Iterable<SourceItem> items) {
    final all = items.toList(growable: false);
    final out = <SourceItem>[];
    final seen = <String>{};
    for (final rule in rules) {
      for (final item in rule.rank(all)) {
        if (seen.add(item.id)) out.add(item);
      }
    }
    return out;
  }

  /// 首次抓取：把当前全部条目标记为已读，返回集合本身（不入队）。
  Set<String> seed(Iterable<SourceItem> items) {
    for (final item in items) {
      seededIds[item.id] = true;
    }
    return seededIds.keys.toSet();
  }

  /// 过滤掉已读条目（倒灌保护）。
  List<SourceItem> unseen(Iterable<SourceItem> items) =>
      items.where((SourceItem i) => seededIds[i.id] != true).toList(growable: false);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'feedUrl': feedUrl,
        'sourceKind': sourceKind,
        'sourceParams': sourceParams,
        'rules': rules.map((SubsRule r) => r.toJson()).toList(),
        'refreshIntervalMs': refreshInterval.inMilliseconds,
        if (lastRefreshAt != null)
          'lastRefreshAt': lastRefreshAt!.toUtc().toIso8601String(),
        if (lastError != null) 'lastError': lastError,
        'enabled': enabled,
        'seededIds': seededIds,
      };

  factory Subscription.fromJson(Map<String, dynamic> json) => Subscription(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        feedUrl: json['feedUrl']?.toString() ?? '',
        sourceKind: json['sourceKind']?.toString() ?? 'rss',
        sourceParams: (json['sourceParams'] as Map?)
                ?.map((dynamic k, dynamic v) =>
                    MapEntry<String, String>(k.toString(), v.toString())) ??
            <String, String>{},
        rules: (json['rules'] as List?)
                ?.whereType<Map>()
                .map((Map m) => SubsRule.fromJson(
                    m.map((dynamic k, dynamic v) =>
                        MapEntry<String, dynamic>(k.toString(), v))))
                .toList() ??
            <SubsRule>[],
        refreshInterval: Duration(
          milliseconds: (json['refreshIntervalMs'] as num?)?.toInt() ??
              const Duration(minutes: 30).inMilliseconds,
        ),
        enabled: json['enabled'] != false,
        lastRefreshAt: json['lastRefreshAt'] is String
            ? DateTime.tryParse(json['lastRefreshAt'] as String)
            : null,
        lastError: json['lastError'] as String?,
        seededIds: (json['seededIds'] as Map?)?.map(
          (dynamic k, dynamic v) => MapEntry<String, bool>(k.toString(), v == true),
        ),
      );

  @override
  String toString() =>
      'Subscription($id, "$name", kind=$sourceKind, rules=${rules.length})';
}

/// 订阅持久化（注入 [KeyValueStore]，生产 = Hive 的 `subscriptions` box）。
class SubscriptionStore {
  SubscriptionStore(this.store, {this.key = 'subscriptions'});

  final KeyValueStore store;
  final String key;

  Future<List<Subscription>> load() async {
    final raw = store.get(key);
    if (raw is! List) return <Subscription>[];
    final out = <Subscription>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      try {
        out.add(Subscription.fromJson(
          entry.map((dynamic k, dynamic v) =>
              MapEntry<String, dynamic>(k.toString(), v)),
        ));
      } catch (_) {
        // 单条损坏 → 跳过，其余照常加载。
      }
    }
    return out;
  }

  Future<void> save(List<Subscription> subscriptions) => store.put(
        key,
        subscriptions.map((Subscription s) => s.toJson()).toList(),
      );
}
