/// 「动漫库」状态（第三十三轮）：端口 + 当前查询 + 结果分页。
///
/// 与「今日推荐」的分工一样：这里只认 `domain/ports.dart` 的 [BangumiLibraryPort]，
/// 真实实现在 `state/bangumi_library.dart`，由 `main.dart` 装配注入；测试注入假实现。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/bangumi.dart';
import '../domain/bangumi_library.dart';
import '../domain/ports.dart';
import '../domain/unavailable.dart';

/// 未装配时是「显式失败」的实现（动漫库页面会显示"未接通 + 怎么办"）。
final Provider<BangumiLibraryPort> bangumiLibraryProvider =
    Provider<BangumiLibraryPort>((Ref ref) => const UnavailableBangumiLibraryPort());

/// 当前筛选条件（筛选条上的每一次改动都落在这里）。
class LibraryQueryController extends Notifier<BangumiLibraryQuery> {
  @override
  BangumiLibraryQuery build() => const BangumiLibraryQuery();

  void patch(BangumiLibraryQuery next) {
    if (next == state) return;
    state = next;
  }

  void setYear(int? year) => patch(
        year == null
            ? state.copyWith(clearYear: true, quarter: 0)
            : state.copyWith(year: year),
      );

  void setQuarter(int quarter) => patch(state.copyWith(quarter: quarter));

  void setForm(BangumiLibraryForm form) => patch(state.copyWith(form: form));

  void setSort(BangumiLibrarySort sort) => patch(state.copyWith(sort: sort));

  void setMinScore(double? score) => patch(
        score == null
            ? state.copyWith(clearMinScore: true)
            : state.copyWith(minScore: score),
      );

  /// 类型（Bangumi 的标签）：`null` = 不限。
  ///
  /// ⚠️ 只动这一格 —— 年份/形态/评分那些**照旧生效**。旧实现里详情页点标签走的是
  /// `patch(BangumiLibraryQuery(tag: tag))`（**整份换掉**），于是"我在动漫库筛着 2024 年，
  /// 从详情页点了个标签回来，年份没了"；右栏的类型胶囊更不能这么干（点一下清掉一整排条件
  /// 会让人不敢点）。
  void setTag(String? tag) => patch(
        (tag ?? '').trim().isEmpty
            ? state.copyWith(clearTag: true)
            : state.copyWith(tag: tag!.trim()),
      );

  /// 类型胶囊被点了第二次 = 取消这一档。
  void toggleTag(String tag) =>
      setTag((state.tag ?? '').trim() == tag.trim() ? null : tag);

  /// 提交关键词（回车/点搜索按钮）。
  void submitKeyword(String keyword) =>
      patch(state.copyWith(keyword: keyword.trim()));

  /// 只改输入框里的字、**不触发查询**（还按着键盘）。
  void typeKeyword(String keyword) => patch(state.copyWith(keyword: keyword));

  /// 「重置」：回到默认（全部动画）。
  void reset() => patch(const BangumiLibraryQuery());
}

final NotifierProvider<LibraryQueryController, BangumiLibraryQuery>
    libraryQueryProvider =
    NotifierProvider<LibraryQueryController, BangumiLibraryQuery>(
        LibraryQueryController.new);

/// 结果页状态。
@immutable
class LibraryView {
  const LibraryView({
    required this.query,
    required this.offset,
    this.trail = const <int>[0],
    this.trailIndex = 0,
    this.loading = false,
    this.started = false,
    this.pageSize = kLibraryDefaultPageSize,
    this.page,
    this.error,
  });

  final BangumiLibraryQuery query;

  /// 当前这一页的服务端起点。
  final int offset;

  /// 走过的每一页起点（[trailIndex] 指向当前这一页）。
  final List<int> trail;
  final int trailIndex;

  final bool loading;

  /// 有没有发过请求。**第一次查询由页面发起**（列数只有布局期才知道），
  /// 所以页面必须知道"还没发过"——否则当量出来的每页条数恰好等于兜底值（6 列 = 24 条）
  /// 时，那次"尺寸没变"会被当成"不用查"，页面就永远停在加载态
  /// （第三十四轮踩到：外壳测试 1400 宽 `pumpAndSettle` 收不住，就是这个）。
  final bool started;

  /// 这一页要多少条 = 列数 × [kLibraryRows]（第三十四轮：一页永远整行）。
  final int pageSize;

  final BangumiLibraryPage? page;
  final Object? error;

  /// 第几页（1 起）——**不是** offset/每页条数：本地过滤会让页与页之间不等长。
  int get pageNumber => trailIndex + 1;

  bool get canGoBack => trailIndex > 0;

  /// 下一页：服务端说还有，且这一页不是空的（空页再翻就没意义了）。
  bool get canGoForward =>
      !loading && (page?.hasMore ?? false) && (page?.items.isNotEmpty ?? false);

  bool get isLoadingFirstPage => loading && page == null;

  List<BangumiSubject> get items => page?.items ?? const <BangumiSubject>[];

  /// 服务端总数（已封顶 1000）；本地放送形态过滤会让实际显示的更少。
  int get total => page?.total ?? 0;
}

class LibraryResultsController extends Notifier<LibraryView> {
  int _requestId = 0;
  bool _disposed = false;

  /// 当前每页条数（列数变了要重算，见 [setPageSize]）。
  int _pageSize = kLibraryDefaultPageSize;

  /// 在途请求：键 + future（同一份请求不重复发，见 [_load]）。
  String? _pendingKey;
  Future<void>? _pending;
  int _loadToken = 0;

