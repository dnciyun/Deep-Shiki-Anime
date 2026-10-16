/// 动漫库「种子」块的**宿主侧服务**（第四十五轮）：绑定落盘 + 番剧页缓存。
///
/// 只做两件与网络无关的事，所以它能独立单测、也不碰任何端口：
/// 1. **「这条 Bangumi 条目 ↔ 哪个 mikan 番剧页」落盘记住**（键 `dsanima.seed.binding.<subjectId>`）；
/// 2. **番剧页结果 30 分钟内存缓存**（[kLibrarySeedTtl]）。
///
/// 为什么第 2 条非有不可：core 的 `MikanSource.bangumi()` **不走缓存**（裸 `http.getText`），
/// 而那一页平均 432KB、还受"同站两次请求开始间隔 ≥1.2s"的限速约束 —— 反复进出同一部番
/// 会把自己限速住。失败**不留缓存**（第四十四轮的教训：把失败缓存了，重试就成了空操作）。
library;

import 'package:dsanima_core/sources/kv.dart' show KeyValueStore;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/library_seed.dart';
import '../domain/models.dart';
import 'infra.dart';

class LibrarySeedService {
  /// [store] 为 null 时只走进程内缓存（测试里就是这么用的）——与
  /// `state/bangumi_library.dart` 的写法一致。
  LibrarySeedService({this.store});

  final KeyValueStore? store;

  /// 绑定在盘上的键前缀（一个 subject 一条）。
  static const String bindingPrefix = 'dsanima.seed.binding.';

  /// 番剧页缓存：`bangumiId → (写入时刻, 详情)`。
  final Map<String, ({DateTime at, BangumiDetailView detail})> _details =
      <String, ({DateTime at, BangumiDetailView detail})>{};

  /// 进程内也记一份绑定（含"确实没有"这一结论，避免同一次会话反复读盘）。
  final Map<int, MikanSeedBinding?> _bindings = <int, MikanSeedBinding?>{};

  /// 这一条条目记住的 mikan 番剧页；没有就是 null。
  MikanSeedBinding? bindingFor(int subjectId) {
    if (_bindings.containsKey(subjectId)) return _bindings[subjectId];
    final KeyValueStore? s = store;
    if (s == null) return null;
    final MikanSeedBinding? binding = MikanSeedBinding.fromJson(
      s.get('$bindingPrefix$subjectId'),
    );
    _bindings[subjectId] = binding;
    return binding;
  }

  /// 记住绑定（**覆盖旧值**：改绑就是再调一次它）。
  Future<void> saveBinding(int subjectId, MikanSeedBinding binding) async {
    _bindings[subjectId] = binding;
    final KeyValueStore? s = store;
    if (s == null) return;
    try {
      await s.put('$bindingPrefix$subjectId', binding.toJson());
    } catch (_) {
      // 写盘失败不该让"这次能看种子"失败：最坏就是下次还得重搜一遍。
    }
  }

  /// 忘掉绑定（站点改名 / 页面被删之后，让下一次重新按番名找）。
  Future<void> forgetBinding(int subjectId) async {
    _bindings[subjectId] = null;
    final KeyValueStore? s = store;
    if (s == null) return;
    try {
      await s.put('$bindingPrefix$subjectId', const <String, Object?>{});
    } catch (_) {
      // 同上：静默。
    }
  }

  /// 番剧页缓存命中（超过 [kLibrarySeedTtl] 就当没有，并顺手清掉）。
  BangumiDetailView? cachedDetail(String bangumiId, {DateTime? now}) {
    final ({DateTime at, BangumiDetailView detail})? hit = _details[bangumiId];
    if (hit == null) return null;
    final Duration age = (now ?? DateTime.now()).difference(hit.at);
    if (age > kLibrarySeedTtl) {
      _details.remove(bangumiId);
      return null;
    }
    return hit.detail;
  }

  void putDetail(String bangumiId, BangumiDetailView detail, {DateTime? now}) {
    _details[bangumiId] = (at: now ?? DateTime.now(), detail: detail);
  }

  /// 丢掉某一页的缓存（失败重试、"重新搜一次"都走它）。
  void dropDetail(String bangumiId) => _details.remove(bangumiId);

  /// 清掉全部内存缓存（设置页清缓存时可用；目前只有测试与探针调）。
  void clear() {
    _details.clear();
    _bindings.clear();
  }
}

/// 默认实现直接读 `keyValueStoreProvider`（测试里它被换成内存实现，于是自动隔离）。
final Provider<LibrarySeedService> librarySeedServiceProvider =
    Provider<LibrarySeedService>(
      (Ref ref) => LibrarySeedService(store: ref.watch(keyValueStoreProvider)),
    );
