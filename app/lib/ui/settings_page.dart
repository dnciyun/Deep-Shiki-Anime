/// 设置页：下载目录 / 引擎路径与连通 / 代理 / 限速 / 省流量策略 / 并发 /
/// 源缓存 TTL / 省流量列表（可编辑）。
///
/// 保存语义（诚实原则）：
/// * 本页是**草稿 + 手动保存**（用户 2026-10-12 第十六轮：「去除设置自动保存的逻辑，
///   仅手动保存」）。改任何一个控件只动 [_SettingsPageState._draft]，界面上立刻是"有未保存的
///   改动"；点底部「保存并生效」才**先落盘**（Hive，一定成功）→ 再调
///   `LifecyclePort.applySettings` 让边车/源客户端真正生效；
/// * 生效失败时显示「已保存，但未生效：原因｜怎么办：提示」，
///   **不会**假装保存即生效；
/// * 带着未保存的改动切页 / 关窗时**拦一下**问三选（保存并生效 / 放弃改动 / 留在这）——
///   见 `state/settings_guard.dart` 与 `_resolveUnsaved()`。
library;

import 'dart:async';
import 'dart:io';

import 'package:dsanima_core/sources/kv.dart' show KeyValueStore;
import 'package:dsanima_core/update/update.dart' as core_update;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/app_version.dart';
import '../domain/download_dir.dart';
import '../domain/error_text.dart';
import '../domain/format.dart';
import '../domain/models.dart';
import '../domain/ports.dart';
import '../domain/settings_draft.dart';
import '../domain/trackers.dart';
import '../domain/watch_history.dart' show kHistoryRetentionDays;
import '../state/cache_sweep.dart';
import '../state/cover_cache.dart';
import '../state/export_service.dart';
import '../state/providers.dart';
import '../state/tracker_refresh.dart';
import '../state/update.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'widgets/ds_cards.dart';
import 'widgets/feedback.dart';
import 'widgets/ds_theme_reveal.dart';
import 'widgets/neo.dart';
import 'widgets/neo_appearance_picker.dart';
import 'widgets/neo_dropdown.dart';
import 'widgets/state_views.dart';

/// 设置页「⋯」菜单的动作（原来的「迁移与诊断」分组）。
enum _DiagAction { exportConfig, importConfig, exportDiagnostics }

/// 「设置有未保存的改动」那个三选对话框的结果。
enum _UnsavedChoice { save, discard, stay }

/// 底部保存条上的三个锚点（测试用：设置页控件太多，靠文字找容易撞）。
const Key dsSettingsSaveKey = ValueKey<String>('ds-settings-save');
const Key dsSettingsDiscardKey = ValueKey<String>('ds-settings-discard');
const Key dsSettingsSaveBarTextKey = ValueKey<String>('ds-settings-save-text');

/// 封面缓存自动清理周期（天）：**0 = 不清除**。用户 2026-10-11 第二阶段清单第 7 项
/// 的原话是「一个月自动清，设置里可选清除周期 / 不清除 / 立即清一次」。
const List<int> kCoverCachePeriodDays = <int>[30, 90, 180, 0];

// ─────────────────────────────────────────────────────────────────────────────
// 设置页的**局部字号阶梯**（第二十六轮：用户「缩小整体字大小」+「增加每个设置的间距」）
// ─────────────────────────────────────────────────────────────────────────────
//
// 为什么是"局部阶梯"而不是直接改 `DsTypeScale`：`DsTypeScale` 是**全站**阶梯，
// 宿主与播放窗口共用同一套（`player_bridge.toShikiiinTokens` 把 bodySize 传成
// 播放器的 fontSize，见 `theme/tokens.dart` 的说明），而用户这一轮只点了**设置页**
// 字太大。动全局阶梯会连带把播放器、主页、搜索页的字都改小 —— 那不是他要的。
// 校验 `DsTypeScale.all == [12,14,15,17,24]` 的用例（`widget_test.dart`）也保持原样。
//
// 档位与全局的对应关系：body 15→13、secondary 14→12、caption 12→11、title 17→15，
// 全部**仍按相对关系递增**，只是整体降一档。提高的设置间距见各处 `SizedBox` / padding。

/// 设置页正文字号（全局 body 15 → 13）。输入框、开关标题、按钮文字用它。
const double kSettingsBodySize = 13;

/// 设置页次要文字（全局 secondary 14 → 12）。区块内小标题、行内说明用它。
const double kSettingsSecondarySize = 12;

/// 设置页最小号字（全局 caption 12 → 11）。区块说明、辅助/空态文案用它。
const double kSettingsCaptionSize = 11;

/// 设置页区块标题（全局 title 17 → 15）。`DsSection` 的标题用它（跨文件共用）。
const double kSettingsTitleSize = 15;

