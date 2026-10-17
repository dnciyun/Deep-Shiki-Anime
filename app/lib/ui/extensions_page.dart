/// 扩展页（1.1.0 M3/T15）：侧栏第 9 个目的地「扩展」。
///
/// 用户 2026-10-17：「扩展就是插件一样的东西可能会加很多东西」「默认不要令牌…」
/// 1.1.0 的边界（计划文档 M3 + `domain/extensions.dart`）：扩展是**资源型插件**
/// （着色器 / 数据 / 主题等静态内容），不是运行时加载的 Dart 代码；本版本把
/// `shader-pack` 接进播放器的「超分」菜单（`state/extension_schemes.dart` 翻译成
/// shikiin 的方案，**下次打开播放窗口生效**），其他类型**装得上、用不上**。
///
/// ⚠️ 文案口径（Lead 2026-10-17 更正）：页面里**不许**写「到设置页的超分方案区里选」——
/// 设置页这一轮还没有超分方案区（M2/T12 推迟）。装好后的提示以 `state.notice` 为准
/// （状态机写的是「下次打开播放窗口可在「超分」菜单里选用」），页面不另编一句。
///
/// 三条"不撒谎"的落点（状态机在 `state/extensions.dart`，这里只负责照它显示）：
/// * **装不上就是装不上**：端口抛异常 → 红字（为什么 + 怎么办），绝不显示假的"已安装"；
/// * **取消 ≠ 失败**：取消安装显示中性提示「已取消安装（临时文件已清理）」，不是红字；
/// * **装上 ≠ 能用**：`usable == false` 的每一行都写着「本版本不接运行时」，
///   不许让用户以为"装了就有新功能"。
///
/// 视觉与设置页同一套语言：`DsSection`（凸起卡片 + 色相标记）+ `DsChip` +
/// `NeoButton` / `NeoBanner`；整页身份色 = 玫红（`hueOfTab(ShellTab.extensions)` 同源）。
library;

import 'dart:async';

import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/extensions.dart';
import '../domain/format.dart';
import '../state/extensions.dart';
import '../theme/tokens.dart';
import 'widgets/ds_cards.dart';
import 'widgets/neo.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 测试锚点（页面控件太多，靠文字找容易撞：页名「扩展」本身也出现在工具条里）
// ─────────────────────────────────────────────────────────────────────────────

const Key dsExtensionsStatsKey = ValueKey<String>('ds-extensions-stats');
const Key dsExtensionsRefreshKey = ValueKey<String>('ds-extensions-refresh');
const Key dsExtensionsOpenDirKey = ValueKey<String>('ds-extensions-open-dir');
const Key dsExtensionsImportZipKey = ValueKey<String>('ds-extensions-import-zip');
const Key dsExtensionsUrlFieldKey = ValueKey<String>('ds-extensions-url-field');
const Key dsExtensionsUrlInstallKey = ValueKey<String>('ds-extensions-url-install');
const Key dsExtensionsCatalogFieldKey = ValueKey<String>('ds-extensions-catalog-field');
const Key dsExtensionsCatalogFetchKey = ValueKey<String>('ds-extensions-catalog-fetch');
const Key dsExtensionsInstallingKey = ValueKey<String>('ds-extensions-installing');
const Key dsExtensionsCancelKey = ValueKey<String>('ds-extensions-cancel');
const Key dsExtensionsNoticeKey = ValueKey<String>('ds-extensions-notice');
const Key dsExtensionsProblemKey = ValueKey<String>('ds-extensions-problem');
const Key dsExtensionsProblemHintKey = ValueKey<String>('ds-extensions-problem-hint');
const Key dsExtensionsEmptyKey = ValueKey<String>('ds-extensions-empty');
const Key dsExtensionsRemoveConfirmKey = ValueKey<String>('ds-extensions-remove-confirm');
const Key dsExtensionsRemoveCancelKey = ValueKey<String>('ds-extensions-remove-cancel');

Key dsExtensionRowKey(String id) => ValueKey<String>('ds-extension-row-$id');
Key dsExtensionToggleKey(String id) => ValueKey<String>('ds-extension-toggle-$id');
Key dsExtensionRemoveKey(String id) => ValueKey<String>('ds-extension-remove-$id');
Key dsExtensionUseHintKey(String id) => ValueKey<String>('ds-extension-use-$id');
Key dsExtensionsCatalogRowKey(String id) => ValueKey<String>('ds-extensions-catalog-$id');
Key dsExtensionsCatalogInstallKey(String id) =>
    ValueKey<String>('ds-extensions-catalog-install-$id');

