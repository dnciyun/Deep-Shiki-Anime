/// 聚合搜索（2026-10-12 第十四轮）：一次问多个源，合并成一池、去重、新→旧排。
///
/// 用户原话：
/// > 「添加聚合搜索，聚合全部源，默认为聚合源，可切换聚合 动漫和全集，
/// >  设置中切换回单独源模式」
///
/// 三档（第一轮问答确认「按**分区**筛」，不是按内容猜）：
/// * [SearchScope.all]「聚合」= 全部源；
/// * [SearchScope.anime]「动漫」= 各站的动漫分区（mikan / nyaa 动漫区 / dmhy / acgrip /
///   acgnx / bangumimoe，以及自定义 RSS 与任何没特别声明的源）；
/// * [SearchScope.collection]「全集」= 各站的季度全集 / 合集分区。
///   ⚠️ **第二十四轮起只剩两个源**（`dmhy-batch` / `acgnx-batch`）：用户
///   「ACG.rip bangumi.moe 去除全集源」——ACG.RIP 的合集区几乎没有内容、
///   bangumi.moe 的关键字搜索不吃分区过滤（做不到"只搜合集"），两个实例都删了注册。
///   同时这两个源的**搜索 URL 也带上了各自的分区参数**（此前不带 ⇒ 「全集」档搜出来
///   的绝大部分是单集，用户报「无法只搜索全集」；真机证据
///   `build/probe-scope/probe-scope-filters.log`）。
///
/// 分区来自**注册时的声明**（core `SourceRegistry.partitionOf` → `SourceOption.partition`），
/// 不是从 id 里猜的 —— 理由见 core `SourcePartition` 的注释。sukebei 声明为
/// [SourcePartition.other]，所以它只会出现在「聚合」这一档预设里（第十五轮起它可以被
/// 单独勾上/取消，见文件末尾的「勾选」一节）。
///
/// 合并规则（第一轮问答选定的那一档）：**同一条资源只留一条**，
/// 判据是 `SourceItemView.dedupeKey`（有 infoHash 用 infoHash，没有就退回 id）。
/// 留哪一条：信息最全的那条（种子数 / 大小 / 磁力链 / 发布时间），平手时种子多的优先，
/// 再平手保持先到的（源注册顺序 = 稳定的）。排序：发布时间从新到旧，没时间的排最后。
///
/// ── 第十五轮：**勾选**（用户原话：「优化聚合搜索，默认全开，可选择几个源搜索，
/// 开启 sukebe 时也能勾选」）────────────────────────────────────────────────
/// 三颗 chip 从"查询时的挡板"改成了**快捷全选**：点「动漫」= 把动漫分区的源勾上、
/// 其余全部取消；真正决定"问哪些源"的只有一样东西 —— **勾选**。
///
/// 勾选存成**排除名单**（[Set] of 源 id），不是"勾选名单"。三个理由：
/// 1. 默认值天然就是"全开"（空集 = 一个都没排除）；
/// 2. **新出现的源自动算勾上**：刚打开的 sukebei、新加的 RSS 订阅不需要用户再点一次
///    —— 这正是用户说的「默认全开」「开启 sukebe 时也能勾选」；
/// 3. 源被移除又回来（sukebei 关掉再打开）时，用户当初的"不要它"仍然算数 ——
///    所以名单里留着一个已不存在的 id **不是脏数据**，不要去清理它。
library;

import 'models.dart';

/// 聚合搜索的一档。
enum SearchScope {
  all('聚合'),
  anime('动漫'),
  collection('全集');

  const SearchScope(this.label);
  final String label;

  /// 这个分区落不落在本档里。
  bool matches(SourcePartition partition) => switch (this) {
    SearchScope.all => true,
    SearchScope.anime => partition == SourcePartition.anime,
    SearchScope.collection => partition == SourcePartition.collection,
  };
}

/// 单个源在聚合里最多等多久（第一轮问答：「单个源最多等 15 秒」）。
const Duration kAggregateSourceTimeout = Duration(seconds: 15);

/// 同时打几个源。
///
/// 为什么不用「全部并发」：一轮聚合最坏要打 10 个源，10 条 HTTP 一起出去（shared
/// transport 只按**同一 host** 限速）对站点不礼貌，也容易撞上对方的风控。
/// 4 个一批是"够快 + 别把站点打疼"的折中；慢的那几个源会在自己的 15 秒上限里结束。
const int kAggregateMaxConcurrent = 4;