  /// 有没有发过请求。**第一次查询由页面发起**（见 [setPageSize]）：一页多少条要等
  /// 布局期量出列数才知道，`build` 里抢跑一次只会打出一个尺寸不对的页（第三十四轮）。
  bool _started = false;

  @override
  LibraryView build() {
    ref.onDispose(() => _disposed = true);
    final BangumiLibraryQuery query = ref.read(libraryQueryProvider);
    // 筛选条件一变就回到第一页重查（Riverpod 3 要求 listen 在 build 里注册）。
    ref.listen<BangumiLibraryQuery>(libraryQueryProvider,
        (BangumiLibraryQuery? previous, BangumiLibraryQuery next) {
      if (previous == next) return;
      unawaited(loadFirstPage());
    });
    // ⚠️ **第一次查询不在这里发**（第三十四轮）：一页多少条 = 列数 × [kLibraryRows]，
    // 而列数只有布局期才知道。这里抢跑一次会先打出一个尺寸不对的页（旧行为：进来打两次，
    // 一次 limit=24 白打），所以改成等页面量出列数后走 [setPageSize]。
    return LibraryView(query: query, offset: 0, loading: true, pageSize: _pageSize);
  }

  /// 页面量出列数之后告诉这里"一页该有多少条"（**整行**，第三十四轮）。
  ///
  /// 三种情况都要重新查：
  /// * 条数变了（窗口宽度跨过列档，或第一次量出来）；
  /// * 还没发过任何请求（进页面第一帧走这里发起第一次查询）。
  ///
  /// 窗口拖动会连续跨过几个列档，而端口那边有 10 分钟页缓存（键含 limit），
  /// 来回拖不会每次都打网络。
  void setPageSize(int size) {
    final int want = size < 1 ? kLibraryDefaultPageSize : size;
    if (want == _pageSize && _started) return;
    _pageSize = want;
    unawaited(loadFirstPage());
  }

  /// 回到第一页（筛选变了、点「重试」、列数变了都走它）。
  Future<void> loadFirstPage() => _load(0, trail: const <int>[0], trailIndex: 0);

  /// 下一页。游标由端口给（本地过滤会吃掉一些条目，不能自己 +每页条数）。
  Future<void> nextPage() {
    final int? cursor = state.page?.nextOffset;
    if (cursor == null || !state.canGoForward) return Future<void>.value();
    final List<int> trail = <int>[...state.trail.take(state.trailIndex + 1), cursor];
    return _load(cursor, trail: trail, trailIndex: trail.length - 1);
  }

  /// 上一页（走已记录的起点，端口那边有 10 分钟内存缓存，基本是瞬时的）。
  Future<void> previousPage() {
    if (!state.canGoBack) return Future<void>.value();
    return _load(state.trail[state.trailIndex - 1],
        trail: state.trail, trailIndex: state.trailIndex - 1);
  }

  /// 当前页重新拉一次（错误态的重试；绕过缓存由端口的 TTL 决定）。
  Future<void> reload() => _load(state.offset, trail: state.trail, trailIndex: state.trailIndex);

  Future<void> _load(
    int offset, {
    required List<int> trail,
    required int trailIndex,
  }) {
    final BangumiLibraryQuery query = ref.read(libraryQueryProvider);
    // ⚠️ **同一份请求别发两次**（第三十四轮）：列数只有布局期才知道，而"进页面就查一次"
    // 排在 `build` 之后 —— 进入页面的那一帧里可能连着来两次 `loadFirstPage()`
    // （一次是初始查询、一次是量到列数之后改每页条数）。键相同就复用同一次在途请求。
    final Future<void>? pending = _pending;
    if (pending != null && _pendingKey == '${query.cacheKey}|$offset|$_pageSize') {
      return pending;
    }
    final int token = ++_loadToken;
    _pendingKey = '${query.cacheKey}|$offset|$_pageSize';
    final Future<void> future = _runLoad(
      query,
      offset,
      trail: trail,
      trailIndex: trailIndex,
    ).whenComplete(() {
      // 只有"还是这一次"才清空：晚到的旧请求不许把新的在途标记抹掉。
      if (token == _loadToken) {
        _pending = null;
        _pendingKey = null;
      }
    });
    _pending = future;
    return future;
  }

  Future<void> _runLoad(
    BangumiLibraryQuery query,
    int offset, {
    required List<int> trail,
    required int trailIndex,
  }) async {
    final int id = ++_requestId;
    _started = true;
    state = LibraryView(
      query: query,
      offset: offset,
      trail: trail,
      trailIndex: trailIndex,
      loading: true,
      started: true,
      pageSize: _pageSize,
      // 换页时旧的一页先留在屏幕上（只盖一层转圈），不要闪成空白。
      page: trailIndex == state.trailIndex && offset == state.offset ? state.page : null,
    );
    try {
      final BangumiLibraryPage page = await ref
          .read(bangumiLibraryProvider)
          .search(query, offset: offset, limit: _pageSize);
      if (_disposed || id != _requestId) return; // 晚到的旧请求丢掉
      state = LibraryView(
        query: query,
        offset: offset,
        trail: trail,
        trailIndex: trailIndex,
        started: true,
        pageSize: _pageSize,
        page: page,
      );
    } catch (error) {
      if (_disposed || id != _requestId) return;
      state = LibraryView(
        query: query,
        offset: offset,
        trail: trail,
        trailIndex: trailIndex,
        started: true,
        pageSize: _pageSize,
        error: error,
      );
    }
  }
}

final NotifierProvider<LibraryResultsController, LibraryView>
    libraryResultsProvider =
    NotifierProvider<LibraryResultsController, LibraryView>(
        LibraryResultsController.new);