/// 设置页：草稿 → 保存并生效；顶部「⋯」菜单放迁移与诊断。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  /// 草稿（用户在页面上的改动都落在这里，**保存之前一个字节都不写出去**）。
  late AppSettings _draft;

  /// 草稿的**起点**：这份草稿是从"已保存的哪一份"长出来的。
  ///
  /// 它同时是两个问题的答案：
  /// * "脏了没有" = [settingsEqual]\([_draft], [_baseline])（不是和"现在的已保存值"比 ——
  ///   后台写进去的东西不该让页面看起来像用户在改）；
  /// * 保存时"用户到底改了什么字段" = 逐字段 diff([_baseline], [_draft])，
  ///   见 [mergeDraftForSave]（没碰过的字段留给"现在的已保存值"，后台写入因此不会被吞）。
  late AppSettings _baseline;

  final TextEditingController _newExclude = TextEditingController();
  DsFailure? _applyFailure;
  String? _applySuccess;

  /// 正在保存（按钮转圈、防重复点）。
  bool _saving = false;

  /// 登记给「切页 / 关窗」的处理器与它的宿主（见 `state/settings_guard.dart`）。
  ValueNotifier<SettingsDraftGuard?>? _guardHolder;
  SettingsDraftGuard? _guard;

  /// tracker 一键更新在跑（联网拉列表）；以及列表是否展开全文。
  bool _busyTracker = false;
  bool _showTrackers = false;

  /// 「加一个来源」输入框（用户 2026-10-11：要能自己导入 URL）。
  final TextEditingController _newTrackerUrl = TextEditingController();

  /// 自动保存（2026-10-11 第二阶段清单第 6 项）在**第十六轮被用户点名去掉**：
  /// 「去除设置自动保存的逻辑，仅手动保存」。
  ///
  /// 删掉的是"看门狗 + 快照比对"那一整套（`Timer.periodic` → `_tickAutoSave` →
  /// 停止变化满 3 拍就落盘 + 生效）。它当初之所以敢开，前提是
  /// `EngineLifecyclePort.applySettings` 已经改成"只有进程参数变了才重启边车"；
  /// 现在改成手动保存之后，那层判断**仍然有用**（见 `domain/settings_effect.dart`）：
  /// 一次保存里改了下载目录就重启一次，只改 TTL 就只重建源客户端。
  ///
  /// 保留下来的是"草稿"这件事本身：页面依旧在 [_draft] 上工作，只是**只有用户点
  /// 保存（或离开时选"保存并生效"）才落盘 + 生效**。

  /// 封面缓存（第 7 项）：周期下拉的当前值、当前占用、清理中标志。
  bool _busyCache = false;
  CoverCacheUsage _cacheUsage = CoverCacheUsage.empty;

  /// KV 里的"只涨不减"缓存（源缓存 / 推荐 / 番剧信息）占用 —— 用户 2026-10-11
  /// 「不要没用的缓存」：这里能看见条数、能一键清空。
  HostCacheUsage _hostCache = const HostCacheUsage(
    sourceEntries: 0,
    sourceBytes: 0,
    recommendEntries: 0,
    metaEntries: 0,
  );

  String get _hostCacheLabel => _hostCache.entries == 0
      ? '暂无缓存'
      : '${_hostCache.sourceEntries} 条源缓存 · ${formatBytes(_hostCache.sourceBytes)}'
          ' · 番剧信息 ${_hostCache.recommendEntries + _hostCache.metaEntries} 条';

  /// 周期取值：草稿里是脏值时（导入/旧配置）回落到"一个月"。
  int get _cachePeriodValue => kCoverCachePeriodDays.contains(_draft.coverCacheMaxAgeDays)
      ? _draft.coverCacheMaxAgeDays
      : 30;

  /// 观看记录保留档位：草稿里是脏值时回落到**现在的默认**（0 = 不删除，第三十三轮）。
  int get _historyRetentionValue =>
      kHistoryRetentionDays.contains(_draft.historyRetentionDays)
      ? _draft.historyRetentionDays
      : 0;

  String _historyRetentionLabel(int days) => switch (days) {
    0 => '不删除',
    30 => '30 天',
    90 => '90 天',
    _ => '$days 天',
  };

  String _cachePeriodLabel(int days) => switch (days) {
    0 => '不清除',
    30 => '一个月',
    90 => '三个月',
    _ => '$days 天',
  };

  String get _cacheUsageLabel => _cacheUsage.files == 0
      ? '暂无缓存'
      : '${formatBytes(_cacheUsage.bytes)} · ${_cacheUsage.files} 张';

  Future<void> _loadCacheUsage() async {
    final Directory? support = ref.read(supportDirProvider);
    if (support == null) return;
    final CoverCacheUsage usage = await coverCacheUsage(coverCacheDirOf(support));
    if (mounted) setState(() => _cacheUsage = usage);
  }

  /// KV 缓存占用（同步读，无需 await 文件系统）。
  void _loadHostCacheUsage() {
    final KeyValueStore store = ref.read(keyValueStoreProvider);
    setState(() => _hostCache = hostCacheUsage(store));
  }

  /// 缓存清理的二次确认（第四十二轮 UX #26）。
  ///
  /// 背景：设置页两颗「清空」（封面缓存 / 源缓存·番剧信息）以前都是**一点就走**，
  /// 而"周期 = 不清除"时的封面清理是**全量删除**。它们都能重建，所以对话框**不**说
  /// "不可恢复"（那是撒谎），只把真实代价摆出来：要重新联网下载。
  Future<bool> _confirmCacheClear({
    required String title,
    required String body,
  }) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: Text(
          body,
          style: TextStyle(
            color: context.ds.text2,
            fontSize: kSettingsBodySize,
            height: 1.5,
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// 「清空其它缓存」：源缓存 + 推荐 + 番剧信息。这些条目随时会重建（下次抓取/下次看番），
  /// 所以这里**不问周期、直接清空** —— 用户点了按钮就是要腾地方。
  ///
  /// 第四十二轮 UX #11：`_busyCache` 原来只在成功路径上被放回 false，而两处 await
  /// 都没有 try —— 清理抛异常（Hive 写失败 / 封面目录被占用）时这个标志**永远是 true**：
  /// 两颗按钮一起变灰、标签卡在「清理中…」，直到重启程序，而且一句错误都没有。
  /// 现在统一 try/finally 收口 + 失败走底部条。
  Future<void> _clearHostCacheNow() async {
    // 第四十二轮 UX #26：先问一句。两颗「清空」以前都是一点就走，而这里删掉的
    // 是"上次抓到的结果"——代价是下次抓取要重新联网（慢/费流量），说清楚再动手。
    final bool ok = await _confirmCacheClear(
      title: '清空源缓存 / 番剧信息？',
      body: '这些条目是"上次抓到的结果"。删掉之后，下一次搜索、下一次看番详情要重新联网取一遍'
          '（慢一点、费点流量）。设置、观看记录、已下载的文件都不受影响。',
    );
    if (!ok || !mounted) return;
    setState(() => _busyCache = true);
    try {
      final int removed = await clearHostCache(ref.read(keyValueStoreProvider));
      if (!mounted) return;
      _loadHostCacheUsage();
      _setNote(removed == 0 ? '没有需要清理的缓存' : '已清掉 $removed 条缓存（下次抓取会重建）');
    } catch (error, stackTrace) {
      if (!mounted) return;
      // 失败走统一反馈通道（SnackBar），**不**塞进 `_applyFailure`：那一位是
      // "设置没生效"专用，底部条上它还会压过「有未保存的改动」提示。
      showFailure(context, describeFailure(error, stackTrace: stackTrace));
    } finally {
      if (mounted) setState(() => _busyCache = false);
    }
  }

  /// 「立即清理」：周期为 0（不清除）时=**清空**（用户明确点了按钮就是要腾地方）。
  Future<void> _sweepCoverCacheNow() async {
    final Directory? support = ref.read(supportDirProvider);
    if (support == null) {
      _setNote('应用支持目录未注入，无法清理封面缓存');
      return;
    }
    final int days = _cachePeriodValue;
    // 第四十二轮 UX #26：周期是「不清除」时这一下是**全量删除**（把已经下过的封面
    // 全清掉），必须问一句；周期 > 0 时只清过期的，那是它本来的日常动作，不打扰。
    if (days == 0) {
      final bool ok = await _confirmCacheClear(
        title: '清空全部封面缓存？',
        body: '周期设成「不清除」时，这颗按钮等于把已经下载过的封面**全部删掉**。'
            '下次进首页 / 搜索页会重新下载它们（费流量，但能长回来）。',
      );
      if (!ok || !mounted) return;
    }
    setState(() => _busyCache = true);
    try {
      final CoverCacheSweep sweep = await sweepCoverCache(
        coverCacheDirOf(support),
        maxAge: days == 0 ? null : Duration(days: days),
      );
      // ⭐ 第三十七轮：清完之后**必须**把封面缓存的内存索引也丢掉 ——
      // 索引里存的是"盘上那个文件"，文件刚被删掉时再把它交出去，`Image.file` 会走到
      // errorBuilder（那一格变灰框）直到下次下载。丢空之后下一次显示会重新探盘/重下。
      _refreshCoverCacheIndex();
      if (!mounted) return;
      await _loadCacheUsage();
      if (!mounted) return;
      _setNote(
        sweep.deleted == 0
            ? '没有需要清理的封面缓存'
            : '已清理 ${sweep.deleted} 张封面，释放 ${formatBytes(sweep.bytes)}',
      );
    } catch (error, stackTrace) {
      if (!mounted) return;
      showFailure(context, describeFailure(error, stackTrace: stackTrace));
    } finally {
      if (mounted) setState(() => _busyCache = false);
    }
  }

  /// 丢掉封面缓存的内存索引（第三十七轮）。
  ///
  /// 端口是 `CoverCachePort`，只有真实实现 `HttpCoverCache` 有索引；测试里的假实现
  /// 没有，所以这里按类型判一下 —— 设置页不该依赖具体实现，但"清完缓存顺手清索引"
  /// 这件事只有真实实现需要。
  void _refreshCoverCacheIndex() {
    final CoverCachePort cache = ref.read(coverCacheProvider);
    if (cache is HttpCoverCache) cache.invalidate();
  }

  /// 区块内的小标题（与 DsSection 的标题层级区分开）。
  ///
  /// 第二十五轮：加一条 2px 的浅色竖条 —— 它和「分组大标题（数字徽标）」「区块标题
  /// （强调色竖条）」一起构成本页的**三级层次**，不再是"全是同样粗细的字"。
  Widget _blockLabel(DsTokens t, String text) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Container(
        width: 2,
        height: 12,
        decoration: BoxDecoration(
          color: t.line,
          borderRadius: BorderRadius.circular(t.radiusPill),
        ),
      ),
      const SizedBox(width: 6),
      Text(
        text,
        style: TextStyle(
          color: t.text2,
          fontSize: kSettingsSecondarySize,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    ],
  );

  /// 分组大标题（第二十五轮）：把 7 个区块分成 3 组，一眼看出「这页分三段」。
  ///
  /// 数字徽标 + 粗标题 + 一句灰字提示；组与组之间靠上面那段 `spacing * 3` 的留白分开
  /// （第二十六轮 2.5 → 3：字号收小之后，留白得再松一点才不会又挤成一坨）。
  ///
  /// 第五十二轮（用户 2026-10-17「整个项目太素」）：设置页的**页面身份色 = 石板灰**
  /// （`hueOfTab(ShellTab.settings)` 也是 slate，见 `widgets/hues.dart`）——
  /// 侧栏「设置」图标、页名竖条已经用上它，这里把三个分组序号徽标也染成同一个色，
  /// 整页的"骨架"就先带上设置页的颜色；区块各自的色相再往下分（见下面每个 `DsSection`）。
  Widget _groupHeader(DsTokens t, int index, String title, String hint) => Padding(
    padding: EdgeInsets.fromLTRB(t.spacing * 2, t.spacing * 3, t.spacing * 2, 0),
    child: Row(
      children: <Widget>[
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: t.hueSoft(DsHue.slate),
            borderRadius: BorderRadius.circular(t.radiusControl * 0.6),
          ),
          child: Text(
            '$index',
            style: TextStyle(
              color: t.hueInk(DsHue.slate),
              fontSize: kSettingsCaptionSize,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 9),
        Text(
          title,
          style: TextStyle(
            color: t.text,
            fontSize: kSettingsBodySize,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            hint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: t.text3, fontSize: kSettingsCaptionSize),
          ),
        ),
      ],
    ),
  );

  /// 上次一键更新的逐来源结果（留在区块里看得见，不只闪一条 SnackBar）。
  String? _trackerNote;

  /// 多来源抓取服务（并发 + 合并去重 + 全部失败回落离线快照）。
  ///
  /// ⚠️ 逻辑**不在这页里**：每日自动刷新（`state/tracker_refresh.dart` 的
  /// `refreshTrackersAtStartup`）走的是同一个服务。这里再抄一份必然会跑偏
  /// （一边改了超时/去重规则、另一边没有）。
  final TrackerRefreshService _trackerService = TrackerRefreshService();

  /// 一键更新 tracker：把**来源清单里的每一条**都拉下来，合并去重后写入设置。
  ///
  /// 用户 2026-10-10 的清单要求参照 BitComet（best 列表）；2026-10-11 追加
  /// 「可以通过导入 URL 获取里面的所有 tracker，也可以使用多条获取」——
  /// 遍历 [_draft].trackerSourceUrls（默认 best 一条），逐条 8s 超时、整轮 20s 上限，
  /// 结果按来源顺序合并去重；**全部失败**才回落到仓库里的离线快照，
  /// 并逐条说明哪个来源为什么没拿到（不假装成功）。
  Future<void> _updateTrackersFromSources() async {
    final List<String> urls = normalizeTrackerSourceUrls(_draft.trackerSourceUrls);
    setState(() => _busyTracker = true);
    final TrackerListResult result = await _trackerService.fetchTrackerList(urls);
    if (!mounted) return;
    final bool fellBack = !result.fetchedFromSources;
    setState(() {
      _busyTracker = false;
      _draft = _draft.copyWith(
        trackerSourceUrls: urls,
        extraTrackers: result.text,
        // ⚠️ 回落快照**不**更新 trackerListUpdatedAt：写成就等于"今天更新过了"，
        // 每日自动刷新会白等一天（见 `state/tracker_refresh.dart` 的说明）。
        // 手动点按钮时把内置快照写进 extraTrackers 是刻意的：用户点了就要有东西可用。
        trackerListUpdatedAt: fellBack ? _draft.trackerListUpdatedAt : DateTime.now(),
      );
      _trackerNote = result.note;
    });
    _setNote(
      fellBack
          ? '联网更新失败，已用内置离线列表（点「保存并生效」写入引擎；时间戳未动，之后会自动重试）'
          : '已更新 ${result.trackers.length} 个 tracker（记得点「保存并生效」）',
    );
  }

  /// 「加一个来源」：校验 → 去重 → 进草稿（保存时落盘）。
  void _addTrackerSource(String raw) {
    final String value = raw.trim();
    if (!isTrackerSourceUrl(value)) {
      _setTrackerNote('不是可用的 http(s) 链接：$value');
      return;
    }
    final List<String> next = normalizeTrackerSourceUrls(<String>[
      ..._draft.trackerSourceUrls,
      value,
    ]);
    if (next.length == _draft.trackerSourceUrls.length) {
      _setTrackerNote('这个来源已经在清单里了');
      return;
    }
    setState(() {
      _draft = _draft.copyWith(trackerSourceUrls: next);
      _newTrackerUrl.clear();
      _trackerNote = '已加上来源（点「保存并生效」后长期有效）';
    });
  }

  void _removeTrackerSource(String url) {
    setState(() {
      _draft = _draft.copyWith(
        trackerSourceUrls: <String>[
          for (final String u in _draft.trackerSourceUrls)
            if (u != url) u,
        ],
      );
      _trackerNote = '已移除来源：${trackerSourceLabel(url)}';
    });
  }

  /// 只写区块内的小字说明（不占用顶部成功/失败横幅）。
  void _setTrackerNote(String note) {
    if (!mounted) return;
    setState(() => _trackerNote = note);
  }

  @override
  void initState() {
    super.initState();
    _baseline = ref.read(settingsProvider);
    _draft = _baseline;
    // 把自己登记给「切页 / 关窗」那两个入口（见 `state/settings_guard.dart`）。
    final ValueNotifier<SettingsDraftGuard?> holder = ref.read(settingsDraftGuardProvider);
    _guardHolder = holder;
    _guard = SettingsDraftGuard(dirty: () => _dirty, resolve: _resolveUnsaved);
    holder.value = _guard;
    // 封面缓存占用（第 7 项）：进页面时数一次，清理后再数一次。
    unawaited(_loadCacheUsage());
    // KV 缓存占用（源缓存 / 推荐 / 番剧信息）：同步读，进页面数一次。
    _loadHostCacheUsage();
  }

  @override
  void dispose() {
    // 只摘掉**自己注册的那一份**（身份比较）：换页重建/热重载时不会误清别人的。
    if (identical(_guardHolder?.value, _guard)) _guardHolder?.value = null;
    _newExclude.dispose();
    _newTrackerUrl.dispose();
    super.dispose();
  }

  /// 页面是不是"脏"的 = 草稿和**它的起点**不一样。
  ///
  /// 刻意不跟"现在的已保存值"比：后台（第 15 轮的搜索页勾选、每日 tracker 刷新）写设置时，
  /// 那种差异**不是用户在改**，不该让底部条突然显示"有未保存的改动"。
  bool get _dirty => !settingsEqual(_draft, _baseline);

  /// 上一次**渲染**时底部条显示的脏状态（[_touchDraft] 靠它决定要不要重建）。
  bool _dirtyShown = false;

  /// 草稿被**程序化**整份替换的次数（保存成功 / 撤销改动 / 导入配置 / 后台对齐）。
  ///
  /// 这一页 13 个文本输入框是 `TextFormField(initialValue:)`（没有 controller），而 Flutter
  /// 只在 **controller 实例变化**时才把 `initialValue` 同步到屏幕上
  /// （`_TextFormFieldState.didUpdateWidget`；`FormFieldState.didUpdateWidget` 也不看
  /// initialValue）。于是上面那几条程序化改草稿的路径全都改不动屏幕：底部条说
  /// 「已保存 / 已还原 / 已导入到草稿」，框里还是旧字 —— 用户没法核对，接着打字还会把
  /// 新值悄悄改回旧值。把这个计数编进输入框的 `key`（见 [_fieldKey]）：key 变了 = 重建
  /// 这个 FormField 的 State = 重新按 `initialValue` 建 controller。
  /// 用户打字**不会**走到这里（`onChanged` 只动草稿，不碰这个计数）。
  int _draftRevision = 0;

  /// 数字输入框当前的错误提示（键 = 字段名；空 = 这个框是合法的）。
  ///
  /// 第四十二轮 UX #12：旧实现每个数字框都是 `int.tryParse(v.trim()) ?? 0` ——
  /// 框里还显示着你打的字，草稿里已经**悄悄换成了别的数字**（清空 ⇒ 上传/下载限速
  /// 变 0 = 「不限速」；`?? 86400` 那种更隐蔽）。用户不可能发现，保存后行为却变了。
  /// 现在：解析不出来就**不写进草稿**、框下标红说明 ——「框里显示的字」与
  /// 「点保存会写下去的值」永远一致。
  final Map<String, String> _fieldErrors = <String, String>{};

  /// 草稿被**程序化整份替换**（保存成功 / 撤销 / 导入 / 后台对齐）：
  /// 输入框要按 `initialValue` 重建（见 [_draftRevision]），数字框的错误提示同时作废 ——
  /// 那条错误说的是"旧那份草稿里的字"，留着只会让人以为新值也有问题。
  void _bumpDraftRevision() {
    _draftRevision++;
    _fieldErrors.clear();
  }

  /// 草稿被改了、但**没有** `setState` 的地方喊一声（这一页 13 个输入框的 `onChanged`）。
  ///
  /// 为什么这些地方刻意不 setState：它们是 `TextFormField`，每敲一下就重铺整页既浪费、
  /// 也容易把正在编辑的输入框弄出别扭的跳动（老代码为此专门注释过）。但第十六轮把
  /// **自动保存**去掉之后，"脏没脏"只由 build 读 —— 没人重建就意味着底部条一直写着
  /// 「设置已保存」、按钮一直是灰的，用户改完却点不动保存。
  ///
  /// 所以这里只在**状态真的翻了**（净→脏）时重建一次，不是每次按键都重建；
  /// 它**只刷新界面**，绝不写盘、绝不生效 —— 保存永远只发生在用户点按钮的时候。
  void _touchDraft() {
    if (_dirty == _dirtyShown) return;
    setState(() {});
  }

  /// 保存并生效。
  ///
  /// 三步顺序（诚实原则）：**先落盘** → 再让边车/源客户端生效 → 生效失败就明说。
  /// 写下去的那份不是草稿本身，而是 [mergeDraftForSave] 合成的"用户改动 + 现在的已保存值"。
  Future<void> _save() async {
    if (_saving) return;
    final AppSettings payload = mergeDraftForSave(
      baseline: _baseline,
      draft: _draft,
      current: ref.read(settingsProvider),
    );
    setState(() {
      _saving = true;
      _applyFailure = null;
      _applySuccess = null;
    });
    DsFailure? failure;
    bool persisted = false;
    try {
      try {
        await ref.read(settingsProvider.notifier).replace(payload);
        persisted = true;
      } catch (error, stackTrace) {
        // 落盘失败：**什么都不算数** —— 不下发引擎（否则边车用着一份重启后就消失的设置），
        // 草稿保持脏（用户能重试或撤销），底部条用失败横幅说明原因。
        failure = describeFailure(error, stackTrace: stackTrace);
      }
      if (persisted) {
        if (!mounted) return;
        // 落盘之后草稿的起点跟着走：底部条立刻回到"设置已保存"。
        setState(() {
          _baseline = payload;
          _draft = payload;
          _bumpDraftRevision(); // 屏幕上的 13 个输入框要跟着吃一遍新值
        });
        try {
          await ref.read(lifecyclePortProvider).applySettings(payload);
        } catch (error, stackTrace) {
          failure = describeFailure(error, stackTrace: stackTrace);
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _applyFailure = failure;
          // 成功文案的前提是**真的落盘了**且一切顺利：落盘失败却说"已保存"就是静默假成功。
          _applySuccess = (persisted && failure == null)
              ? '设置已保存并已生效（边车/源客户端已按新参数重建）'
              : null;
        });
      }
    }
  }

  /// 丢掉草稿上的改动，回到"现在的已保存值"（不落盘、不生效）。
  void _discard() {
    final AppSettings current = ref.read(settingsProvider);
    setState(() {
      _draft = current;
      _baseline = current;
      _bumpDraftRevision(); // 输入框里的字也要一起回到已保存那份
      _applyFailure = null;
      _applySuccess = null;
    });
  }

  /// 「要离开设置页了」时被 [resolveUnsavedSettings] 回调：问三选并照做。
  ///
  /// 返回 true = 可以走（已保存或已放弃）；false = 留在设置页。
  Future<bool> _resolveUnsaved(BuildContext context) async {
    final _UnsavedChoice? choice = await showDialog<_UnsavedChoice>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('设置有未保存的改动'),
        content: Text(
          '这一页改过的东西还没有写进去（设置不会自动保存）。\n'
          '现在就走的话：可以顺手保存并生效，或者丢掉这些改动。',
          style: TextStyle(color: context.ds.text2, fontSize: kSettingsBodySize, height: 1.5),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(_UnsavedChoice.stay),
            child: const Text('留在这'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(_UnsavedChoice.discard),
            child: const Text('放弃改动'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_UnsavedChoice.save),
            child: const Text('保存并生效'),
          ),
        ],
      ),
    );
    switch (choice) {
      case _UnsavedChoice.save:
        await _save();
        // 落盘成功 → 草稿不再脏；**生效失败**（_applyFailure != null）也要留下 ——
        // 放行走了的话，那条"为什么没生效"的横幅用户永远看不到，注释里的承诺就落空了。
        return !_dirty && _applyFailure == null;
      case _UnsavedChoice.discard:
        _discard();
        return true;
      case _UnsavedChoice.stay:
      case null:
        return false;
    }
  }

  /// 页头「⋯」菜单：导出/导入配置与导出诊断包（原「迁移与诊断」分组的内容）。
  Future<void> _runDiag(_DiagAction action) async {
    switch (action) {
      case _DiagAction.exportConfig:
        await runGuarded(
          context,
          action: () async {
            final String path = await exportConfigTo(ref.read(pickerPortProvider), _draft);
            _setNote('配置已导出：$path');
          },
        );
      case _DiagAction.importConfig:
        await runGuarded(
          context,
          action: () async {
            final AppSettings imported = await importConfigFrom(ref.read(pickerPortProvider));
            // 导入 = 整份草稿被换掉：13 个输入框（没有 controller）必须重建才吃得上新值，
            // 否则屏幕上还是旧配置，用户根本没法核对刚导入了什么。
            setState(() {
              _draft = imported;
              _bumpDraftRevision();
            });
            _setNote('配置已导入到草稿：确认无误后点「保存并生效」；想撤销就点「撤销改动」');
          },
        );
      case _DiagAction.exportDiagnostics:
        await runGuarded(
          context,
          action: () async {
            final String path = await exportDiagnosticsTo(
              ref.read(pickerPortProvider),
              settings: _draft,
              engineStatus: ref.read(engineStatusProvider).label,
              supportDir: ref.read(supportDirProvider),
              notes: <String>[
                '可用源：${ref.read(sourceOptionsProvider).length} 个',
                '边车：${ref.read(engineBootstrapProvider).running ? '已连接' : '未连接'}',
              ],
            );
            _setNote('诊断包已导出：$path');
          },
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final EngineBootstrapState engine = ref.watch(engineBootstrapProvider);    final DirectorySupport sup = DirectorySupport.of(ref);

    // 后台**别的**写者改了设置（第 15 轮的搜索页勾选、每日 tracker 刷新、首启向导）：
    // 页面是干净的时候跟着走，草稿与起点一起对齐 —— 否则这一页显示的还是旧值，却写着
    // "设置已保存"，那是撒谎。脏的时候**不动草稿**（用户在改的东西不能被别人覆盖），
    // 保存时由 `mergeDraftForSave()` 保证没碰过的字段仍用后台那份。
    ref.listen<AppSettings>(settingsProvider, (AppSettings? previous, AppSettings next) {
      if (_dirty) return;
      if (mounted) {
        setState(() {
          _baseline = next;
          _draft = next;
          _bumpDraftRevision(); // 干净时对齐后台那份 → 输入框里的字也得跟着变
        });
      }
    });

    final bool dirty = _dirty;
    _dirtyShown = dirty; // 供 _touchDraft() 比较（见那里的说明）
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: ListView(
            padding: EdgeInsets.only(bottom: t.spacing),
            children: <Widget>[
              // 用户 2026-10-10 第 3 轮问答：「迁移与诊断」收进页头一个「⋯」菜单
              //（导出/导入配置、导出诊断包不常点，但出事时必须找得到）。
              Align(
                alignment: Alignment.centerRight,
                child: PopupMenuButton<_DiagAction>(
                  tooltip: '迁移与诊断',
                  onSelected: _runDiag,
                  itemBuilder: (BuildContext context) => <PopupMenuEntry<_DiagAction>>[
                    const PopupMenuItem<_DiagAction>(
                      value: _DiagAction.exportConfig,
                      child: Text('导出配置'),
                    ),
                    const PopupMenuItem<_DiagAction>(
                      value: _DiagAction.importConfig,
                      child: Text('导入配置'),
                    ),
                    const PopupMenuItem<_DiagAction>(
                      value: _DiagAction.exportDiagnostics,
                      child: Text('导出诊断包（日志 + 配置）'),
                    ),
                  ],
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(t.spacing, 6, t.spacing, 0),
                    child: Icon(Icons.more_horiz, size: 18, color: t.text2),
                  ),
                ),
              ),
              // ── 第 ① 组：引擎 / 下载 / 网络 ─────────────────────────────────
              _groupHeader(t, 1, '引擎 · 下载 · 网络',
                  '边车参数、下载目录、代理与限速 —— 改完都要点「保存并生效」'),
              // 第五十二轮（用户 2026-10-17「整个项目太素」）：**每个区块一个色相 + 图标**。
              // 颜色在这里是信息编码（"这是哪一类设置"），不是装饰：同一色相在设置页的
              // 区块头、图标淡底、以及对应的页面/侧栏入口上指同一个东西；页内 9 个区块
              // 一一对应、互不撞色（12 色环取自 `theme/tokens.dart` 的 [DsHue]）。
              // 引擎 = 蓝（后台进程 / 端口，与侧栏「队列」同一个蓝，都是"机器在跑的东西"）。
              DsSection(
                title: '引擎（rqbit-engine 边车）',
                hue: DsHue.blue,
                icon: Icons.dns_outlined,
                subtitle: '拉起的进程参数：下载目录 · 限速 · 做种比 · tracker',
                trailing: const EngineStatusPill(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _row(<Widget>[
                      Expanded(
                        child: TextFormField(
                          key: _fieldKey('enginePath'),
                          initialValue: _draft.enginePath ?? '',
                          decoration: const InputDecoration(
                            labelText: 'rqbit-engine.exe 路径（留空 = 自动查找）',
                            hintText: r'F:\Ai\DSAnima\engine\target\release\rqbit-engine.exe',
                          ),
                          style: TextStyle(color: t.text, fontSize: kSettingsBodySize),
                          onChanged: (String v) {
                            // 清空 = "留空，自动查找"：必须用 clearEnginePath 才清得掉
                            // （`copyWith(enginePath: null)` 的语义是"不改"，见 models.dart）。
                            final bool empty = v.trim().isEmpty;
                            _draft = _draft.copyWith(
                              enginePath: empty ? null : v.trim(),
                              clearEnginePath: empty,
                            );
                            _touchDraft();
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final String? path = await ref
                              .read(pickerPortProvider)
                              .pickFile(title: '选择 rqbit-engine.exe', extensions: <String>['exe']);
                          if (path == null || !mounted) return;
                          setState(() => _draft = _draft.copyWith(enginePath: path));
                        },
                        icon: const Icon(Icons.folder_open, size: 16),
                        label: const Text('浏览…'),
                      ),
                    ]),
                    const SizedBox(height: 16),
                    _row(<Widget>[
                      Expanded(
                        child: TextFormField(
                          // 设置为空时**显示默认目录**（用户 2026-10-11：
                          // 「下载目录默认在 C:\Users\用户名\Downloads\Anime」）。
                          // 之前这里是空框 + 引擎实际会用别处的路径 ⇒ 「空着但实际会用默认路径」
                          // 的迷惑态；现在框里显示的就是**真正会用的那个目录**。
                          key: _fieldKey('downloadDir'),
                          initialValue: effectiveDownloadDir(_draft.downloadDir),
                          decoration: InputDecoration(
                            labelText: '下载目录（引擎启动参数）',
                            hintText: r'C:\Users\<用户名>\Downloads\Anime',
                            helperText: (_draft.downloadDir ?? '').trim().isEmpty
                                ? (resolveDefaultDownloadDir().isEmpty
                                    ? '未设置，且本机解析不出默认目录：请点「选择目录」或直接填路径'
                                    : '未设置（含清空输入框）→ 引擎用默认目录：'
                                        '${resolveDefaultDownloadDir()}')
                                : null,
                          ),
                          style: TextStyle(color: t.text, fontSize: kSettingsBodySize),
                          onChanged: (String v) {
                            // 清空 = 回到"未设置、用默认目录"：必须用 clearDownloadDir
                            // 才清得掉（`copyWith(downloadDir: null)` 的语义是"不改"）。
                            final bool empty = v.trim().isEmpty;
                            _draft = _draft.copyWith(
                              downloadDir: empty ? null : v.trim(),
                              clearDownloadDir: empty,
                            );
                            _touchDraft();
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final String? dir = await ref
                              .read(pickerPortProvider)
                              .pickDirectory(title: '选择下载目录');
                          if (dir == null || !mounted) return;
                          setState(() => _draft = _draft.copyWith(downloadDir: dir));
                        },
                        icon: const Icon(Icons.folder_open, size: 16),
                        label: const Text('选择目录'),
                      ),
                    ]),
                    const SizedBox(height: 16),
                    _row(<Widget>[
                      Expanded(
                        child: TextFormField(
                          key: _fieldKey('extraTrackers'),
                          initialValue: _draft.extraTrackers,
                          decoration: const InputDecoration(
                            labelText: '追加公共 tracker（逗号分隔，留空用内置列表）',
                          ),
                          style: TextStyle(color: t.text, fontSize: kSettingsBodySize),
                          onChanged: (String v) {
                            _draft = _draft.copyWith(extraTrackers: v);
                            _touchDraft();
                          },
                        ),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        FilledButton.icon(
                          onPressed: engine.busy
                              ? null
                              : () async {
                                  final Directory? dir = ref.read(supportDirProvider);
                                  if (dir == null) return;
                                  await ref
                                      .read(engineBootstrapProvider.notifier)
                                      .start(settings: _draft, supportDir: dir);
                                  if (!context.mounted) return;
                                  ref.invalidate(engineHealthProvider);
                                  ref.invalidate(engineTorrentsProvider);
                                },
                          icon: const Icon(Icons.play_arrow, size: 16),
                          label: Text(engine.running ? '重启引擎' : '启动引擎'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () async {
                            ref.invalidate(engineHealthProvider);
                            await ref.read(engineHealthProvider.future);
                            if (!context.mounted) return;
                            final AsyncValue<EngineHealthView> health = ref.read(
                              engineHealthProvider,
                            );
                            final Object? error = health.error;
                            await showDialog<void>(
                              context: context,
                              builder: (BuildContext context) => AlertDialog(
                                title: const Text('引擎连通测试'),
                                content: error != null
                                    ? DsErrorPanel(failure: describeFailure(error))
                                    : Text(
                                        'GET /health 成功：'
                                        'v${health.value?.version ?? '?'} · '
                                        '会话 ${health.value?.sessions ?? 0}',
                                        style: TextStyle(color: t.text, fontSize: kSettingsBodySize),
                                      ),
                                actions: <Widget>[
                                  TextButton(
                                    onPressed: () => Navigator.of(context).pop(),
                                    child: const Text('关闭'),
                                  ),
                                ],
                              ),
                            );
                          },
                          icon: const Icon(Icons.network_check, size: 16),
                          label: const Text('测试连通'),
                        ),
                        OutlinedButton.icon(
                          onPressed: engine.running
                              ? () => ref.read(engineBootstrapProvider.notifier).stop()
                              : null,
                          icon: const Icon(Icons.stop, size: 16),
                          label: const Text('停止引擎'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (engine.busy) const DsLoading(label: '正在拉起边车进程…'),
                    if (engine.error != null)
                      DsBanner(
                        kind: DsBannerKind.error,
                        text: '${engine.error}｜怎么办：${engine.errorHint ?? '—'}',
                      ),
                    if (engine.running)
                      DsBanner(
                        kind: DsBannerKind.success,
                        text:
                            '引擎进程已就绪'
                            '${engine.exePath == null ? '' : '：${engine.exePath}'}'
                            '${engine.lastStartup == null ? '' : '（启动耗时 ${engine.lastStartup!.inMilliseconds} ms）'}',
                      ),
                    if (sup.path != null) ...<Widget>[
                      const SizedBox(height: 12),
                      SelectableText(
                        '边车日志：${sup.path}\\engine\\engine.log',
                        style: TextStyle(color: t.textDim, fontSize: kSettingsSecondarySize),
                      ),
                    ],
                  ],
                ),
              ),
              // 网络 / 代理 / 限速 = 青（搜索页也是青：这一组管的就是"往外抓东西"）。
              DsSection(
                title: '网络 · 限速 · 做种',
                hue: DsHue.cyan,
                icon: Icons.wifi,
                subtitle:
                    '代理只作用于源抓取（nyaa/mikan/RSS）；限速与做种比是边车启动参数'
                    '（0 = 不限），改完需「保存并生效」',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _row(<Widget>[
                      SizedBox(
                        width: 190,
                        child: DropdownButtonFormField<ProxyMode>(
                          initialValue: _draft.proxyMode,
                          decoration: const InputDecoration(labelText: '代理模式'),
                          isExpanded: true,
                          dropdownColor: t.surfaceAlt,
                          // ⚠️ 第四十六轮（用户：「优化一些框里字太大的问题，
                          // 比如默认源 代理模式」）：这里**必须**显式给字号 ——
                          // `DropdownButton` 不给 style 就吃 `textTheme.titleMedium`
                          // （本站 = 17 + w600），于是这一格比同一行的输入框（13）大一圈，
                          // 出图见 `build/probe-size/S_settings_network.png`。
                          // `dsControlTextStyle` 同时把字体族带上（这个 style 不与主题
                          // merge，裸写 `TextStyle(...)` 会掉回系统默认字体）。
                          style: dsControlTextStyle(t, fontSize: kSettingsBodySize),
                          // 箭头跟着字一起收（Material 默认 24，比 13 的字高一倍）。
                          iconSize: 18,
                          items: <DropdownMenuItem<ProxyMode>>[
                            for (final ProxyMode mode in ProxyMode.values)
                              DropdownMenuItem<ProxyMode>(value: mode, child: Text(mode.label)),
                          ],
                          onChanged: (ProxyMode? value) => setState(
                            () => _draft = _draft.copyWith(proxyMode: value ?? ProxyMode.none),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 200,
                        child: TextFormField(
                          key: _fieldKey('proxyHost'),
                          initialValue: _draft.proxyHost,
                          decoration: const InputDecoration(labelText: '代理主机'),
                          style: TextStyle(color: t.text, fontSize: kSettingsBodySize),
                          onChanged: (String v) {
                            _draft = _draft.copyWith(proxyHost: v.trim());
                            _touchDraft();
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      _numberField(
                        t,
                        name: 'proxyPort',
                        value: _draft.proxyPort,
                        label: '端口',
                        width: 110,
                        onChanged: (num v) => _draft =
                            _draft.copyWith(proxyPort: v.toInt()),
                      ),
                    ]),
                    const SizedBox(height: 16),
                    _row(<Widget>[
                      Expanded(
                        child: TextFormField(
                          key: _fieldKey('proxyUsername'),
                          initialValue: _draft.proxyUsername,
                          decoration: const InputDecoration(labelText: '代理用户名（可选）'),
                          style: TextStyle(color: t.text, fontSize: kSettingsBodySize),
                          onChanged: (String v) {
                            _draft = _draft.copyWith(proxyUsername: v.trim());
                            _touchDraft();
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextFormField(
                          key: _fieldKey('proxyPassword'),
                          initialValue: _draft.proxyPassword,
                          obscureText: true,
                          decoration: const InputDecoration(labelText: '代理密码（可选）'),
                          style: TextStyle(color: t.text, fontSize: kSettingsBodySize),
                          onChanged: (String v) {
                            _draft = _draft.copyWith(proxyPassword: v);
                            _touchDraft();
                          },
                        ),
                      ),
                    ]),
                    const SizedBox(height: 16),
                    _row(<Widget>[
                      _numberField(
                        t,
                        name: 'sourceRequestIntervalMs',
                        value: _draft.sourceRequestIntervalMs,
                        label: '每 host 最小请求间隔（毫秒）',
                        width: 240,
                        onChanged: (num v) => _draft = _draft.copyWith(
                          sourceRequestIntervalMs: v.toInt(),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _numberField(
                        t,
                        name: 'sourceCacheTtlSeconds',
                        value: _draft.sourceCacheTtlSeconds,
                        label: '源缓存 TTL（秒，搜索/最新）',
                        width: 240,
                        onChanged: (num v) => _draft = _draft.copyWith(
                          sourceCacheTtlSeconds: v.toInt(),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _numberField(
                        t,
                        name: 'sourceDetailCacheTtlSeconds',
                        value: _draft.sourceDetailCacheTtlSeconds,
                        label: '详情缓存 TTL（秒）',
                        width: 220,
                        onChanged: (num v) => _draft = _draft.copyWith(
                          sourceDetailCacheTtlSeconds: v.toInt(),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    _sourcePicker(context),
                    const SizedBox(height: 12),
                    _searchModePicker(context),
                    // ── 用户 2026-10-10 第 2 轮问答：「网络与源抓取」+「限速与做种」
                    // 合成一组（8 组 → 7 组）。两件事都是"网络这一侧怎么跑"。
                    const SizedBox(height: 16),
                    Divider(height: 1, color: t.divider),
                    const SizedBox(height: 14),
                    _row(<Widget>[
                      _numberField(
                        t,
                        name: 'uploadLimitKbps',
                        value: _draft.uploadLimitKbps,
                        label: '上传限速 (KB/s)',
                        onChanged: (num v) =>
                            _draft = _draft.copyWith(uploadLimitKbps: v.toInt()),
                      ),
                      const SizedBox(width: 10),
                      _numberField(
                        t,
                        name: 'downloadLimitKbps',
                        value: _draft.downloadLimitKbps,
                        label: '下载限速 (KB/s，0 = 不限速)',
                        onChanged: (num v) => _draft =
                            _draft.copyWith(downloadLimitKbps: v.toInt()),
                      ),
                      const SizedBox(width: 10),
                      _numberField(
                        t,
                        name: 'seedRatio',
                        value: _draft.seedRatio,
                        label: '做种比（达到该比例后自动暂停；0 = 不按比例停）',
                        width: 220,
                        integer: false,
                        onChanged: (num v) =>
                            _draft = _draft.copyWith(seedRatio: v.toDouble()),
                      ),
                    ]),
                  ],
                ),
              ),
              // ── 第 ② 组：观感与资源占用 ──────────────────────────────────────
              _groupHeader(t, 2, '外观 · 省流量 · 缓存',
                  '界面观感、预热与省流量规则、封面/源缓存什么时候清'),
              // 外观 / 主题 = 紫（8 套色表本身就是"换颜色"，用色环里最像"调色盘"的一档）。
              // ⚠️ 外观选择器（`NeoAppearancePicker` 的 8 张卡）本身已有色，保持不动。
              DsSection(
                title: '外观',
                hue: DsHue.violet,
                icon: Icons.palette_outlined,
                subtitle: '8 套内置手调色表（无自定义编辑器）· **点一下立刻生效并保存**'
                    '（第三十三轮起不再需要点「保存并生效」）',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    NeoAppearancePicker(
                      keyPrefix: 'settings-appearance',
                      value: DsAppearance.fromCode(_draft.themeId),
                      onChanged: (DsAppearance a, Offset origin) =>
                          unawaited(_pickAppearance(a, origin)),
                    ),
                    _segmentedRow<DsCoverSize>(
                      t,
                      '封面大小',
                      '只影响「今日更新」网格的封面宽度：小 172 / 中 208 / 大 250',
                      DsCoverSize.values,
                      DsCoverSize.fromCode(_draft.homeCoverSize),
                      (DsCoverSize v) => setState(
                        () => _draft = _draft.copyWith(homeCoverSize: v.code),
                      ),
                    ),
                    _segmentedRow<DsCarouselShape>(
                      t,
                      '轮播封面',
                      '横版 = 现状（3:2，竖海报会裁掉上下）；竖版 = 按海报比例，整张封面看得全',
                      DsCarouselShape.values,
                      DsCarouselShape.fromCode(_draft.carouselShape),
                      (DsCarouselShape v) => setState(
                        () => _draft = _draft.copyWith(carouselShape: v.code),
                      ),
                    ),
                    _segmentedRow<DsCarouselSize>(
                      t,
                      '轮播大小',
                      '主卡 + 两侧邻卡 + 整块高度一起等比：小 0.85 / 中 1.2（默认）/ 大 1.5（第三十二轮上移一档）',
                      DsCarouselSize.values,
                      DsCarouselSize.fromCode(_draft.carouselSize),
                      (DsCarouselSize v) => setState(
                        () => _draft = _draft.copyWith(carouselSize: v.code),
                      ),
                    ),
                  ],
                ),
              ),
              // 省流量 / 缓存 = 水绿（"省"这一族：预热、排除规则、封面缓存清理）。
              DsSection(
                title: '省流量策略',
                hue: DsHue.teal,
                icon: Icons.data_saver_on,
                subtitle: '预热档位（默认关）+ 做种/删除；对应「设置里加入省流量列表」：'
                    '命中的番剧/规则一律不预热',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _segmentedRow<DsPreheatAhead>(
                      t,
                      '提前预热后几集',
                      '默认「关」：起播时只下正在看的那一集。选 1–3 集后，**起播那一刻**就把'
                          '后面几集加进队列开始下 —— 点「下一集」时种子已经在引擎里、'
                          '元数据早已就绪，不用再等「补磁力 → 等元数据」那一段'
                          '（第三十八轮：这一档是"让切集快"用的）。'
                          '代价说清楚：它是真下载，会提前吃带宽与磁盘；预热的那几集'
                          '**不受「并发下载数」限制**（那个数管的是用户任务），'
                          '所以档位越高、和正在看的那一集抢带宽越明显。',
                      DsPreheatAhead.values,
                      DsPreheatAhead.fromCount(_draft.bandwidth.preheatAhead),
                      (DsPreheatAhead v) => setState(
                        () => _draft = _draft.copyWith(
                          bandwidth: _draft.bandwidth.copyWith(preheatAhead: v.count),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _switchRow(
                      '播完/切集后停止做种',
                      '播放结束或切到下一集时对该 torrent pause()，不再上传',
                      _draft.bandwidth.stopSeedingAfterPlayback,
                      (bool v) => setState(
                        () => _draft = _draft.copyWith(
                          bandwidth: _draft.bandwidth.copyWith(stopSeedingAfterPlayback: v),
                        ),
                      ),
                    ),
                    _switchRow(
                      '播完删除已看文件',
                      '节省磁盘；删除后无法续播该集',
                      _draft.bandwidth.deleteAfterPlayed,
                      (bool v) => setState(
                        () => _draft = _draft.copyWith(
                          bandwidth: _draft.bandwidth.copyWith(deleteAfterPlayed: v),
                        ),
                      ),
                    ),
                    _switchRow(
                      '播完自动下一集',
                      '播放结束时自动播下一集（搜索页点播时会把同批结果里的后续集带上）',
                      _draft.autoPlayNext,
                      (bool v) => setState(() => _draft = _draft.copyWith(autoPlayNext: v)),
                    ),
                    const SizedBox(height: 16),
                    _row(<Widget>[
                      SizedBox(
                        width: 200,
                        child: DropdownButtonFormField<int>(
                          initialValue: _draft.bandwidth.maxConcurrent,
                          decoration: const InputDecoration(labelText: '并发下载数（1–3）'),
                          isExpanded: true,
                          dropdownColor: t.surfaceAlt,
                          style: dsControlTextStyle(t, fontSize: kSettingsBodySize),
                          iconSize: 18,
                          items: const <DropdownMenuItem<int>>[
                            DropdownMenuItem<int>(value: 1, child: Text('1')),
                            DropdownMenuItem<int>(value: 2, child: Text('2')),
                            DropdownMenuItem<int>(value: 3, child: Text('3')),
                          ],
                          onChanged: (int? value) => setState(
                            () => _draft = _draft.copyWith(
                              bandwidth: _draft.bandwidth.copyWith(maxConcurrent: value ?? 1),
                            ),
                          ),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 14),
                    Text(
                      '省流量列表（正则，命中即不预取）',
                      style: TextStyle(
                        color: t.text,
                        fontSize: kSettingsBodySize,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (_draft.bandwidth.excludePatterns.isEmpty)
                      Text(
                        '列表为空：所有番剧都参与预取',
                        style: TextStyle(color: t.textDim, fontSize: kSettingsSecondarySize),
                      ),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (final String pattern in _draft.bandwidth.excludePatterns)
                          InputChip(
                            label: Text(
                              pattern,
                              style: TextStyle(color: t.text, fontSize: kSettingsSecondarySize),
                            ),
                            backgroundColor: t.sunken,
                            // 无边框（硬边框已从全项目移除）；凹槽底 + 胶囊形状即足够。
                            side: BorderSide(color: Colors.transparent),
                            deleteIconColor: t.danger,
                            onDeleted: () => setState(
                              () => _draft = _draft.copyWith(
                                bandwidth: _draft.bandwidth.copyWith(
                                  excludePatterns: _draft.bandwidth.excludePatterns
                                      .where((String p) => p != pattern)
                                      .toList(growable: false),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _row(<Widget>[
                      Expanded(
                        child: TextField(
                          controller: _newExclude,
                          decoration: const InputDecoration(
                            labelText: '新增排除正则',
                            hintText: '例如：合集|总集篇|HEVC.*10bit',
                          ),
                          style: TextStyle(color: t.text, fontSize: kSettingsBodySize),
                          onSubmitted: (String value) => _addExclude(value),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: () => _addExclude(_newExclude.text),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('添加'),
                      ),
                    ]),
                    // 用户 2026-10-11 第二阶段清单第 7 项：封面缓存自动清理。
                    // 放在这一组是因为它同样是"资源占用"的取舍（省流量 / 省磁盘）。
                    const SizedBox(height: 14),
                    _blockLabel(t, '封面缓存'),
                    const SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        Text(
                          '自动清理',
                          style: TextStyle(color: t.text2, fontSize: kSettingsSecondarySize),
                        ),
                        const SizedBox(width: 8),
                        NeoDropdown<int>(
                          width: 132,
                          height: 30,
                          fontSize: kSettingsSecondarySize,
                          value: _cachePeriodValue,
                          tooltip: '什么时候自动清掉过期的封面图',
                          label: _cachePeriodLabel(_cachePeriodValue),
                          items: <NeoDropdownItem<int>>[
                            for (final int days in kCoverCachePeriodDays)
                              NeoDropdownItem<int>(days, _cachePeriodLabel(days)),
                          ],
                          onSelected: (int days) =>
                              setState(() => _draft = _draft.copyWith(coverCacheMaxAgeDays: days)),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          onPressed: _busyCache ? null : _sweepCoverCacheNow,
                          icon: const Icon(Icons.cleaning_services, size: 15),
                          label: Text(
                            _busyCache ? '清理中…' : (_cachePeriodValue == 0 ? '清空缓存' : '立即清理'),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          _cacheUsageLabel,
                          style: TextStyle(color: t.text3, fontSize: kSettingsSecondarySize),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // 用户 2026-10-11「不要没用的缓存」：源缓存/推荐/番剧信息这三处
                    // 以前**只涨不减**（core 只按 TTL 判读，条目从不删除），这里能看见、能清。
                    Row(
                      children: <Widget>[
                        Text(
                          '源缓存 / 番剧信息',
                          style: TextStyle(color: t.text2, fontSize: kSettingsSecondarySize),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          onPressed: _busyCache ? null : _clearHostCacheNow,
                          icon: const Icon(Icons.delete_outline, size: 15),
                          label: const Text('清空'),
                        ),
                        const Spacer(),
                        Text(
                          _hostCacheLabel,
                          style: TextStyle(color: t.text3, fontSize: kSettingsSecondarySize),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // ── 第 ③ 组：种子来源与后台 ──────────────────────────────────────
              _groupHeader(t, 3, 'tracker · 后台 · 做种',
                  '公共 tracker 从哪来、关掉主程序后还跑不跑'),
              // tracker 来源 = 靛（公共 tracker 是"一张网"：来源清单、一键更新、合并去重）。
              DsSection(
                title: 'tracker 来源',
                hue: DsHue.indigo,
                icon: Icons.public,
                subtitle: _draft.trackerListUpdatedAt == null
                    ? '还没更新过：引擎会用内置兜底列表'
                    : '上次更新：${formatDateTime(_draft.trackerListUpdatedAt)}',
                trailing: OutlinedButton.icon(
                  // 用户 2026-10-10：参照 BitComet —— 拉 ngosang 的 trackers_best.txt
                  // （社区每日更新）。2026-10-11：改成**把来源清单里每一条都拉下来**
                  // 合并去重，全部失败才回落离线快照。
                  onPressed: _busyTracker ? null : _updateTrackersFromSources,
                  icon: const Icon(Icons.system_update_alt, size: 15),
                  label: Text(
                    _busyTracker
                        ? '更新中…'
                        : '从 ${normalizeTrackerSourceUrls(_draft.trackerSourceUrls).length} 个来源更新',
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // ① 来源清单：一行一条，可删；来源之间并发拉取、结果合并去重。
                    for (final String url in _draft.trackerSourceUrls)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          children: <Widget>[
                            Icon(Icons.link, size: 14, color: t.text3),
                            const SizedBox(width: 8),
                            Expanded(
                              child: SelectableText(
                                url,
                                maxLines: 1,
                                style: TextStyle(color: t.text2, fontSize: kSettingsSecondarySize),
                              ),
                            ),
                            IconButton(
                              tooltip: '移除这个来源',
                              visualDensity: VisualDensity.compact,
                              icon: Icon(Icons.close, size: 15, color: t.text3),
                              onPressed: () => _removeTrackerSource(url),
                            ),
                          ],
                        ),
                      ),
                    if (_draft.trackerSourceUrls.isEmpty)
                      Text(
                        '（没有来源：一键更新只能用离线快照）',
                        style: TextStyle(color: t.text3, fontSize: kSettingsSecondarySize),
                      ),

                    // ② 加来源：粘贴 URL → 添加（校验 + 去重都在这儿拦）。
                    const SizedBox(height: 6),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: TextField(
                            controller: _newTrackerUrl,
                            decoration: const InputDecoration(
                              isDense: true,
                              labelText: '导入 tracker 列表 URL',
                              hintText: 'https://…/trackers_best.txt',
                            ),
                            style: TextStyle(color: t.text, fontSize: kSettingsBodySize),
                            onSubmitted: _addTrackerSource,
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: () => _addTrackerSource(_newTrackerUrl.text),
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('添加来源'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // ③ 常用来源：点一下就加进清单（不写死，用户可以删）。
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (final TrackerSourcePreset preset in trackerSourcePresets)
                          Tooltip(
                            message: '${preset.hint}\n${preset.url}',
                            child: ActionChip(
                              avatar: const Icon(Icons.add_link, size: 14),
                              label: Text(
                                preset.label,
                                style: TextStyle(fontSize: kSettingsSecondarySize),
                              ),
                              onPressed: () => _addTrackerSource(preset.url),
                            ),
                          ),
                      ],
                    ),

                    // ④ 上次更新结果（每个来源拿到多少条 / 为什么没拿到）。
                    if (_trackerNote != null) ...<Widget>[
                      const SizedBox(height: 12),
                      Text(
                        _trackerNote!,
                        style: TextStyle(
                          color: t.text2,
                          fontSize: kSettingsSecondarySize,
                          height: 1.5,
                        ),
                      ),
                    ],

                    // ⑤ 最终写入引擎的那份（默认只显示条数，要看全文再展开）。
                    const SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        Text(
                          _draft.extraTrackers.trim().isEmpty
                              ? '（留空 = 用引擎内置列表）'
                              : '已写入 ${parseTrackerList(_draft.extraTrackers).length} 个 tracker',
                          style: TextStyle(color: t.text2, fontSize: kSettingsSecondarySize),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => setState(() => _showTrackers = !_showTrackers),
                          child: Text(_showTrackers ? '收起' : '展开全文'),
                        ),
                      ],
                    ),
                    if (_showTrackers)
                      SelectableText(
                        _draft.extraTrackers.trim().isEmpty
                            ? '（留空 = 用引擎内置列表）'
                            : _draft.extraTrackers,
                        maxLines: 12,
                        style: TextStyle(
                          color: t.text2,
                          fontSize: kSettingsSecondarySize,
                          height: 1.5,
                        ),
                      ),
                  ],
                ),
              ),
              // 做种与后台 = 玫红（"把东西送出去 + 常驻"：做种、后台常驻、sukebei 开关）。
              DsSection(
                title: '做种与后台',
                hue: DsHue.rose,
                icon: Icons.cloud_upload_outlined,
                subtitle: '默认都不做种、不常驻（spec §7.1 Q2 / §7.3 Q14）',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _switchRow(
                      '开启做种',
                      '默认关：下完就由宿主 pause()，不再上传；开启后按下面的「做种比」做种'
                          '（上传限速两档都照旧生效）',
                      _draft.seedEnabled,
                      (bool v) => setState(
                        () => _draft = _draft.copyWith(
                          seedEnabled: v,
                          seedRatio: v ? (_draft.seedRatio == 0 ? 1.0 : _draft.seedRatio) : 0,
                        ),
                      ),
                    ),
                    _switchRow(
                      '后台常驻（关闭主程序后继续下载）',
                      trayHint,
                      _draft.backgroundResident,
                      (bool v) => setState(() => _draft = _draft.copyWith(backgroundResident: v)),
                    ),
                    _switchRow(
                      'nyaa 同时查 sukebei（默认关）',
                      // 第二十五轮：分区从「不限」改成 sukebei 自己的 **Art - Anime（1_1）**，
                      // 文案跟着说实话（以前写「全部分类」）。
                      'sukebei · 成人区 · 只搜动漫分区（Art - Anime，c=1_1）：'
                          '打开后多注册一个 sukebei 源，结果里用来源标记区分；关闭则不注册',
                      _draft.sukebeiEnabled,
                      (bool v) => setState(() => _draft = _draft.copyWith(sukebeiEnabled: v)),
                    ),
                  ],
                ),
              ),
              // ── 第 ④ 组：观看记录 · 播放器（第二十七轮）───────────────────────
              _groupHeader(t, 4, '观看记录 · 播放器',
                  '看过的能留多久、记不记进度、播放器两条栏什么时候出来'),
              // 观看记录 = 金（与侧栏「观看记录」页同一个色相：这里配的就是那一页的数据源）。
              DsSection(
                title: '观看记录',
                hue: DsHue.gold,
                icon: Icons.history,
                subtitle: '侧栏「观看记录」页的数据源：每看一集记一条（番名 / 集数 / 字幕组 / '
                    '看过时间 / 进度），过期的按这里的天数自动清掉',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Text(
                          '记录保留',
                          style: TextStyle(color: t.text2, fontSize: kSettingsSecondarySize),
                        ),
                        const SizedBox(width: 8),
                        NeoDropdown<int>(
                          width: 132,
                          height: 30,
                          fontSize: kSettingsSecondarySize,
                          value: _historyRetentionValue,
                          tooltip: '看过的记录留多久；「不删除」= 一直留着（第三十三轮起这是默认）',
                          label: _historyRetentionLabel(_historyRetentionValue),
                          items: <NeoDropdownItem<int>>[
                            for (final int days in kHistoryRetentionDays)
                              NeoDropdownItem<int>(days, _historyRetentionLabel(days)),
                          ],
                          onSelected: (int days) => setState(
                            () => _draft = _draft.copyWith(historyRetentionDays: days),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _historyRetentionValue == 0
                                ? '不自动删除：记录会一直留在这台机器上（可到「观看记录」页手动清空）'
                                : '超过 $_historyRetentionValue 天的记录在下次读取时自动移除',
                            style: TextStyle(color: t.text3, fontSize: kSettingsCaptionSize),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _switchRow(
                      '记录观看进度',
                      '记下每集看到哪儿（续播/进度条用），看到结尾自动打「已看过」的勾；'
                          '关掉后只记「什么时候看了哪一集」，不给进度也不自动打勾',
                      _draft.recordWatchProgress,
                      (bool v) => setState(() => _draft = _draft.copyWith(recordWatchProgress: v)),
                    ),
                  ],
                ),
              ),
              // 播放器 = 绿（"播放"那一族；播放页 / 已完成的绿是同一个信息：能看、在看）。
              DsSection(
                title: '播放器',
                hue: DsHue.emerald,
                icon: Icons.play_circle_outline,
                subtitle: '两条栏（标题栏 / 控制栏）什么时候出来、什么时候淡出',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _switchRow(
                      '鼠标移到画面正中也叫出控制栏',
                      '默认关：只有移到上下的栏目附近才唤起（第十四/二十六轮的语义，'
                          '看片时鼠标划过画面不会一直弹出两条栏）。打开后画面里任何位置'
                          '动一下都会显示，并且停住 1 秒才淡出',
                      _draft.wakeChromeAtCenter,
                      (bool v) => setState(() => _draft = _draft.copyWith(wakeChromeAtCenter: v)),
                    ),
                  ],
                ),
              ),
              // ── 第 ⑤ 组：更新 · 版本（第三十九轮）─────────────────────────
              _groupHeader(t, 5, '更新 · 版本',
                  '从 GitHub 的 Release 检查新版本；可以直接下载发布包覆盖本目录并重启'),
              _updateSection(),
            ],
          ),
        ),
        // 底部保存条（第十六轮：**手动保存**）。脏了才亮：提示 + 撤销改动 + 保存并生效，
        // 没改动时两个按钮都禁用（否则用户会以为"点了没反应"）。
        Container(
          padding: EdgeInsets.fromLTRB(t.spacing, 10, t.spacing, 10),
          decoration: BoxDecoration(
            color: t.raised,
            border: Border(top: BorderSide(color: t.divider)),
          ),
          child: Row(
            children: <Widget>[
              if (_applyFailure case final DsFailure failure)
                Expanded(
                  child: DsBanner(
                    kind: DsBannerKind.error,
                    text: '${failure.message}｜怎么办：${failure.hint ?? '—'}',
                  ),
                )
              // ⚠️ "有未保存的改动"要**压过**上一次保存的成功提示：保存完之后用户接着改，
              // 屏幕上必须立刻回到"还没写进去"，而不是继续挂着上一轮那句"已保存并已生效"。
              else if (dirty)
                Expanded(
                  child: Text(
                    '有未保存的改动：点「保存并生效」才会写进去（切页/关窗会问一句）',
                    key: dsSettingsSaveBarTextKey,
                    style: TextStyle(color: t.textDim, fontSize: kSettingsSecondarySize),
                  ),
                )
              else if (_applySuccess case final String success)
                Expanded(
                  child: DsBanner(kind: DsBannerKind.success, text: success),
                )
              else
                Expanded(
                  child: Text(
                    '设置已保存',
                    key: dsSettingsSaveBarTextKey,
                    style: TextStyle(color: t.textDim, fontSize: kSettingsSecondarySize),
                  ),
                ),
              const SizedBox(width: 10),
              TextButton(
                key: dsSettingsDiscardKey,
                onPressed: dirty ? _discard : null,
                child: const Text('撤销改动'),
              ),
              const SizedBox(width: 6),
              FilledButton.icon(
                key: dsSettingsSaveKey,
                onPressed: (!dirty || _saving) ? null : () => _save(),
                icon: const Icon(Icons.save, size: 16),
                label: Text(_saving ? '保存中…' : '保存并生效'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // 第 ⑤ 组：软件更新（第三十九轮：GitHub Release 检查更新 + 直接覆盖更新）
  // ─────────────────────────────────────────────────────────────────────────────

  /// 检查更新：用**草稿**里那两格（更新源 + 可选的访问令牌），所以填完就能点、不必先保存。
  Future<void> _checkUpdate() => ref
      .read(updateProvider.notifier)
      .check(_draft.updateRepo, tokenRaw: _draft.updateToken);

  /// 「立即重启并更新」：先兑现手动保存这一层，再解压交给覆盖脚本，最后走宿主统一退出。
  ///
  /// 为什么先保存：[updateRepo] 要留给**新版本**用（不然重启后那一格又空了，下次还得再填）。
  /// 落盘失败就**不切走**程序 —— 让用户先看见底部条那条原因，别把没存下去的东西一起带走。
  Future<void> _restartToUpdate() async {
    if (_dirty) {
      await _save();
      if (_applyFailure != null) return;
    }
    if (!mounted) return;
    await ref.read(updateProvider.notifier).apply();
  }

  /// 第 ⑤ 组：「软件更新」整块。
  ///
  /// 为什么整块包一层 [Consumer]：下载时端口每 256KB 报一次进度（39MB 的包约 150 次），
  /// 整页 `ref.watch` 会让上面 4 个分组跟着重铺 150 遍 —— 只有这一块需要动。
  Widget _updateSection() {
    final DsTokens t = context.ds;
    return Consumer(
      builder: (BuildContext context, WidgetRef ref, Widget? child) {
        final UpdateState update = ref.watch(updateProvider);
        // 更新源**内置**（第四十一轮）：这一格是"覆盖"入口 —— 留空就用内置仓库。
        // 用户问过的"仓库建了在哪找 api"照旧：把**真正会请求的接口**显示出来。
        final bool usingBuiltin = _draft.updateRepo.trim().isEmpty;
        final String? slug = core_update.normalizeRepoSlug(
          core_update.effectiveUpdateRepo(_draft.updateRepo),
        );
        // 软件更新 / 版本 = 橙（主页今日推荐也是这个橙：这一块管的就是"从外面拿新东西"）。
        return DsSection(
          title: '软件更新',
          hue: DsHue.orange,
          icon: Icons.info_outline,
          subtitle: '从 GitHub 的 Release 里取新版本，直接下载整个发布包覆盖本目录并重启'
              '（便携式：程序与它的 DSAnima-data 在同一个文件夹里）',
          trailing: Text(
            '当前 ${kAppVersion.label}',
            style: TextStyle(color: t.text2, fontSize: kSettingsSecondarySize),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _row(<Widget>[
                Expanded(
                  child: TextFormField(
                    key: _fieldKey('updateRepo'),
                    initialValue: _draft.updateRepo,
                    decoration: const InputDecoration(
                      labelText: '更新源（留空 = 内置）',
                      hintText: 'abc/DSAnima（留空就用内置仓库；整条地址也能直接粘）',
                    ),
                    style: TextStyle(color: t.text, fontSize: kSettingsBodySize),
                    onChanged: (String v) {
                      _draft = _draft.copyWith(updateRepo: v.trim());
                      _touchDraft();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                NeoButton(
                  label: '检查更新',
                  icon: Icons.refresh,
                  kind: NeoButtonKind.primary,
                  busy: update.phase == UpdatePhase.checking,
                  onPressed: update.busy ? null : _checkUpdate,
                ),
              ]),
              const SizedBox(height: 8),
              Text(
                slug == null
                    ? '这一格填的东西不是仓库地址。**留空**就用内置的 '
                        '`${core_update.kBuiltinUpdateRepo}`；要换成别的仓库，把 '
                        '`github.com/<用户名>/<仓库名>` 里那两段填进来（整条地址也能直接粘）。'
                    : '真正请求的接口：${core_update.releaseApiUrl(slug)}'
                        '${usingBuiltin ? '　（这一格留空 = 用内置的 ${core_update.kBuiltinUpdateRepo}）' : ''}'
                        '　GitHub 匿名额度 60 次/小时；改了这一格要点底部的「保存并生效」才会记住',
                style: TextStyle(color: t.text3, fontSize: kSettingsCaptionSize, height: 1.6),
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: _fieldKey('updateToken'),
                initialValue: _draft.updateToken,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '访问令牌（可选）',
                  hintText: 'github_pat_…（只读：Contents → Read-only）',
                ),
                style: TextStyle(color: t.text, fontSize: kSettingsBodySize),
                onChanged: (String v) {
                  _draft = _draft.copyWith(updateToken: v.trim());
                  _touchDraft();
                },
              ),
              const SizedBox(height: 8),
              Text(
                _draft.updateToken.trim().isEmpty
                    ? '**私有仓库、或者匿名读不到发布信息时**才需要填这一格：只读令牌就够'
                        '（GitHub → `Settings → Developer settings → Fine-grained tokens`，'
                        '权限只勾 **Contents: Read-only**）。不填 = 匿名请求（匿名额度 60 次/小时）'
                    : '检查更新与下载都会带上它（`Authorization: Bearer`）。'
                        '它明文存在本机设置里，所以只填只读令牌；不想要了就直接清空这一格。',
                style: TextStyle(color: t.text3, fontSize: kSettingsCaptionSize, height: 1.6),
              ),
              const SizedBox(height: 14),
              ..._updateStatus(t, ref, update),
            ],
          ),
        );
      },
    );
  }

  /// 结果区：状态机的每一档对应**一句话**（不含糊、不合并）。
  List<Widget> _updateStatus(DsTokens t, WidgetRef ref, UpdateState update) {
    final UpdateController controller = ref.read(updateProvider.notifier);
    final TextStyle plain =
        TextStyle(color: t.text2, fontSize: kSettingsSecondarySize, height: 1.6);
    final List<Widget> out = <Widget>[];
    if (update.note case final String note) {
      out.add(DsBanner(kind: DsBannerKind.info, text: note));
      out.add(const SizedBox(height: 10));
    }
    switch (update.phase) {
      case UpdatePhase.idle:
        out.add(Text('点「检查更新」会请求上面的接口；只有真的发现新版本，才会出现下载按钮。', style: plain));
      case UpdatePhase.checking:
        out.add(Text('正在请求 GitHub…（最多等 20 秒）', style: plain));
      case UpdatePhase.upToDate:
        out.add(Text(
          update.checkedAt == null
              ? '已是最新。'
              : '已是最新（检查于 ${formatRelative(update.checkedAt)}）。',
          style: plain,
        ));
      case UpdatePhase.available:
        final core_update.ReleaseInfo? release = update.release;
        final core_update.ReleaseAsset? asset = update.asset;
        out.add(DsBanner(
          kind: DsBannerKind.warning,
          text: '发现新版本 ${release?.tag ?? ''}：${release?.displayTitle ?? ''}'
              '（${formatBytes(asset?.sizeBytes)}）',
        ));
        final String notes = release?.notes.trim() ?? '';
        if (notes.isNotEmpty) {
          out.add(const SizedBox(height: 8));
          out.add(Text(notes, maxLines: 6, overflow: TextOverflow.ellipsis, style: plain));
        }
        out.add(const SizedBox(height: 12));
        out.add(_row(<Widget>[
          NeoButton(
            label: '下载更新包',
            icon: Icons.download,
            kind: NeoButtonKind.primary,
            onPressed: controller.download,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '下载到数据目录的 update 文件夹；下完再点一次才会真正替换（不会偷偷改你的程序）。',
              style: TextStyle(color: t.text3, fontSize: kSettingsCaptionSize, height: 1.5),
            ),
          ),
        ]));
      case UpdatePhase.downloading:
        final double? ratio = update.progress;
        out.add(Text(
          '正在下载 ${formatBytes(update.received)} / ${formatBytes(update.total)}'
          '${ratio == null ? '' : '（${formatPercent(ratio)}）'}',
          style: plain,
        ));
        out.add(const SizedBox(height: 8));
        out.add(_row(<Widget>[
          Expanded(
            child: ratio == null
                ? DsInset(height: 6, radius: 3, border: false, child: const SizedBox.shrink())
                : NeoProgress(value: ratio),
          ),
          const SizedBox(width: 12),
          OutlinedButton(onPressed: controller.cancelDownload, child: const Text('取消下载')),
        ]));
      case UpdatePhase.ready:
        out.add(DsBanner(
          kind: DsBannerKind.success,
          text: '更新包已下载：${update.package?.path.split(Platform.pathSeparator).last ?? ''}'
              '（${formatBytes(update.assetBytes)}）',
        ));
        out.add(const SizedBox(height: 12));
        out.add(_row(<Widget>[
          NeoButton(
            label: '立即重启并更新',
            icon: Icons.restart_alt,
            kind: NeoButtonKind.primary,
            onPressed: _restartToUpdate,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'DSAnima 会先退出（正常收尾：落盘 + 停边车），几秒后自动以新版本打开。'
              '新版本装在同一个文件夹里，设置和观看记录都还在。',
              style: TextStyle(color: t.text3, fontSize: kSettingsCaptionSize, height: 1.5),
            ),
          ),
        ]));
      case UpdatePhase.applying:
        out.add(Text('正在准备覆盖并退出…（覆盖脚本已启动）', style: plain));
      case UpdatePhase.problem:
        final DsFailure? failure = update.failure;
        out.add(DsBanner(
          kind: DsBannerKind.error,
          text: failure == null
              ? '更新过程中出错了。'
              : '${failure.message}｜怎么办：${failure.hint ?? '—'}',
        ));
        out.add(const SizedBox(height: 12));
        out.add(NeoButton(
          label: '重试',
          icon: Icons.refresh,
          kind: NeoButtonKind.secondary,
          onPressed: update.busy ? null : _checkUpdate,
        ));
    }
    return out;
  }

  Widget _sourcePicker(BuildContext context) {
    final DsTokens t = context.ds;
    final List<SourceOption> sources = ref.watch(sourceOptionsProvider);
    if (sources.isEmpty) {
      return const DsBanner(
        kind: DsBannerKind.warning,
        text:
            '源未接通：core 的 sources/ 尚未注入，默认源暂时无法选择。'
            '接通后这里会列出 nyaa 动漫区 / mikan / 自定义 RSS。',
      );
    }
    final bool hasValue = sources.any((SourceOption s) => s.id == _draft.defaultSourceId);
    // 存的源不在了：优先落回 mikan（默认源），没有 mikan 才用列表第一个。
    final String fallback = sources.any((SourceOption s) => s.id == 'mikan')
        ? 'mikan'
        : sources.first.id;
    return SizedBox(
      width: 260,
      child: DropdownButtonFormField<String>(
        initialValue: hasValue ? _draft.defaultSourceId : fallback,
        decoration: const InputDecoration(labelText: '默认源'),
        isExpanded: true,
        dropdownColor: t.surfaceAlt,
        // 第四十六轮：同「代理模式」——不给 style 就是 17 的 titleMedium。
        style: dsControlTextStyle(t, fontSize: kSettingsBodySize),
        iconSize: 18,
        items: <DropdownMenuItem<String>>[
          for (final SourceOption s in sources)
            DropdownMenuItem<String>(value: s.id, child: Text(s.displayName)),
        ],
        onChanged: (String? value) =>
            setState(() => _draft = _draft.copyWith(defaultSourceId: value ?? fallback)),
      ),
    );
  }

  /// 搜索模式（用户 2026-10-12 第十四轮：「默认为聚合源……设置中切换回单独源模式」）。
  ///
  /// 放在「默认源」旁边：这两件事是同一个决策的两半 —— 聚合模式下「默认源」不生效
  /// （聚合问的是一档里的一组源），说清楚省得用户以为"改了默认源但搜索还是到处都有"。
  Widget _searchModePicker(BuildContext context) {
    final DsTokens t = context.ds;
    return _row(<Widget>[
      SizedBox(
        width: 260,
        child: DropdownButtonFormField<SearchMode>(
          initialValue: _draft.searchMode,
          decoration: const InputDecoration(labelText: '搜索模式'),
          isExpanded: true,
          dropdownColor: t.surfaceAlt,
          // 第四十六轮：同「代理模式」。顺带修掉"17 号字把「聚合（全部 / 动漫 / 全集）」
          // 挤成省略号"—— 260 宽的格子在 13 下装得下全句。
          style: dsControlTextStyle(t, fontSize: kSettingsBodySize),
          iconSize: 18,
          items: const <DropdownMenuItem<SearchMode>>[
            DropdownMenuItem<SearchMode>(
              value: SearchMode.aggregate,
              child: Text('聚合（全部 / 动漫 / 全集）'),
            ),
            DropdownMenuItem<SearchMode>(
              value: SearchMode.single,
              child: Text('单独源（只问上面那个默认源）'),
            ),
          ],
          onChanged: (SearchMode? value) => setState(
            () => _draft = _draft.copyWith(searchMode: value ?? SearchMode.aggregate),
          ),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        // 这一段是整页最长的一句说明。⚠️ 第二十六轮：**不再折叠**（删掉「展开说明」），
        // 全文换行摊开；行高 1.5 → 1.7 补回可读性（字小了、行距得跟上）。
        child: Text(
          '聚合（默认）：一次搜索并发问勾选的源，合并去重后按发布时间从新到旧排；'
          '搜索页顶部的「聚合 / 动漫 / 全集」是快捷全选，旁边那颗「源 N/M」打开勾选面板，'
          '可以只勾几个（默认全开，sukebei 打开后在「其它」那组里一起勾上）。'
          '单个源最多等 15 秒，某个源挂了不影响其它源，只在结果上方提醒少了哪几个。\n'
          '单独源：回到以前的样子 —— 只问「默认源」那一个，搜索页顶部是源下拉。',
          style: TextStyle(color: t.text3, fontSize: kSettingsCaptionSize, height: 1.7),
        ),
      ),
    ]);
  }

  /// 加一条排除规则。
  ///
  /// 第四十二轮 UX #25：旧实现空输入/重复都是**直接 return** —— 框里的字不清、列表不变、
  /// 一句提示都没有（同页 tracker 来源那个动作是逐条反馈的，两条路不一致）。
  /// 更麻烦的是"正则"这件事：标签与示例都写着正则，而 core 以前按子串匹配，于是照着
  /// 示例填的 `合集|总集篇` 永远不生效也没人告诉你。现在两头都对齐：
  /// * core 真的按正则匹配（`BandwidthPolicy.isExcluded`）；
  /// * 这里空/重复/编不出来都有话说，编不出来时**按纯文本存**（转义后），不静默丢。
  void _addExclude(String raw) {
    final String value = raw.trim();
    if (value.isEmpty) {
      showWarning(context, '先在输入框里填一条规则再点「添加」',
          hint: '它是正则，例如 合集|总集篇（`|` = 或）');
      return;
    }
    if (_draft.bandwidth.excludePatterns.contains(value)) {
      showWarning(context, '「$value」已经在下面的列表里了', hint: '列表保持不变，不用重复添加');
      return;
    }
    // 编不出来（例如 `C++`）就**转义成纯文本**再存：比拒绝更实用，
    // 而且存下去的正是"会匹配什么"，列表里显示的就是它。
    final bool validRegex = _isValidRegex(value);
    final String stored = validRegex ? value : RegExp.escape(value);
    setState(() {
      _draft = _draft.copyWith(
        bandwidth: _draft.bandwidth.copyWith(
          excludePatterns: <String>[..._draft.bandwidth.excludePatterns, stored],
        ),
      );
      _newExclude.clear();
    });
    if (validRegex) {
      showSuccess(context, '已加入省流量列表：$value');
    } else {
      showWarning(context, '「$value」不是合法的正则，已按**纯文本**加入',
          hint: '存进去的是转义后的 $stored —— 匹配的是这几个字本身，不会被当成语法');
    }
  }

  static bool _isValidRegex(String pattern) {
    try {
      RegExp(pattern);
      return true;
    } on FormatException {
      return false;
    }
  }

  Widget _row(List<Widget> children) =>
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: children);

  /// 非受控输入框的 key：带上草稿版本，让程序化替换草稿时它重新吃一遍 `initialValue`
  /// （理由见 [_draftRevision]）。
  Key _fieldKey(String name) => ValueKey<String>('$name@$_draftRevision');

  /// 数字设置框：**只把合法数字写进草稿**，解析不出来就地标红（第四十二轮 UX #12/#37）。
  ///
  /// 与手写 `TextFormField(onChanged: ... int.tryParse(v) ?? 0)` 的区别：
  /// * 非法/空输入**不改进草稿** —— 值仍是上一个合法值，保存时写下去的也是它；
  /// * 框下标红说清为什么不认（只认整数 / 不能是负数 / 空着不算 0）；
  /// * 提示只在状态真的变了才 `setState`（这一页刻意避免每次按键重铺整页）。
  ///
  /// [integer] false 时按小数解析（做种比那种）。
  Widget _numberField(
    DsTokens t, {
    required String name,
    required num value,
    required String label,
    required void Function(num parsed) onChanged,
    double width = 200,
    bool integer = true,
  }) {
    return SizedBox(
      width: width,
      child: TextFormField(
        key: _fieldKey(name),
        initialValue: '$value',
        decoration: InputDecoration(
          labelText: label,
          errorText: _fieldErrors[name],
        ),
        style: TextStyle(color: t.text, fontSize: kSettingsBodySize),
        onChanged: (String raw) {
          final String text = raw.trim();
          final num? parsed =
              integer ? int.tryParse(text) : double.tryParse(text);
          final String? error = text.isEmpty
              ? '空着不算 0（要填 0 就写 0）：这一项还用着上一个值'
              : parsed == null
                  ? '只认数字${integer ? '（整数）' : ''}：这一项还用着上一个值'
                  : parsed < 0
                      ? '不能是负数：这一项还用着上一个值'
                      : null;
          if (_fieldErrors[name] != error) {
            setState(() {
              if (error == null) {
                _fieldErrors.remove(name);
              } else {
                _fieldErrors[name] = error;
              }
            });
          }
          if (error != null) return; // 非法输入不进草稿
          onChanged(parsed!);
          _touchDraft();
        },
      ),
    );
  }

  /// 一行「标题 + 分段控件 + 一句说明」（决策 F23/F24：封面大小 / 轮播封面 / 轮播大小）。
  ///
  /// 三档/两档都用 [NeoSegmented]（扁平规范下的分段控件：`sunken` 槽 + 选中项 accent 12% 底），
  /// 文案由枚举自带的 `label` 给（见 `neo.dart` 的 `_defaultSegmentLabel`）。
  Widget _segmentedRow<T>(
    DsTokens t,
    String title,
    String hint,
    List<T> options,
    T value,
    ValueChanged<T> onChanged,
  ) =>
      Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(title,
                    style: TextStyle(
                        color: t.text,
                        fontSize: kSettingsBodySize,
                        fontWeight: FontWeight.w600)),
                const SizedBox(width: 14),
                NeoSegmented<T>(
                  options: options,
                  value: value,
                  // 第四十六轮：分段控件里的字跟这一页同一档（13）——
                  // 不传就是全局 body（15），比左边的行标题还大。
                  fontSize: kSettingsBodySize,
                  onChanged: onChanged,
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(hint,
                style: TextStyle(
                    color: t.text3,
                    fontSize: kSettingsSecondarySize,
                    height: 1.5)),
          ],
        ),
      );

  Widget _switchRow(String title, String subtitle, bool value, ValueChanged<bool> onChanged) =>
      // 外面 DsSection 是带底色的 Container；ListTile 需要一个更近的 Material
      // 祖先来画水波纹（否则 Flutter 会报「ink splashes may be invisible」）。
      Material(
        color: Colors.transparent,
        child: SwitchListTile(
          // ⚠️ 第二十六轮「增加每个设置的间距」：开关行是这一页密度最高的一类设置，
          // 间距统一做在这一个 `contentPadding` 上（全页 24 个开关一处生效）。
          contentPadding: const EdgeInsets.symmetric(horizontal: 0, vertical: 9),
          dense: true,
          title: Text(title, style: const TextStyle(fontSize: kSettingsBodySize)),
          // ⚠️ 第二十六轮：说明**不再折叠**（「展开说明 / 收起说明」整段删掉），
          // 全文换行显示；字小了（12）就把行距提到 1.6 补回可读性。
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              subtitle,
              style: const TextStyle(fontSize: kSettingsSecondarySize, height: 1.6),
            ),
          ),
          value: value,
          onChanged: onChanged,
        ),
      );

  void _setNote(String note) {
    if (!mounted) return;
    setState(() {
      _applyFailure = null;
      _applySuccess = note;
    });
  }

  /// 点外观：**立刻生效 + 立刻落盘 + 圆形揭开**（用户 2026-10-15 第三十三轮
  /// 「点击外观直接转换，不用点保存，使用动画Circular Reveal」）。
  ///
  /// 为什么这一项破了"整页手动保存"的规矩（第十六轮：「去除设置自动保存的逻辑，仅手动保存」）：
  /// 那条规矩的理由是**其它设置项要重建边车/源客户端**，顺手生效很难解释"生效到哪一步了"；
  /// 而外观只是一个 token 表，换它没有任何副作用，用户却要先看一眼才能决定要不要它 ——
  /// 让他先点"保存并生效"再看，等于把试色变成一次落盘。
  /// 所以：**外观单独即时生效**，其余项照旧手动保存（问答里选的就是这一条）。
  ///
  /// 三件事同一帧里对齐，避免"页面显示 A、盘上是 B"：
  /// 1. 盘上写新 themeId（`settingsProvider.patch`：**同步改内存态**，落盘异步跟在后头）；
  /// 2. 草稿跟上（选中态落在被点的那一格）；
  /// 3. 圆形揭开（旧界面快照 + 新配色），圆心 = 被点的那一格。
  ///
  /// ⚠️ **基线要等落盘成功才推上去**（第四十二轮 UX #41）：旧的 apply 里 `_baseline`
  /// 和 `_draft` 一起改，于是底部条在写盘还没回来时就已经显示「设置已保存」；
  /// 写盘失败时更糟 —— `replace` 把内存态回滚了（配色变回旧的那套），而页面草稿
  /// 还停在新的那格，**选择器与真实主题相反**。现在：成功才推基线，失败把草稿也退回去。
  Future<void> _pickAppearance(DsAppearance appearance, Offset origin) async {
    final DsThemeRevealHostState? host =
        context.findAncestorStateOfType<DsThemeRevealHostState>();
    // 失败时要退回的那一套 = 基线里的（基线是"盘上那份"的镜像）。
    final String persistedThemeId = _baseline.themeId;
    void apply() {
      setState(() {
        // 只动草稿。基线留到写盘成功再动。
        _draft = _draft.copyWith(themeId: appearance.code);
      });
      // 同步改内存态（这一帧界面就换色），落盘与失败回滚在后台完成。
      unawaited(
        ref
            .read(settingsProvider.notifier)
            .patch((AppSettings s) => s.copyWith(themeId: appearance.code))
            .then<void>((_) {
          if (!mounted) return;
          // 真的写下去了：这时才把基线推上去（页面回到"干净"）。
          setState(() {
            _baseline = _baseline.copyWith(themeId: appearance.code);
          });
          _setNote('外观已切换并保存：${appearance.label}');
        }).catchError((Object error) {
          // 落盘失败时 `replace` 已经把内存态回滚了；这里如实说一句，不装作成功，
          // 并把**页面草稿也退回旧的那一套** —— 否则选择器还标着新那格。
          if (!mounted) return;
          setState(() {
            _draft = _draft.copyWith(themeId: persistedThemeId);
            _applyFailure = describeFailure(error);
          });
        }),
      );
    }

    if (host == null) {
      apply(); // 单独挂在测试/别的宿主里：直接换，不演动画。
      return;
    }
    await host.revealFrom(origin: origin, apply: apply);
  }

  /// 托盘可用性说明（托盘端口未接通时不能承诺「隐藏后能唤回」）。
  String get trayHint {
    final bool trayReady = ref.read(trayPortProvider).isAvailable;
    return trayReady ? '开启后：关闭主程序会询问「后台继续下载？」，托盘图标可唤回窗口' : '托盘组件未接通：开启后关闭主窗口只会最小化（可从任务栏唤回），不会隐藏到托盘';
  }
}

/// 支持目录的小包装（未注入时明确报错，而不是猜一个路径）。
class DirectorySupport {
  const DirectorySupport(this.path);
  final String? path;

  static DirectorySupport of(WidgetRef ref) =>
      DirectorySupport(ref.watch(supportDirProvider)?.path);

  /// 缺少支持目录时抛可行动异常（设置页会把它显示成失败横幅）。
  String require() {
    final String? value = path;
    if (value == null) {
      throw const PortUnavailableException(
        '应用支持目录未注入，引擎无法定位状态目录',
        hint: '这是装配问题（main.dart 未注入 supportDirProvider），请回报开发者',
      );
    }
    return value;
  }
}