/// 这一档要问哪些源。
///
/// [needSearch] = true 时只留 `supportsSearch` 的源（「最新」那条路不看这个：
/// 每个源都能给最新，只有**搜索**才挑源）。
List<SourceOption> sourcesForScope(
  List<SourceOption> sources,
  SearchScope scope, {
  bool needSearch = true,
}) {
  return <SourceOption>[
    for (final SourceOption s in sources)
      if (scope.matches(s.partition) && (!needSearch || s.supportsSearch)) s,
  ];
}

/// 一条条目的「信息全不全」，用于同一条资源在多个站都有时决定留哪条。
///
/// 权重刻意偏"能播/能下"的字段（磁力链、种子直链）：只有它们的条目才是可行动的，
/// 光有标题没有下载方式的条目留在列表里点不动。
int itemRichness(SourceItemView item) {
  int score = 0;
  if (item.magnet != null && item.magnet!.isNotEmpty) score += 2;
  if (item.torrentUrl != null && item.torrentUrl!.isNotEmpty) score += 2;
  if (item.infoHash != null && item.infoHash!.isNotEmpty) score += 1;
  if (item.sizeBytes != null) score += 1;
  if (item.seeders != null) score += 1;
  if (item.publishedAt != null) score += 1;
  if (item.group != null && item.group!.isNotEmpty) score += 1;
  if (item.episodeHints.isNotEmpty) score += 1;
  return score;
}

/// [a] 是否比 [b] 更该留在池子里（同一条资源的两份拷贝之间比）。
///
/// 第四十八轮公开：动漫库种子块的「同名合并」也要用**同一把尺子** —— 同一件事
/// （两份拷贝留哪份）写两套比较，迟早会漂移出"聚合搜索留 A、种子块留 B"这种行为。
bool richerItem(SourceItemView a, SourceItemView b) {
  final int ra = itemRichness(a);
  final int rb = itemRichness(b);
  if (ra != rb) return ra > rb;
  final int sa = a.seeders ?? -1;
  final int sb = b.seeders ?? -1;
  if (sa != sb) return sa > sb;
  return false; // 平手：保持先到的
}

/// 把新拿到的一批条目并进已有的池子（按 [SourceItemView.dedupeKey] 去重）。
///
/// 顺序保持「先到先得」——排序是 [aggregateSort] 的事，这一步不动顺序，
/// 免得"合并"和"排序"两件事纠缠在一起（分页只需要合并）。
List<SourceItemView> aggregateMerge(
  List<SourceItemView> base,
  Iterable<SourceItemView> incoming,
) {
  final List<SourceItemView> out = List<SourceItemView>.of(base);
  final Map<String, int> at = <String, int>{
    for (int i = 0; i < out.length; i++) out[i].dedupeKey: i,
  };
  for (final SourceItemView item in incoming) {
    final int? existing = at[item.dedupeKey];
    if (existing == null) {
      at[item.dedupeKey] = out.length;
      out.add(item);
      continue;
    }
    if (richerItem(item, out[existing])) out[existing] = item;
  }
  return out;
}

/// 排序：发布时间从新到旧；没有发布时间的排最后；时间相同按 id 稳定。
///
/// 为什么要排序而不是"哪个源先回来谁在前"：聚合的意义就是让用户一眼看到**最新的**，
/// 而各源返回顺序、并发完成顺序都是随机的（同一句话搜两次可能顺序不同）。
List<SourceItemView> aggregateSort(List<SourceItemView> items) {
  final List<SourceItemView> out = List<SourceItemView>.of(items);
  out.sort((SourceItemView a, SourceItemView b) {
    final DateTime? da = a.publishedAt;
    final DateTime? db = b.publishedAt;
    if (da != null && db != null) {
      final int byTime = db.compareTo(da); // 新的在前
      if (byTime != 0) return byTime;
    } else if (da != null) {
      return -1; // 有时间的在前
    } else if (db != null) {
      return 1;
    }
    return a.id.compareTo(b.id);
  });
  return out;
}

/// 一个源在这一轮聚合里的结果（成功与失败都要有名字，失败才好报给用户）。
class AggregateSourceResult {
  const AggregateSourceResult({
    required this.sourceId,
    required this.displayName,
    this.items = const <SourceItemView>[],
    this.hasNext = false,
    this.failure,
    this.fromCache = false,
    this.staleFallback = false,
    this.fetchedAt,
  });

  final String sourceId;
  final String displayName;
  final List<SourceItemView> items;

