/// 把「整页 HTML 解析」从调用方 isolate（Flutter 里就是 UI isolate）挪到子 isolate。
///
/// 背景（1.1.0 M1/T6）：nyaa / dmhy / acgrip / mikan 四个内置源的列表页解析都是
/// `package:html` 建整页 DOM 的**纯同步 CPU**，一页几百 KB～几 MB 就直接压在 UI
/// isolate 上。第一次量到它的是第四十七轮的 mikan（4.12MB 搜索页同步解析 ~460ms，
/// 用户原话「点进去时必卡一下」），那一轮只把 mikan 挪走了；T6 把同一套做法提成
/// 公共工具，nyaa / dmhy / acgrip 也接上。
///
/// 代价（量过，别以为改完就是 0 卡顿）：`Isolate.run` 的 isolate 与调用方**同属一个
/// isolate group、共享堆**，子 isolate 解析大页时触发的 GC 会把主线程一起暂停 ——
/// 实测 nyaa 123KB / dmhy 317KB 两页改后主线程停 2~4ms，450~1020 条的大结果出现过
/// 13~17ms 的单次停顿（`parse_off_thread_probe.dart` 的真实输出）；对比同步解析要
/// 12~226ms，仍是数量级改善。要彻底消掉这十几毫秒得换独立 isolate group
/// （`Isolate.spawnUri`，每次重新加载脚本/核），那个钱不值当。
///
/// 两条约定（都踩过，见第四十七轮 mikan 的实现）：
/// * **时钟按值传**（[now]），别把 `clock` 闭包带过去 —— 测试里的假时钟不保证可跨
///   isolate；同一页每一行本来就用同一个"现在"算相对日期，语义不变。
/// * ⚠️ `compute` 闭包必须在**顶层函数**里造（各源的 `_parseXxxOffThread` 入口），
///   不能在实例方法里直接写：Dart 的闭包按**上下文**捕获，实例方法里的上下文连着
///   `this`，于是 `Isolate.run` 会当场抛
///   `Illegal argument in isolate message: … _Future ← RateLimiter ← SourceHttp ← XxxSource`
///   （第四十七轮 mikan 实测：把 `id` / `baseUrl` 先取成局部变量**也不够**）。
///
/// 错误语义：解析里抛的 `SourceException`（含 `DmhyNotListPageException` /
/// `SourceNoResultsException` 两个子类）由 `Isolate.run` 原样送回调用方 isolate ——
/// 实测类型与文案都不变（`parse_off_thread_test.dart` 里有同一份大页的双路对比）。
/// 这条很要紧：dmhy 的「临时页自动重试一次」正是靠 `on DmhyNotListPageException`
/// 认的，类型一旦被换成 `RemoteError`，重试就会静默失效。
///
/// 超时 / 取消：这里只包**解析**这一段纯 CPU。HTTP 的超时在 `SourceHttp` 里早就走完了，
/// 本函数不新增、也不吞掉任何超时；解析本身原来也没有超时（同步跑完为止），现在不变。
library;

import 'dart:isolate';

/// 超过这个长度（UTF-16 code unit；页面基本全是 ASCII，≈ 字节）就把解析挪到子 isolate。
///
/// **64KB 是量出来的**（Windows / Dart 3.12 / `flutter test` 的 JIT，真数字见
/// `core/test/sources/parse_off_thread_probe.dart` 的输出）：
/// * `package:html` 建整页 DOM ≈ **60~80ms/MB**：dmhy 真机列表页 347KB → 26ms、
///   mikan 4.3MB 搜索页 → 257ms；而且**行解析不免费** —— nyaa 真实搜索页只有 123KB，
///   同步解析实测 **12~15ms**，已经越过半帧（60fps 8.3ms）；
/// * 空 `Isolate.run` 的启动开销实测 **≈0ms**（7 次里 6 次 0ms、冷启动 3ms），
///   所以阈值只该按"这一页解析要多久"定，不必为调度另留余量；
/// * 64KB ≈ **5ms**（75ms/MB × 64KB），约一帧的 1/3 —— 低于它留同步不为过，
///   高于它挪走、主线程最多只付一次 `Isolate.run` 的调度钱。
///
/// 为什么不是第四十七轮 mikan 定的 128KB：那是按 80ms/MB 估的 ~10ms，但 nyaa 的
/// 123KB 真实页面实测 15ms —— 按体积估会低估"行多"的页面，128KB 会把这一页留在主线程。
/// 真实小页（nyaa 详情 18KB → 1ms、dmhy 列表 12KB → 2ms、acgrip 列表 3KB → <1ms、
/// mikan 单集页 26KB → 2~7ms）都远低于 64KB，继续同步，不付 isolate 的钱。
const int kParseOffloadBytes = 64 * 1024;

/// 小于 [kParseOffloadBytes] 的页面**同步**解析（`compute` 当场跑完，与改动前一致）；
/// 大于等于则整段丢进子 isolate，主 isolate 只等结果、不被这页占住。
///
/// `compute` 的入参是按值传进来的"现在"，供各源在自己的解析器里造 `clock: () => at`。
Future<T> parseOffThread<T>({
  required String text,
  required DateTime now,
  required T Function(DateTime now) compute,
}) {
  if (text.length < kParseOffloadBytes) {
    // 注意：这里是**先算再包 Future**（不是 async 函数里算），小页的解析仍在调用点
    // 同步完成 —— 与改动前逐字节一致。别改成 `Future(() => compute(now))`：那会把
    // 小页也推到事件循环尾巴上，破坏「小负载同步走」的约定（也会让解析顺序变）。
    return Future<T>.value(compute(now));
  }
  return Isolate.run<T>(
    () => compute(now),
    debugName: 'dsanima-parse',
  );
}
