/// 首启向导：① 选下载目录 → ② 测试引擎连通 → ③ 选默认源。
///
/// 每一步都**真实执行**：目录要能写、引擎要真的起得来（否则显示可行动错误）、
/// 源未接通就明说「源未接通」，不假装完成。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/download_dir.dart';
import '../domain/error_text.dart';
import '../domain/models.dart';
import '../domain/trackers.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import 'widgets/brand_icon.dart';
import 'widgets/neo_appearance_picker.dart';
import 'widgets/state_views.dart';

class FirstRunPage extends ConsumerStatefulWidget {
  const FirstRunPage({super.key});

  @override
  ConsumerState<FirstRunPage> createState() => _FirstRunPageState();
}

class _FirstRunPageState extends ConsumerState<FirstRunPage> {
  int _step = 0;
  late AppSettings _draft;
  DsFailure? _failure;
  String? _note;
  bool _busy = false;
  bool _complianceChecked = false;

  /// 用户试过「完成」但没勾合规声明：合规那块要变成错误态（否则"点了没反应"）。
  bool _complianceMissing = false;

  @override
  void initState() {
    super.initState();
    _draft = ref.read(settingsProvider);
    // 用户 2026-10-11：「下载目录默认在 C:\Users\用户名\Downloads\Anime」。
    // 进第 ① 步就把默认值**预填进草稿**（不只是显示提示）：
    // * 用户可以直接点「下一步」，不必手打路径；
    // * 后面两步的「下载目录：…」回显与 `_next()` 的空值校验读的都是同一份草稿，
    //   不会出现"框里有字、校验说没填"的自相矛盾；
    // * 仍然只是**草稿**（`_finish()` 才落盘），用户改/浏览目录都会覆盖它。
    // 解析不出默认值（没有 USERPROFILE / HOMEDRIVE）时保持原样：第 ① 步照旧拦住并说明怎么办。
    final String seeded = effectiveDownloadDir(_draft.downloadDir);
    if (seeded.isNotEmpty) _draft = _draft.copyWith(downloadDir: seeded);
  }

  @override
  void dispose() {
    super.dispose();
  }

  /// 「写入内置 tracker」：把仓库里的**离线快照**填进草稿。
  ///
  /// ⚠️ 刻意**不**写 `trackerListUpdatedAt`：这是回落快照，不是「联网更新成功」。
  /// 写了就等于宣布"今天已经更新过"，每日自动刷新（`state/tracker_refresh.dart`）
  /// 会白等一天 —— 而用户点这个按钮往往正是因为网络不通。
  void _updateTrackers() {
    setState(() {
      _draft = _draft.copyWith(extraTrackers: trackerListText(builtinTrackers));
      _note = '已写入 ${builtinTrackers.length} 个内置公共 tracker（离线快照，'
          '不算「今日已更新」；联网后会自动刷新）';
      _failure = null;
    });
  }

  Future<void> _pickDirectory() async {
    try {
      final String? dir = await ref
          .read(pickerPortProvider)
          .pickDirectory(title: '选择下载目录（番剧存这里）');
      if (dir == null) return;
      setState(() {
        _draft = _draft.copyWith(downloadDir: dir);
        _failure = null;
      });
    } catch (error, stackTrace) {
      if (!mounted) return;
      setState(() =>
          _failure = describeFailure(error, stackTrace: stackTrace));
    }
  }