  /// 这个源说"还有下一页"（宿主据此决定还能不能往下翻）。
  final bool hasNext;

  /// 失败原因（已归一化的用户可读文本）；null = 这个源成功了。
  final String? failure;
  final bool fromCache;

  /// 这个源是**网络失败后回落过期缓存**（UX #10；与"新鲜命中"要分开说）。
  final bool staleFallback;
  final DateTime? fetchedAt;

  bool get ok => failure == null;
}

/// 失败的那些源（顺序 = 传进来的顺序 = 源注册顺序，稳定）。
List<AggregateSourceResult> aggregateFailures(List<AggregateSourceResult> results) =>
    <AggregateSourceResult>[for (final AggregateSourceResult r in results) if (!r.ok) r];

/// 警告带文案：**部分源**没回来时说明是哪几个（全部失败时由调用方走整页报错）。
///
/// 为什么不静默跳过：静默跳过会让用户以为"聚合了全部源"，而真相是少看了几个站 ——
/// 一句话搜不到时，这个区别决定了他是"真没有"还是"某个站挂了"。
String aggregateFailureBanner(List<AggregateSourceResult> results, {int max = 3}) {
  final List<AggregateSourceResult> failed = aggregateFailures(results);
  if (failed.isEmpty) return '';
  final String head = '${failed.length}/${results.length} 个源没回来：';
  final List<String> shown = <String>[
    for (final AggregateSourceResult r in failed.take(max)) '${r.displayName}（${r.failure}）',
  ];
  final String tail = failed.length > max ? ' …共 ${failed.length} 个' : '';
  return '$head${shown.join('、')}$tail';
}

/// 结果行里那个"来源"该显示成什么（第四十二轮 UX #16）。
///
/// 旧实现直接打印 `item.sourceId` —— 表格里出现的是 `mikan`、`dmhy-batch`、
/// `acgnx-batch`、`rss:8f3a1c…` 这类**内部 id**。用户既看不懂，也认不出哪个是自己
/// 订阅的那个源，更没法把它和「源」面板里的名字对上。
///
/// 规则（宁可难看也不要显示一个错的源名）：
/// * 源表里查得到 → 用它的 `displayName`（= 「源」面板、设置里看到的同一个名字）；
/// * `rss:<订阅 id>` → 「订阅源」（订阅名在订阅那一侧，结果行拿不到，也不编）；
/// * 查不到（源被移除 / 注册表变了）→ 原样显示 id。
String sourceLabelFor(String sourceId, List<SourceOption> options) {
  for (final SourceOption o in options) {
    if (o.id == sourceId) return o.displayName;
  }
  if (sourceId.startsWith('rss:')) return '订阅源';
  return sourceId;
}

// ─────────────────────────────────────────────────────────────────────────────
// 勾选：哪些源要问（2026-10-12 第十五轮）
//
// 真相只有一份：`excludedSourceIds`（排除名单）。三颗 chip 是它的快捷方式，
// 「源 N/M」面板是它的编辑器，`searchProvider` 的取数只认它算出来的那一组源。
// ─────────────────────────────────────────────────────────────────────────────

/// 一档 chip 对应的**排除名单**：不在这一档里的源全被排除。
///
/// 这就是"chip 变快捷全选"的全部实现：点「全集」= 把 anime 与 other 分区的源都排掉。
Set<String> excludedForScope(List<SourceOption> sources, SearchScope scope) => <String>{
  for (final SourceOption s in sources)
    if (!scope.matches(s.partition)) s.id,
};

/// 勾上的源里**真正会去问**的那些。
///
/// [needSearch] = true（有关键字）时再筛掉 `supportsSearch` 为假的源：RSS 订阅源
/// 只提供"最新"，`search()` 会直接抛错（老行为，第十四轮就是这样）。
List<SourceOption> selectedSources(
  List<SourceOption> sources,
  Set<String> excludedSourceIds, {
  bool needSearch = true,
}) => <SourceOption>[
  for (final SourceOption s in sources)
    if (!excludedSourceIds.contains(s.id) && (!needSearch || s.supportsSearch)) s,
];

/// 勾上了几个源（不看 `supportsSearch`：面板里那个"5/7"说的就是用户勾了几个）。
int selectedSourceCount(List<SourceOption> sources, Set<String> excludedSourceIds) {
  int count = 0;
  for (final SourceOption s in sources) {
    if (!excludedSourceIds.contains(s.id)) count++;
  }
  return count;
}

