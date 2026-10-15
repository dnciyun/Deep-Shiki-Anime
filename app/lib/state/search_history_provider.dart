/// 搜索历史状态（第三十三轮）：两个入口各一份，读写都过 `KeyValueStore`（Hive）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/search_history.dart';
import 'infra.dart';

/// 哪一份历史。
enum SearchHistoryScope {
  /// 搜索页（种子搜索）。
  torrents(kTorrentSearchHistoryKey, '搜索历史'),

  /// 动漫库（Bangumi 条目搜索）。
  library(kLibrarySearchHistoryKey, '动漫库搜索历史');

  const SearchHistoryScope(this.storageKey, this.title);

  final String storageKey;
  final String title;
}

/// 两份历史（一个 Notifier 管两格：写入时整份换掉，界面只读自己那一格）。
@immutable
class SearchHistories {
  const SearchHistories({
    this.torrents = const <String>[],
    this.library = const <String>[],
  });

  final List<String> torrents;
  final List<String> library;

  List<String> of(SearchHistoryScope scope) =>
      scope == SearchHistoryScope.library ? library : torrents;

  SearchHistories withScope(SearchHistoryScope scope, List<String> value) =>
      scope == SearchHistoryScope.library
          ? SearchHistories(torrents: torrents, library: value)
          : SearchHistories(torrents: value, library: library);
}

class SearchHistoryController extends Notifier<SearchHistories> {
  @override
  SearchHistories build() {
    final store = ref.read(keyValueStoreProvider);
    return SearchHistories(
      torrents: readSearchHistory(store.get(SearchHistoryScope.torrents.storageKey)),
      library: readSearchHistory(store.get(SearchHistoryScope.library.storageKey)),
    );
  }

  /// 记一笔（搜之前/搜成功都行：这里不判断结果好坏，"搜过什么"是事实）。
  Future<void> remember(SearchHistoryScope scope, String keyword) async {
    final List<String> next = rememberSearchKeyword(state.of(scope), keyword);
    if (listEquals(next, state.of(scope))) return;
    state = state.withScope(scope, next);
    await ref.read(keyValueStoreProvider).put(scope.storageKey, next);
  }

  /// 删一条。
  Future<void> forget(SearchHistoryScope scope, String keyword) async {
    final List<String> next = forgetSearchKeyword(state.of(scope), keyword);
    if (listEquals(next, state.of(scope))) return;
    state = state.withScope(scope, next);
    await ref.read(keyValueStoreProvider).put(scope.storageKey, next);
  }

  /// 清空这一份。
  Future<void> clear(SearchHistoryScope scope) async {
    if (state.of(scope).isEmpty) return;
    state = state.withScope(scope, const <String>[]);
    await ref.read(keyValueStoreProvider).delete(scope.storageKey);
  }
}

final NotifierProvider<SearchHistoryController, SearchHistories>
    searchHistoryProvider =
    NotifierProvider<SearchHistoryController, SearchHistories>(
        SearchHistoryController.new);