  Future<void> _startEngine() async {
    final String? supportDir = ref.read(supportDirProvider)?.path;
    if (supportDir == null) {
      setState(() => _failure = const DsFailure(
          '应用支持目录未注入，无法启动引擎',
          hint: '这是装配问题（main.dart 未注入 supportDirProvider），请回报开发者'));
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
      _note = null;
    });
    final bool ok = await ref.read(engineBootstrapProvider.notifier).start(
          settings: _draft,
          supportDir: ref.read(supportDirProvider)!,
        );
    if (!mounted) return;
    final EngineBootstrapState state = ref.read(engineBootstrapProvider);
    setState(() {
      _busy = false;
      if (ok) {
        _note = '边车已就绪（端口由系统分配，runtime.json 已写入）';
      } else {
        _failure = DsFailure(state.error ?? '引擎启动失败',
            hint: state.errorHint);
      }
    });
    if (ok) {
      ref.invalidate(engineHealthProvider);
      ref.invalidate(engineTorrentsProvider);
    }
  }

  /// 「跳过向导」/「完成」共用：把草稿落盘并置 `firstRunCompleted`。
  ///
  /// 这里是 `needsFirstRunProvider`（`state/providers.dart:379`）唯一放行条件，
  /// 所以**任何失败都必须变成屏幕上的一句话**，否则用户看到的是"点了没反应，
  /// App 永远进不去"（第四十二轮 UX #1，一级）。三条纪律：
  /// ① `replace()` 是**故意 rethrow** 的（`providers.dart:368`），必须由本函数接住；
  /// ② `_busy` 全程覆盖写盘，按钮要变灰、要能看见「处理中…」；
  /// ③ 失败文案要**指向真实原因**（`documents` 被 OneDrive 接管 / 满盘 / 杀软锁目录），
  ///    不能让上一次「请先勾选合规声明」的陈旧 `_failure` 留着指错方向。
  Future<void> _finish() async {
    if (_busy) return; // 写盘可能慢，防连点重复落盘
    if (!_complianceChecked) {
      setState(() {
        // 合规声明在第 ③ 步：先把用户带到那一步，再把错误显示出来 ——
        // 旧实现只在第 ① / ② 步渲染 _failure，第 ③ 步点「完成」时**什么都看不到**。
        _step = 2;
        _complianceMissing = true;
        _failure = const DsFailure(
            '请先阅读并勾选合规声明',
            hint: 'DSAnima 只是播放/下载工具，不对内容来源与版权负责；'
                '继续使用前需要你确认这一点');
      });
      return;
    }
    final AppSettings next = _draft.copyWith(
      firstRunCompleted: true,
      complianceAccepted: true,
    );
    setState(() {
      _busy = true;
      _failure = null;
      _complianceMissing = false;
    });
    try {
      await ref.read(settingsProvider.notifier).replace(next);
    } catch (error, stackTrace) {
      if (!mounted) return;
      final DsFailure base = describeFailure(error, stackTrace: stackTrace);
      setState(() {
        _busy = false;
        _failure = DsFailure(
          '设置没能保存到本机，所以向导没法完成',
          hint: '常见原因：「文档」目录被 OneDrive 接管后不可写、磁盘已满、'
              '或安全软件锁住了配置目录。腾出空间 / 解除锁定后再点一次「完成」；'
              '也可以先退出 App，稍后重开会再次进入向导',
          detail: base.detail ?? base.message,
        );
      });
      return;
    }
    if (!mounted) return;
    try {
      await ref.read(lifecyclePortProvider).applySettings(next);
    } catch (_) {
      // 已经保存；向导不因为「引擎还没起」而卡住，设置页会显示未生效原因。
    }
    if (!mounted) return;
    setState(() => _busy = false);
  }

  /// 「下一步」：每一步都做**真校验**，通不过就把错误显示在当前这一步。
  void _next() {
    if (_step == 0) {
      final String? dir = _draft.downloadDir;
      if (dir == null || dir.trim().isEmpty) {
        setState(() => _failure = const DsFailure(
            '还没有选下载目录',
            hint: '点「选择目录…」挑一个盘，或直接在输入框里填路径'
                '（例如 F:\\Anime）；也可以点「跳过向导」以后再设'));
        return;
      }
    }
    if (_step == 1) {
      // 到「默认源」这一步：存的源不在了（或首次进来）就落到 mikan —— 番剧的中文
      // 标题与更新表都在那边，比 nyaa 更适合当默认。
      final List<SourceOption> sources = ref.read(sourceOptionsProvider);
      if (sources.isNotEmpty &&
          !sources.any((SourceOption s) => s.id == _draft.defaultSourceId)) {
        _draft = _draft.copyWith(
          defaultSourceId: sources.any((SourceOption s) => s.id == 'mikan')
              ? 'mikan'
              : sources.first.id,
        );
      }
    }
    setState(() {
      _failure = null;
      _step += 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final List<SourceOption> sources = ref.watch(sourceOptionsProvider);
    final EngineBootstrapState engine = ref.watch(engineBootstrapProvider);
    return Scaffold(
      backgroundColor: t.bg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 620),
          child: Container(
            margin: const EdgeInsets.all(24),
            decoration: t.cardDecoration(
              radius: t.radiusCard,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      // 与侧栏/托盘/exe 同一个图标（唯一真源见 brand_icon.dart）。
                      const DsBrandIcon(size: 40),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text('欢迎使用 DSAnima',
                                style: TextStyle(
                                    color: t.text,
                                    fontSize: DsTypeScale.display,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 4),
                            Text('三步就能用：挑个下载目录 → 起引擎 → 选默认源',
                                style: TextStyle(
                                    color: t.textDim,
                                    fontSize: DsTypeScale.body)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: t.line),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _StepRail(current: _step, onSelect: (int i) {
                        if (!_busy && i <= _step) setState(() => _step = i);
                      }),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: SingleChildScrollView(
                            child: switch (_step) {
                              0 => _stepDirectory(t),
                              1 => _stepEngine(t, engine),
                              _ => _stepSource(t, sources),
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: t.line),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
                  child: Row(
                    children: <Widget>[
                      if (_busy) const DsLoading(label: '处理中…', compact: true),
                      const Spacer(),
                      TextButton(
                        // 不裸调：`_finish` 自己是全域的（内部 try/catch + `_busy`），
                        // `unawaited` 只是把这个意图写明，避免未处理的异步异常。
                        onPressed:
                            _busy ? null : () => unawaited(_finish()),
                        child: const Text('跳过向导（之后可在设置里改）'),
                      ),
                      const SizedBox(width: 8),
                      if (_step > 0)
                        OutlinedButton(
                          onPressed: _busy
                              ? null
                              : () => setState(() => _step -= 1),
                          child: const Text('上一步'),
                        ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _busy
                            ? null
                            : () async {
                                if (_step < 2) {
                                  _next();
                                } else {
                                  await _finish();
                                }
                              },
                        child: Text(_step < 2 ? '下一步' : '完成'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _stepDirectory(DsTokens t) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('① 下载目录',
              style: TextStyle(
                  color: t.text, fontSize: DsTypeScale.title, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text('边车把番剧分片存在这里；建议放在空间充足的盘（SSD 更顺）。',
              style: TextStyle(color: t.textDim, fontSize: DsTypeScale.body, height: 1.5)),
          const SizedBox(height: 4),
          // 预填了什么、为什么，明说（用户 2026-10-11：默认目录就是 Downloads\Anime）。
          // 显示**解析出来的真实路径**而不是 `%USERPROFILE%\...` 这个变量名 ——
          // 用户要核对的是"文件会存到哪"，不是环境变量的拼法。
          Text(
            _draft.downloadDir == null || _draft.downloadDir!.trim().isEmpty
                ? r'本机没解析出默认目录（%USERPROFILE%\Downloads\Anime 拿不到）：'
                    '请点「选择目录…」或直接填路径'
                : '已按默认规则（%USERPROFILE%\\Downloads\\Anime）预填：'
                    '${_draft.downloadDir}；想换位置点「选择目录…」或直接改',
            style: TextStyle(color: t.text3, fontSize: DsTypeScale.secondary, height: 1.5),
          ),
          const SizedBox(height: 14),
          TextFormField(
            initialValue: _draft.downloadDir ?? '',
            decoration: const InputDecoration(
              labelText: '下载目录',
              hintText: r'C:\Users\<用户名>\Downloads\Anime',
            ),
            style: TextStyle(color: t.text, fontSize: DsTypeScale.body),
            onChanged: (String v) => setState(() {
              // 清空 = 明确"不要这个目录"：必须用 clearDownloadDir 才清得掉
              // （`copyWith(downloadDir: null)` 的语义是"不改"，见 AppSettings.copyWith）。
              final bool empty = v.trim().isEmpty;
              _draft = _draft.copyWith(
                downloadDir: empty ? null : v.trim(),
                clearDownloadDir: empty,
              );
            }),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: _pickDirectory,
                icon: const Icon(Icons.folder_open, size: 15),
                label: const Text('选择目录…'),
              ),
              const SizedBox(width: 10),
              if (_draft.downloadDir != null)
                Expanded(
                  child: SelectableText(_draft.downloadDir!,
                      maxLines: 1,
                      style: TextStyle(color: t.success, fontSize: DsTypeScale.secondary)),
                ),
            ],
          ),
          if (_failure != null) ...<Widget>[
            const SizedBox(height: 14),
            // 这一步**故意不给** `onRetry`：这里的失败只有"还没选下载目录"一种，
            // 它不是"重试就能过"的动作，重试按钮只会误导（要用户做的动作就在上面）。
            DsErrorPanel(failure: _failure!),
          ],
        ],
      );

  Widget _stepEngine(DsTokens t, EngineBootstrapState engine) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('② 启动并测试引擎',
              style: TextStyle(
                  color: t.text, fontSize: DsTypeScale.title, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            'DSAnima 需要 rqbit-engine.exe（Rust 边车）负责下载与串流。'
            '默认会在应用目录与 engine/target/release 下自动查找；找不到就手填路径。',
            style: TextStyle(color: t.textDim, fontSize: DsTypeScale.body, height: 1.5),
          ),
          const SizedBox(height: 14),
          TextFormField(
            initialValue: _draft.enginePath ?? '',
            decoration: const InputDecoration(
              labelText: 'rqbit-engine.exe（留空 = 自动查找）',
              hintText: r'F:\Ai\DSAnima\engine\target\release\rqbit-engine.exe',
            ),
            style: TextStyle(color: t.text, fontSize: DsTypeScale.body),
            onChanged: (String v) {
              // 同设置页：清空 = "留空，自动查找"，得用 clearEnginePath 才清得掉。
              final bool empty = v.trim().isEmpty;
              setState(() => _draft = _draft.copyWith(
                    enginePath: empty ? null : v.trim(),
                    clearEnginePath: empty,
                  ));
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              FilledButton.icon(
                onPressed: _busy ? null : _startEngine,
                icon: const Icon(Icons.play_arrow, size: 16),
                label: Text(engine.running ? '重新启动引擎' : '启动引擎'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: () async {
                  ref.invalidate(engineHealthProvider);
                  try {
                    final EngineHealthView health =
                        await ref.read(engineHealthProvider.future);
                    if (!mounted) return;
                    setState(() => _note =
                        'GET /health 成功：v${health.version.isEmpty ? '?' : health.version} · 会话 ${health.sessions}');
                  } catch (error, stackTrace) {
                    if (!mounted) return;
                    setState(() => _failure =
                        describeFailure(error, stackTrace: stackTrace));
                  }
                },
                icon: const Icon(Icons.network_check, size: 16),
                label: const Text('测试连通'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: _updateTrackers,
                icon: const Icon(Icons.system_update_alt, size: 16),
                label: const Text('写入内置 tracker'),
              ),
            ],
          ),
          if (_note != null) ...<Widget>[
            const SizedBox(height: 12),
            DsBanner(kind: DsBannerKind.success, text: _note!),
          ],
          if (_failure != null) ...<Widget>[
            const SizedBox(height: 12),
            // 这一步的失败都是"引擎没起来 / /health 不通"，**重试就是再起一次**，
            // 所以错误面板自带重试（第四十二轮 UX #43）。
            DsErrorPanel(
              failure: _failure!,
              onRetry: _busy ? null : () => unawaited(_startEngine()),
              retryLabel: engine.running ? '重新启动引擎' : '启动引擎',
            ),
          ],
        ],
      );

  Widget _stepSource(DsTokens t, List<SourceOption> sources) {
    // 合规声明左侧细条：未勾选=警告色，试过「完成」但没勾=危险色，勾了=成功色。
    final Color complianceTone = _complianceMissing
        ? t.danger
        : (_complianceChecked ? t.success : t.warning);
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('③ 选默认源',
              style: TextStyle(
                  color: t.text, fontSize: DsTypeScale.title, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text('搜索页默认从这个源拉「最新」；源可以随时在顶部工具条切换。',
              style: TextStyle(color: t.textDim, fontSize: DsTypeScale.body, height: 1.5)),
          const SizedBox(height: 14),
          if (sources.isEmpty)
            const DsBanner(
              kind: DsBannerKind.warning,
              text: '源未接通：core 的 sources/（nyaa / mikan / RSS）尚未注入，'
                  '现在无法选择默认源。可以先完成向导，接通后到「设置 → 网络」里选。',
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final SourceOption source in sources)
                  ChoiceChip(
                    label: Text(source.displayName),
                    selected: _draft.defaultSourceId == source.id,
                    onSelected: (bool selected) {
                      if (!selected) return;
                      setState(() =>
                          _draft = _draft.copyWith(defaultSourceId: source.id));
                    },
                  ),
              ],
            ),
          const SizedBox(height: 18),
          Text('③′ 外观（8 套内置，随时可换）',
              style: TextStyle(
                  color: t.text,
                  fontSize: DsTypeScale.body,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 7),
          Row(
            children: <Widget>[
              NeoAppearancePicker(
                keyPrefix: 'firstrun-appearance',
                value: DsAppearance.fromCode(_draft.themeId),
                // 向导里的外观只是**草稿**（走完向导才落盘），不演圆形揭开。
                onChanged: (DsAppearance a, Offset _) => setState(
                    () => _draft = _draft.copyWith(themeId: a.code)),
              ),
              const SizedBox(width: 12),
              Text('之后可在设置里随时切换',
                  style:
                      TextStyle(color: t.text3, fontSize: DsTypeScale.caption)),
            ],
          ),
          const SizedBox(height: 18),
          // 合规声明（spec §7.3 Q20①）：必须显式确认才能完成向导。
          // 未勾选 = 凹槽 + 警告色细条；勾选 = 凸起 + 成功色细条（语义色只做小面积）。
          // 试过「完成」但没勾 → 变危险色细条 + 下方给出可行动错误（旧实现这里什么都不显示）。
          Container(
            padding: const EdgeInsets.fromLTRB(11, 11, 11, 11),
            decoration: BoxDecoration(
              color: _complianceChecked ? t.raised : t.sunken,
              borderRadius: BorderRadius.circular(t.radiusCard),
              // 扁平（决策 F1）：内容层零阴影 —— 勾选状态靠面色 + 左侧语义色细条表达。
              border: Border(
                left: BorderSide(color: complianceTone, width: 3),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Checkbox(
                  value: _complianceChecked,
                  onChanged: (bool? v) => setState(() {
                    _complianceChecked = v ?? false;
                    _complianceMissing = false;
                    _failure = null;
                  }),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('合规声明（必须确认）',
                          style: TextStyle(
                              color: t.text,
                              fontSize: DsTypeScale.body,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 5),
                      Text(
                        'DSAnima 只是「边下边播」的工具：它不提供、不托管、不推荐任何资源，'
                        '也不对内容的来源与版权负责。请自行确认所下载/观看的内容在你所在地区合法，'
                        '并由你承担使用后果。',
                        style: TextStyle(
                            color: t.textDim, fontSize: DsTypeScale.secondary, height: 1.55),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // 第 ③ 步也必须渲染 _failure：合规声明就在这一步，旧实现只在前两步渲染，
          // 于是「没勾就点完成」完全没有提示（用户报的「引导不完全」）。
          if (_failure != null) ...<Widget>[
            // 第 ③ 步的失败有两种：没勾合规声明（下方勾选就是动作）、以及**落盘失败**
            // （首启向导最容易卡死的一种）。后者是"再存一次就能过"（比如腾出磁盘后），
            // 所以给重试。
            DsErrorPanel(
              failure: _failure!,
              onRetry: _busy ? null : () => unawaited(_finish()),
              retryLabel: '再存一次',
            ),
            const SizedBox(height: 12),
          ],
          if (_draft.downloadDir != null)
            Text('下载目录：${_draft.downloadDir}',
                style: TextStyle(color: t.textDim, fontSize: DsTypeScale.secondary)),
          if (_draft.defaultSourceId.isNotEmpty)
            Text('默认源：${_draft.defaultSourceId}',
                style: TextStyle(color: t.textDim, fontSize: DsTypeScale.secondary)),
        ],
      );
  }
}

class _StepRail extends StatelessWidget {
  const _StepRail({required this.current, required this.onSelect});

  final int current;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    const List<(String, String)> steps = <(String, String)>[
      ('下载目录', '番剧存哪'),
      ('引擎连通', 'rqbit-engine'),
      ('默认源', 'mikan / nyaa / RSS'),
    ];
    return Container(
      width: 178,
      decoration: BoxDecoration(
        // 向导左侧步骤栏：凹陷面表达「这是背景轨」，用极淡分隔线收边（无硬边框）。
        color: t.sunken.withValues(alpha: 0.55),
        border: Border(right: BorderSide(color: t.divider)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int i = 0; i < steps.length; i++)
              InkWell(
                onTap: () => onSelect(i),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: <Widget>[
                      Container(
                        width: 20,
                        height: 20,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: i <= current ? t.accent : t.surfaceAlt,
                          borderRadius: BorderRadius.circular(t.radiusCard),
                        ),
                        child: Text('${i + 1}',
                            style: TextStyle(
                                color: i <= current ? t.bg : t.textDim,
                                fontSize: DsTypeScale.caption,
                                fontWeight: FontWeight.w700)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(steps[i].$1,
                                style: TextStyle(
                                    color: i == current ? t.text : t.textDim,
                                    fontSize: DsTypeScale.body,
                                    fontWeight: i == current
                                        ? FontWeight.w600
                                        : FontWeight.w400)),
                            Text(steps[i].$2,
                                style:
                                    TextStyle(color: t.textDim, fontSize: DsTypeScale.caption)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