/// 勾选是否**正好**等于某一档预设（chip 高亮用）。
///
/// 只比较**当前注册表里**的源：排除名单里躺着一个已经不存在的 id（sukebei 关掉之后）
/// 不该让「聚合」档看起来"没选全"。
bool selectionMatchesScope(
  List<SourceOption> sources,
  Set<String> excludedSourceIds,
  SearchScope scope,
) {
  for (final SourceOption s in sources) {
    if (excludedSourceIds.contains(s.id) == scope.matches(s.partition)) return false;
  }
  return true;
}

/// 当前勾选**正好**是哪一档；手动改过（和哪一档都不完全一样）→ null = 自定义。
///
/// 为什么要有这个"反推"：档位不是第二份真相，而是勾选的一个名字。两份状态一定会
/// 出现"我点着动漫，可 sukebei 也勾着"这种自相矛盾的样子，到时候说出来的话就是错的。
SearchScope? activeScopePreset(List<SourceOption> sources, Set<String> excludedSourceIds) {
  for (final SearchScope scope in SearchScope.values) {
    if (selectionMatchesScope(sources, excludedSourceIds, scope)) return scope;
  }
  return null;
}

/// 取消 [id] 会不会被"至少留一个源"的规则挡住（第一轮问答选定：不允许零勾）。
///
/// 判定刻意按"取消之后还剩几个"来算：这一个是唯一勾着的 → 取消后一个源都没有 →
/// 挡住。已经没勾的（用户在点"勾上"）永远不挡。
bool blocksUnselect({
  required List<SourceOption> sources,
  required Set<String> excludedSourceIds,
  required String id,
}) {
  if (excludedSourceIds.contains(id)) return false; // 它本来就没勾，不存在"取消最后一个"
  return selectedSourceCount(sources, excludedSourceIds) <= 1;
}

/// 面板里的一个分组（动漫 / 全集 / 其它）。
class SourceGroup {
  const SourceGroup(this.partition, this.sources);

  final SourcePartition partition;
  final List<SourceOption> sources;
}

/// 分区名（面板分组标题与提示文案共用）。
String partitionLabel(SourcePartition partition) => switch (partition) {
  SourcePartition.anime => '动漫',
  SourcePartition.collection => '全集',
  SourcePartition.other => '其它',
};

/// 按分区把源分组（动漫 → 全集 → 其它），**空组不返回**；组内保持注册顺序。
///
/// 顺序刻意固定成 anime / collection / other：面板每打开一次都长一个样，
/// 用户才能靠位置记住"sukebei 在最下面那组"。
List<SourceGroup> sourceGroups(List<SourceOption> sources) => <SourceGroup>[
  for (final SourcePartition p in <SourcePartition>[
    SourcePartition.anime,
    SourcePartition.collection,
    SourcePartition.other,
  ])
    if (sources.any((SourceOption s) => s.partition == p))
      SourceGroup(
        p,
        <SourceOption>[for (final SourceOption s in sources) if (s.partition == p) s],
      ),
];

/// 「源 N/M」那颗按钮上的字（N = 勾上的，M = 注册表里的全部源）。
String selectionSummary(List<SourceOption> sources, Set<String> excludedSourceIds) =>
    '源 ${selectedSourceCount(sources, excludedSourceIds)}/${sources.length}';

/// 「源」面板里那句"正在问哪些站"的说明（按钮 tooltip 与面板副标题共用）。
///
/// 勾上的逐个列出来：聚合搜索最怕的一件事就是"我以为是全部源，其实某个站没在问"，
/// 把名字摆出来比一个数字更能说明白。
String selectionDetail(
  List<SourceOption> sources,
  Set<String> excludedSourceIds, {
  bool needSearch = true,
  int max = 6,
}) {
  final List<SourceOption> on = selectedSources(
    sources,
    excludedSourceIds,
    needSearch: false,
  );
  final List<String> names = <String>[for (final SourceOption s in on) s.displayName];
  if (names.isEmpty) return '一个源都没勾：搜索会直接报错，至少勾一个';
  final String head = names.length > max
      ? '${names.take(max).join('、')} …共 ${names.length} 个'
      : names.join('、');
  final int skipped = needSearch
      ? on.where((SourceOption s) => !s.supportsSearch).length
      : 0;
  final String tail = skipped == 0 ? '' : '（其中 $skipped 个不支持关键字搜索，只在「最新」里参与）';
  return '正在问：$head$tail';
}