/// 扩展页：装 / 卸 / 启停 / 本地导入 / 在线目录。
///
/// 所有列表数据都来自 [extensionsProvider]；页面挂载时调一次 `ensureLoaded()`
/// （懒挂载：没进过这一页就不扫盘，与 M1/T1 同一套）。
class ExtensionsPage extends ConsumerStatefulWidget {
  const ExtensionsPage({super.key});

  @override
  ConsumerState<ExtensionsPage> createState() => _ExtensionsPageState();
}

class _ExtensionsPageState extends ConsumerState<ExtensionsPage> {
  /// 「从地址安装」输入框。
  final TextEditingController _url = TextEditingController();

  /// 「拉取在线目录」输入框。
  final TextEditingController _catalog = TextEditingController();

  /// 文件选择器打开中（`state.busy` 还不会变 —— 选完才真正开始安装）。
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    // ⚠️ 不能在 initState 里**直接**调 `ensureLoaded()`：`refresh()` 会同步把 provider
    // 置成 scanning，而 initState 仍处在父级的 build 阶段 —— Riverpod 3 禁止在 build 期
    // 改 provider（会抛 "Tried to modify a provider while the widget tree was building"）。
    // 推到第一帧之后：页面先画「读取中」，扫盘结果到了再换成列表。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(extensionsProvider.notifier).ensureLoaded());
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _catalog.dispose();
    super.dispose();
  }

  /// 页面身份色：与侧栏图标 / 工具条页名 / 内容区洗色同源（见 `widgets/hues.dart`）。
  DsHue get _hue => DsHue.rose;

  ExtensionsController get _controller => ref.read(extensionsProvider.notifier);

  /// 本地导入 zip：选文件期间把按钮禁掉（选完 `installFromZip` 自己会进入 installing）。
  Future<void> _importZip() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      await _controller.installFromZip();
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 卸载确认：**文件进回收站**（用户 2026-10-12 定的"删除要可恢复"）。
  Future<void> _confirmRemove(InstalledExtension item) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('卸载「${item.name}」？'),
        content: Text(
          '扩展目录会被移到**回收站**（可恢复），不是永久删除。\n\n'
          '${item.name} ${item.manifest.version} · ${core.ExtensionKind.labelOf(item.manifest.kind)}',
          style: TextStyle(color: context.ds.text2, fontSize: DsTypeScale.body, height: 1.5),
        ),
        actions: <Widget>[
          TextButton(
            key: dsExtensionsRemoveCancelKey,
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: dsExtensionsRemoveConfirmKey,
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _controller.remove(item.id);
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final ExtensionsState s = ref.watch(extensionsProvider);
    final ExtensionsSummary summary = s.summary;
    // 任何"正在忙"（扫盘 / 安装 / 选文件）都禁用所有动作按钮：连点会排两次队，
    // 第二次只会被控制器静默丢掉（`state.busy` 检查），但按钮看起来还能点就是骗人。
    final bool busy = s.busy || _picking;

    return ListView(
      padding: EdgeInsets.fromLTRB(t.spacing, t.spacing, t.spacing, t.spacing * 2),
      children: <Widget>[
        _header(t, s, summary, busy),
        if (s.problem != null) _problem(t, s),
        if (s.notice != null) _notice(s.notice!),
        if (s.phase == ExtensionsPhase.installing) _installing(t, s),
        _installedSection(t, s, busy),
        _catalogSection(t, s, busy),
      ],
    );
  }

  // ── 顶部：统计 + 所有操作入口 ──────────────────────────────────────────────

  Widget _header(DsTokens t, ExtensionsState s, ExtensionsSummary summary, bool busy) => DsSection(
        title: '扩展（资源包）',
        hue: _hue,
        icon: Icons.extension_outlined,
        subtitle: '扩展是资源包：静态内容（着色器 / 数据），不是运行时加载的代码。'
            '本版本支持着色器包（shader-pack）：装好后出现在播放器的「超分」菜单里；'
            '其他类型本版本只做安装/管理（不接运行时）。',
        trailing: DsChip(label: '${summary.installedCount} 个', hue: _hue),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '已安装 ${summary.installedCount} 个 · 启用 ${summary.enabledCount} · '
              '可用 ${summary.usableCount} · 占用 ${formatBytes(summary.bytes)}',
              key: dsExtensionsStatsKey,
              style: TextStyle(color: t.text, fontSize: DsTypeScale.secondary),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                NeoButton(
                  key: dsExtensionsRefreshKey,
                  label: '刷新',
                  icon: Icons.refresh,
                  compact: true,
                  busy: s.phase == ExtensionsPhase.scanning,
                  onPressed: busy ? null : () => unawaited(_controller.refresh()),
                ),
                NeoButton(
                  key: dsExtensionsOpenDirKey,
                  label: '打开扩展目录',
                  icon: Icons.folder_open,
                  compact: true,
                  onPressed: busy ? null : () => unawaited(_controller.openDirectory()),
                ),
                NeoButton(
                  key: dsExtensionsImportZipKey,
                  label: '本地导入 zip…',
                  icon: Icons.upload_file,
                  compact: true,
                  busy: _picking,
                  onPressed: busy ? null : _importZip,
                ),
              ],
            ),
            const SizedBox(height: 14),
            _addressRow(
              t,
              fieldKey: dsExtensionsUrlFieldKey,
              buttonKey: dsExtensionsUrlInstallKey,
              controller: _url,
              label: '从地址安装（zip 直链，只收 HTTPS）',
              hint: 'https://…/扩展包.zip',
              buttonLabel: '从地址安装',
              buttonIcon: Icons.link,
              busy: busy,
              onPressed: () => unawaited(_controller.installFromUrl(_url.text)),
            ),
            const SizedBox(height: 10),
            _addressRow(
              t,
              fieldKey: dsExtensionsCatalogFieldKey,
              buttonKey: dsExtensionsCatalogFetchKey,
              controller: _catalog,
              label: '拉取在线目录（catalog.json 地址）',
              hint: 'https://…/catalog.json',
              buttonLabel: '拉取在线目录',
              buttonIcon: Icons.cloud_download_outlined,
              busy: busy,
              onPressed: () => unawaited(_controller.addCatalog(_catalog.text)),
            ),
          ],
        ),
      );

  /// 一行「输入框 + 动作按钮」（安装直链 / 拉目录共用）。
  Widget _addressRow(
    DsTokens t, {
    required Key fieldKey,
    required Key buttonKey,
    required TextEditingController controller,
    required String label,
    required String hint,
    required String buttonLabel,
    required IconData buttonIcon,
    required bool busy,
    required VoidCallback onPressed,
  }) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: TextField(
              key: fieldKey,
              controller: controller,
              enabled: !busy,
              style: TextStyle(color: t.text, fontSize: DsTypeScale.secondary),
              decoration: InputDecoration(
                labelText: label,
                hintText: hint,
                isDense: true,
              ),
              onSubmitted: (_) {
                if (!busy) onPressed();
              },
            ),
          ),
          const SizedBox(width: 10),
          NeoButton(
            key: buttonKey,
            label: buttonLabel,
            icon: buttonIcon,
            compact: true,
            onPressed: busy ? null : onPressed,
          ),
        ],
      );

  // ── 反馈：中性/成功条 与 红字问题区（分开两个落点）─────────────────────────

  /// notice：成功（绿）或中性（信息）——「已取消安装」属于后者，不该被画成失败。
  Widget _notice(String text) {
    final bool neutral = text.contains('取消') || text.contains('没有可用');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: NeoBanner(
        key: dsExtensionsNoticeKey,
        kind: neutral ? NeoBannerKind.info : NeoBannerKind.success,
        text: text,
      ),
    );
  }

  /// problem：红字（为什么）+ 红字小字（怎么办）。**不和 notice 抢同一个位置**。
  Widget _problem(DsTokens t, ExtensionsState s) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
        child: Container(
          padding: const EdgeInsets.fromLTRB(0, 10, 12, 10),
          decoration: BoxDecoration(
            color: t.danger.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(t.radiusControl),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 2,
                height: 18,
                margin: const EdgeInsets.only(left: 8, right: 10),
                decoration: BoxDecoration(
                  color: t.danger,
                  borderRadius: BorderRadius.circular(t.radiusPill),
                ),
              ),
              Icon(Icons.error_outline, size: 15, color: t.danger),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      s.problem!,
                      key: dsExtensionsProblemKey,
                      style: TextStyle(color: t.danger, fontSize: DsTypeScale.secondary, height: 1.4),
                    ),
                    if (s.problemHint case final String hint) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        '怎么办：$hint',
                        key: dsExtensionsProblemHintKey,
                        style: TextStyle(color: t.danger, fontSize: DsTypeScale.caption, height: 1.45),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  // ── 安装中：名字 + 进度（未知总量 = 不确定进度）+ 取消 ─────────────────────

  Widget _installing(DsTokens t, ExtensionsState s) {
    final ExtensionProgress? progress = s.progress;
    final double? fraction = progress?.fraction;
    final String detail = progress == null
        ? '准备中…'
        : fraction == null
            ? '已收到 ${formatBytes(progress.received)}（对端没给总大小，进度不确定）'
            : '已收到 ${formatBytes(progress.received)} / ${formatBytes(progress.total)}';
    return DsSection(
      key: dsExtensionsInstallingKey,
      title: '正在安装',
      hue: _hue,
      icon: Icons.system_update_alt,
      subtitle: '「${s.installingName ?? '扩展'}」',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(t.radiusPill),
                  // fraction 为 null（总量未知）= 不确定进度条：不拿"已下载多少"除以编造的总量。
                  child: LinearProgressIndicator(
                    value: fraction,
                    minHeight: 8,
                    backgroundColor: t.sunken,
                    valueColor: AlwaysStoppedAnimation<Color>(t.hueFill(_hue)),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  detail,
                  style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          NeoButton(
            key: dsExtensionsCancelKey,
            label: s.cancelling ? '正在取消…' : '取消安装',
            kind: NeoButtonKind.danger,
            compact: true,
            // 正在取消时按钮禁用（端口收到取消标志要等下一个 chunk 才收尾）。
            onPressed: s.cancelling ? null : () => _controller.cancelInstall(),
          ),
        ],
      ),
    );
  }

  // ── 已安装列表 ────────────────────────────────────────────────────────────

  Widget _installedSection(DsTokens t, ExtensionsState s, bool busy) => DsSection(
        title: '已安装扩展',
        hue: _hue,
        icon: Icons.inventory_2_outlined,
        subtitle: '禁用只是不让它参与运行时（文件还在）；卸载会把目录移到回收站，可恢复。',
        trailing: DsChip(label: '${s.installed.length} 个', hue: _hue),
        child: s.installed.isEmpty
            ? _empty(t, s)
            : Column(
                children: <Widget>[
                  for (int i = 0; i < s.installed.length; i++) ...<Widget>[
                    if (i > 0) const SizedBox(height: 8),
                    _installedRow(t, s.installed[i], busy),
                  ],
                ],
              ),
      );

  /// 空态：说清"扩展是什么、本版本支持什么"，而不是只留一句"暂无数据"。
  ///
  /// 扫描中/还没扫过时不谎报"没有扩展"；读盘失败时指向上面那条红字。
  Widget _empty(DsTokens t, ExtensionsState s) {
    final String text;
    if (s.problem != null) {
      text = '读不到已安装列表 —— 先按上面的红字处理，再点「刷新」。';
    } else if (s.phase == ExtensionsPhase.idle || s.phase == ExtensionsPhase.scanning) {
      text = '正在读取扩展目录…';
    } else {
      text = '还没有安装任何扩展。\n'
          '扩展是资源包（着色器 / 数据等静态内容），不是运行时代码；'
          '本版本支持着色器包（shader-pack）：装好后出现在播放器的「超分」菜单里；'
          '其他类型本版本只做安装/管理。\n'
          '点「本地导入 zip…」选一个包，或填地址安装。';
    }
    return Container(
      key: dsExtensionsEmptyKey,
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: t.inset(radius: t.radiusControl),
      child: Text(
        text,
        style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption, height: 1.7),
      ),
    );
  }

  Widget _installedRow(DsTokens t, InstalledExtension item, bool busy) {
    final bool usable = item.usable;
    return Container(
      key: dsExtensionRowKey(item.id),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: t.cardDecoration(radius: t.radiusControl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: t.text,
                    fontSize: DsTypeScale.body,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              DsChip(
                label: item.enabled ? '已启用' : '已禁用',
                tone: item.enabled ? t.success : t.text3,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              DsChip(label: 'v${item.manifest.version}', hue: _hue),
              // 类型用 core 的中文表：认不出的类型也要如实写「未知类型（…）」。
              DsChip(label: core.ExtensionKind.labelOf(item.manifest.kind), hue: _hue),
              DsChip(label: formatBytes(item.bytes)),
              DsChip(label: '来源：${item.origin.label}'),
            ],
          ),
          if (item.manifest.description.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              item.manifest.description,
              style: TextStyle(color: t.text2, fontSize: DsTypeScale.caption, height: 1.5),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Icon(
                usable ? Icons.check_circle_outline : Icons.info_outline,
                size: 14,
                color: usable ? t.success : t.text3,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  // 装上 ≠ 能用：这一行就是用户点进来最该看到的一句话。
                  // 可用性链路见 `state/extension_schemes.dart`：扩展目录里的 shader-pack
                  // 会被翻成播放器的超分方案，**重开播放窗口**才生效（跨窗口热通知留到 1.2.0）。
                  usable
                      ? '可在播放器的「超分」菜单里选用（重开播放窗口生效）'
                      : '本版本不接运行时（数据包装得上、用不上，暂时不会有新功能）',
                  key: dsExtensionUseHintKey(item.id),
                  style: TextStyle(
                    color: usable ? t.success : t.text3,
                    fontSize: DsTypeScale.caption,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              NeoButton(
                key: dsExtensionToggleKey(item.id),
                label: item.enabled ? '禁用' : '启用',
                compact: true,
                onPressed: busy
                    ? null
                    : () => unawaited(_controller.setEnabled(item.id, !item.enabled)),
              ),
              const SizedBox(width: 6),
              NeoButton(
                key: dsExtensionRemoveKey(item.id),
                label: '卸载',
                kind: NeoButtonKind.danger,
                compact: true,
                onPressed: busy ? null : () => unawaited(_confirmRemove(item)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── 在线目录 ──────────────────────────────────────────────────────────────

  Widget _catalogSection(DsTokens t, ExtensionsState s, bool busy) {
    final Set<String> installedIds = <String>{
      for (final InstalledExtension item in s.installed) item.id,
    };
    final Uri? uri = s.catalogUri;
    final String subtitle = uri == null
        ? '还没拉过目录：在上面填一个 catalog.json 地址再点「拉取在线目录」'
        : '来自 $uri'
            '${s.catalogFetchedAt == null ? '' : ' · ${_fetchedLabel(s.catalogFetchedAt!)}'}';
    return DsSection(
      title: '在线目录',
      hue: _hue,
      icon: Icons.public,
      subtitle: subtitle,
      trailing: DsChip(label: '${s.catalog.length} 个', hue: _hue),
      child: s.catalog.isEmpty
          ? Text(
              '目录是空的（或还没拉取）。目录只提供安装入口，真正装什么以 zip 里的清单为准。',
              style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption, height: 1.6),
            )
          : Column(
              children: <Widget>[
                for (int i = 0; i < s.catalog.length; i++) ...<Widget>[
                  if (i > 0) Divider(height: 1, color: t.divider),
                  _catalogRow(t, s.catalog[i], installedIds.contains(s.catalog[i].manifest.id), busy),
                ],
              ],
            ),
    );
  }

  Widget _catalogRow(DsTokens t, core.CatalogEntry entry, bool installed, bool busy) {
    final core.ExtensionManifest m = entry.manifest;
    final String meta = <String>[
      core.ExtensionKind.labelOf(m.kind),
      formatBytes(entry.size),
      // 目录没给 sha256 时必须如实写出来（只有大小校验，弱一档）。
      entry.sha256 == null ? '未提供哈希' : 'sha256 校验',
    ].join(' · ');
    return Padding(
      key: dsExtensionsCatalogRowKey(m.id),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        m.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: t.text,
                          fontSize: DsTypeScale.secondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    DsChip(label: 'v${m.version}', hue: _hue),
                  ],
                ),
                if (m.description.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(
                    m.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.text2, fontSize: DsTypeScale.caption, height: 1.45),
                  ),
                ],
                const SizedBox(height: 3),
                Text(
                  meta,
                  style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          NeoButton(
            key: dsExtensionsCatalogInstallKey(m.id),
            // 同 id 已装：装下去是**升级/覆盖**，按钮如实写「重新安装」。
            label: installed ? '重新安装' : '安装',
            icon: installed ? Icons.refresh : Icons.download,
            compact: true,
            onPressed: busy ? null : () => unawaited(_controller.installFromCatalog(entry)),
          ),
        ],
      ),
    );
  }

  /// 目录拉取时间的中文短标签（不显示绝对时间：拉取时间只用来回答"新不新"）。
  String _fetchedLabel(DateTime at) {
    final Duration age = DateTime.now().difference(at);
    if (age.inMinutes < 1) return '刚刚拉取';
    if (age.inHours < 1) return '${age.inMinutes} 分钟前拉取';
    if (age.inDays < 1) return '${age.inHours} 小时前拉取';
    return '${age.inDays} 天前拉取';
  }
}
