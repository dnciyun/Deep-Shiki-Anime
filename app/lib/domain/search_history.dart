/// 搜索历史（第三十三轮）：**纯列表操作**，两个入口各存一份、互不影响。
///
/// 用户原话：「添加搜索历史记录」「动漫库的独立计算」—— 所以：
/// * 搜索页（种子搜索）一份：`dsanima.search_history.torrents`
/// * 动漫库（Bangumi 条目搜索）一份：`dsanima.search_history.library`
///
/// 两份的规则完全一样（同一套纯函数），但**不共享数据**：在种子搜索里打过的词，
/// 不会出现在动漫库的历史里 —— 那两件事的"最近搜过什么"本来就不是一回事。
///
/// 为什么要有条数上限：[watch_history] 那边的教训 —— 一个无限长的列表每次读写都要
/// 序列化整份，而"最近搜过什么"超过 20 条就没人往下看了。
library;

/// 搜索历史最多留几条（超出的从**最旧**开始丢）。
const int kSearchHistoryMax = 20;

/// 历史项的存储键（两个入口各一个）。
const String kTorrentSearchHistoryKey = 'dsanima.search_history.torrents';
const String kLibrarySearchHistoryKey = 'dsanima.search_history.library';

/// 读一份历史（盘上脏数据 → 空表，绝不因为一条坏记录把搜索页打崩）。
List<String> readSearchHistory(Object? raw) {
  if (raw is! List) return const <String>[];
  return <String>[
    for (final Object? item in raw)
      if (item is String && item.trim().isNotEmpty) item.trim(),
  ];
}

/// 记一笔搜索：**最新在前、同词去重（忽略大小写）、超过上限丢最旧的**。
///
/// 去重忽略大小写但**保留用户这次的写法**（`frieren` 之后再搜 `Frieren`，
/// 列表里显示的是他刚打的 `Frieren`）。
List<String> rememberSearchKeyword(
  List<String> history,
  String keyword, {
  int max = kSearchHistoryMax,
}) {
  final String word = keyword.trim();
  if (word.isEmpty) return List<String>.unmodifiable(history);
  final String folded = word.toLowerCase();
  return List<String>.unmodifiable(<String>[
    word,
    for (final String item in history)
      if (item.trim().toLowerCase() != folded) item,
  ].take(max < 1 ? 1 : max));
}

/// 删掉某一条（大小写不敏感）。
List<String> forgetSearchKeyword(List<String> history, String keyword) {
  final String folded = keyword.trim().toLowerCase();
  return List<String>.unmodifiable(
    history.where((String item) => item.trim().toLowerCase() != folded),
  );
}
