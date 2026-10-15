/// 「已完成」页的 bangumi 封面（2026-10-12 第十四轮）。
///
/// 用户原话：
/// > 「封面调用bangumi，bangumi搜索逻辑去除框里面的只搜名字，比如 [hyakuhuyu&VCB-Studio]
/// >  Re Zero kara Hajimeru Isekai Seikatsu 3rd Season [51][Ma10p_1080p][x265_flac_aac].CHS.mp4
/// >  只搜 Re Zero kara Hajimeru Isekai Seikatsu 3rd Season，默认使用第一个，
/// >  如果错的，可点开错误封面，然后展示搜索内容自选，如果还是没有可自己搜索」
///
/// 追问后确认：**手选结果不记住**（「不记住，每次重新匹配」）—— 所以这里只有
/// **会话内**记忆：一张卡问过一次就不再重复打 bangumi（否则一屏十几张卡每次 rebuild
/// 都联网），进程退出即清空，下次启动重新按"第一个结果"匹配。
///
/// 判据刻意**不用** `bangumi_match.dart` 的置信度匹配：用户要的是"默认第一个，
/// 错了自己改"，而不是"置信度不够就不显示封面"。候选列表整份留给 UI，
/// 用户点开封面就能换（也可以自己输关键字重搜）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/bangumi.dart';
import '../domain/error_text.dart';
import '../domain/ports.dart' show PortUnavailableException;
import 'bangumi_meta_provider.dart';

/// 一次封面查询的状态（按归组键存）。
@immutable
class CompletedCoverState {
  const CompletedCoverState({
    this.candidates = const <String, List<BangumiSubject>>{},
    this.picked = const <String, BangumiSubject>{},
    this.loading = const <String>{},
    this.errors = const <String, String>{},
  });

  /// 归组键 → bangumi 搜出来的候选（顺序就是 bangumi 返回的顺序）。
  final Map<String, List<BangumiSubject>> candidates;

  /// 归组键 → 用户手选的条目（覆盖"第一个结果"）。
  final Map<String, BangumiSubject> picked;

  final Set<String> loading;
  final Map<String, String> errors;

  /// 这张卡该显示哪个条目：手选的优先，否则**默认第一个候选**（用户原话）。
  BangumiSubject? subjectOf(String key) {
    final BangumiSubject? chosen = picked[key];
    if (chosen != null) return chosen;
    final List<BangumiSubject>? list = candidates[key];
    if (list == null || list.isEmpty) return null;
    return list.first;
  }

  List<BangumiSubject> candidatesOf(String key) =>
      candidates[key] ?? const <BangumiSubject>[];

  bool isLoading(String key) => loading.contains(key);

  String? errorOf(String key) => errors[key];

  /// 这一条是不是**用户手选**的（对话框里给个标记，别让人以为默认就是它）。
  bool isPicked(String key) => picked.containsKey(key);

  CompletedCoverState copyWith({
    Map<String, List<BangumiSubject>>? candidates,
    Map<String, BangumiSubject>? picked,
    Set<String>? loading,
    Map<String, String>? errors,
  }) =>
      CompletedCoverState(
        candidates: candidates ?? this.candidates,
        picked: picked ?? this.picked,
        loading: loading ?? this.loading,
        errors: errors ?? this.errors,
      );
}

/// 番名 → bangumi 封面（会话内，不落盘）。
class CompletedCoverController extends Notifier<CompletedCoverState> {
  @override
  CompletedCoverState build() => const CompletedCoverState();

  /// 问一次（[key] = 归组键，[name] = 清洗后的番名）。
  ///
  /// 已经问过（有候选、或在飞、或失败过）就不再问：失败也记着，
  /// 免得一屏卡片每次 rebuild 都往 bangumi 打一次 —— 那正是被站点限速的姿势。
  /// 用户点「重新搜」走 [search]（它会清掉记录再问）。
  Future<void> ensure(String key, String name, {bool force = false}) async {
    final String keyword = name.trim();
    if (keyword.isEmpty) return;
    final CompletedCoverState before = state;
    if (!force &&
        (before.candidates.containsKey(key) ||
            before.loading.contains(key) ||
            before.errors.containsKey(key))) {
      return;
    }
    state = before.copyWith(loading: <String>{...before.loading, key});
    try {
      final BangumiClient? client = ref.read(bangumiMetaProvider)?.client;
      if (client == null) {
        throw const PortUnavailableException(
          'Bangumi 未接通',
          hint: '宿主没有注入元数据服务（设置 → 关于 里能看到装配状态）',
        );
      }
      final List<BangumiSubject> results =
          await client.searchSubjects(keyword, maxResults: 10);
      if (!ref.mounted) return;
      state = state.copyWith(
        candidates: <String, List<BangumiSubject>>{...state.candidates, key: results},
        loading: <String>{...state.loading}..remove(key),
        errors: <String, String>{...state.errors}..remove(key),
      );
    } catch (error, stackTrace) {
      if (!ref.mounted) return;
      state = state.copyWith(
        loading: <String>{...state.loading}..remove(key),
        errors: <String, String>{
          ...state.errors,
          key: describeFailure(error, stackTrace: stackTrace).message,
        },
      );
    }
  }

  /// 用户自己输关键字重搜（对话框里的输入框）：清掉这一条的记忆再问一次。
  Future<void> search(String key, String keyword) async {
    state = CompletedCoverState(
      candidates: <String, List<BangumiSubject>>{...state.candidates}..remove(key),
      picked: state.picked,
      loading: state.loading,
      errors: <String, String>{...state.errors}..remove(key),
    );
    await ensure(key, keyword, force: true);
  }

  /// 用户点开封面选了某一条。
  void pick(String key, BangumiSubject subject) {
    state = state.copyWith(
      picked: <String, BangumiSubject>{...state.picked, key: subject},
    );
  }

  /// 撤销手选（回到"默认第一个"）。
  void clearPick(String key) {
    if (!state.picked.containsKey(key)) return;
    state = state.copyWith(
      picked: <String, BangumiSubject>{...state.picked}..remove(key),
    );
  }
}
