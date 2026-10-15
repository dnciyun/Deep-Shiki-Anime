/// 搜索历史（第三十三轮）：纯列表规则 + 两份互不影响的持久化。
///
/// 用户：「添加搜索历史记录」+「动漫库的独立计算」—— 所以这里同时钉两件事：
/// 规则本身（最新在前、去重、上限 20、删单条、清空），以及**搜索页与动漫库各一份**。
library;

import 'package:dsanima/domain/search_history.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/state/search_history_provider.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('纯规则', () {
    test('最新在前 + 同词去重（忽略大小写，保留这次的写法）', () {
      List<String> h = rememberSearchKeyword(const <String>[], '芙莉莲');
      h = rememberSearchKeyword(h, '迷宫饭');
      expect(h, <String>['迷宫饭', '芙莉莲']);
      h = rememberSearchKeyword(h, '芙莉莲');
      expect(h, <String>['芙莉莲', '迷宫饭'], reason: '再搜一次 = 提到最前，不出现第二条');
      h = rememberSearchKeyword(h, 'Frieren');
      h = rememberSearchKeyword(h, 'frieren');
      expect(h.first, 'frieren', reason: '保留用户刚打的写法');
      expect(h.where((String s) => s.toLowerCase() == 'frieren'), hasLength(1));
    });

    test('空词不记（"看最新"不是一次搜索）、超上限丢最旧的、删单条、脏数据读成空表', () {
      expect(rememberSearchKeyword(const <String>[], '   '), isEmpty);
      final List<String> many = <String>[
        for (int i = 0; i < kSearchHistoryMax + 5; i++) '词$i',
      ];
      final List<String> trimmed = rememberSearchKeyword(many, '最新');
      expect(trimmed, hasLength(kSearchHistoryMax));
      expect(trimmed.first, '最新');
      // 列表约定是"最新在前"，所以这批里最旧的是**最后一个**（词24）。
      expect(trimmed.contains('词24'), isFalse, reason: '先丢最旧的');
      expect(trimmed.last, '词18', reason: '留下的是最新的 19 条');

      expect(forgetSearchKeyword(<String>['A', 'b', 'C'], 'B'), <String>['A', 'C']);
      expect(readSearchHistory(<Object?>['A', 42, '', '  B  ', null]), <String>['A', 'B']);
      expect(readSearchHistory('不是列表'), isEmpty);
    });
  });

  group('两份历史（持久化）', () {
    test('各存一份、互不影响；删一条与清空都落盘', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore(<String, Object?>{});
      final ProviderContainer container = ProviderContainer(
        overrides: [keyValueStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      final SearchHistoryController ctrl =
          container.read(searchHistoryProvider.notifier);

      await ctrl.remember(SearchHistoryScope.torrents, '芙莉莲');
      await ctrl.remember(SearchHistoryScope.library, '葬送的芙莉莲');
      expect(container.read(searchHistoryProvider).torrents, <String>['芙莉莲']);
      expect(container.read(searchHistoryProvider).library, <String>['葬送的芙莉莲']);
      expect(store.get(kTorrentSearchHistoryKey), <String>['芙莉莲']);
      expect(store.get(kLibrarySearchHistoryKey), <String>['葬送的芙莉莲']);

      await ctrl.forget(SearchHistoryScope.torrents, '芙莉莲');
      expect(container.read(searchHistoryProvider).torrents, isEmpty);
      expect(container.read(searchHistoryProvider).library, <String>['葬送的芙莉莲'],
          reason: '动漫库那份不许跟着被删');

      await ctrl.clear(SearchHistoryScope.library);
      expect(container.read(searchHistoryProvider).library, isEmpty);
      expect(store.get(kLibrarySearchHistoryKey), isNull, reason: '清空 = 连键一起删掉');
    });

    test('重启后读得回来（同一份 store 重新建容器）', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore(<String, Object?>{});
      final ProviderContainer first = ProviderContainer(
        overrides: [keyValueStoreProvider.overrideWithValue(store)],
      );
      await first.read(searchHistoryProvider.notifier)
          .remember(SearchHistoryScope.library, '芙莉莲');
      first.dispose();

      final ProviderContainer again = ProviderContainer(
        overrides: [keyValueStoreProvider.overrideWithValue(store)],
      );
      addTearDown(again.dispose);
      expect(again.read(searchHistoryProvider).library, <String>['芙莉莲']);
    });
  });
}
