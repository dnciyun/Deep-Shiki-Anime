/// 扩展页（1.1.0 M3/T15）：侧栏第 9 个目的地「扩展」。
///
/// 用户 2026-10-17：「扩展就是插件一样的东西可能会加很多东西」「默认不要令牌…」
/// 1.1.0 的边界（计划文档 M3 + `domain/extensions.dart`）：扩展是**资源型插件**
/// （着色器 / 数据 / 主题等静态内容），不是运行时加载的 Dart 代码；本版本把
/// `shader-pack` 接进播放器的「超分」菜单（`state/extension_schemes.dart` 翻译成
/// shikiin 的方案；装/卸/启停后**已打开的播放窗口会立即刷新**），其他类型**装得上、用不上**。
///
/// ⚠️ 文案口径（Lead 2026-10-17 更正）：页面里**不许**写「到设置页的超分方案区里选」——
/// 设置页这一轮还没有超分方案区（M2/T12 推迟）。装好后的提示以 `state.notice` 为准，
/// 页面不另编一句；第六十四轮起热刷新已接通，所以也不许再写「重开播放窗口才生效」。
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
import 'dart:io';

import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/extensions.dart';
import '../state/extension_settings.dart';
import '../state/infra.dart' show supportDirProvider;
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

/// 「官方插件库」一键拉取（用户 2026-10-18：「加入官方插件库，可以直接下载我加进去的插件」）。
const Key dsExtensionsOfficialKey = ValueKey<String>('ds-extensions-official');

/// 某一行的「设置」按钮（只给**有设置项**的扩展：目前是画面调节包的预设开关）。
Key dsExtensionSettingsKey(String id) => ValueKey<String>('ds-extension-settings-$id');

/// 设置对话框里某个预设的勾选框（勾上 = 该预设出现在播放器右键菜单里）。
Key dsExtensionPresetToggleKey(String id, String presetId) =>
    ValueKey<String>('ds-extension-preset-$id-$presetId');

/// 设置对话框：全部开启 / 全部关闭 / 保存 / 取消。
const Key dsExtensionSettingsAllKey = ValueKey<String>('ds-extension-settings-all');
const Key dsExtensionSettingsNoneKey = ValueKey<String>('ds-extension-settings-none');
const Key dsExtensionSettingsSaveKey = ValueKey<String>('ds-extension-settings-save');
const Key dsExtensionSettingsCancelKey = ValueKey<String>('ds-extension-settings-cancel');
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
      unawaited(_loadUserSettings());
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

  /// 扩展用户设置（关掉的预设 / 上次的目录地址）：进页面读一次，顺手把输入框填上。
  ///
  /// 读盘失败只当"没有设置"（`loadExtensionUserSettings` 永不抛）：这一页的第一职责
  /// 是让用户看见装了什么，不该因为一份偏好文件把页面卡住。
  Future<void> _loadUserSettings() async {
    final Directory? dir = ref.read(supportDirProvider);
    if (dir == null) return; // 装配问题：设置页/首启向导会报，这里静默
    await ref.read(extensionUserSettingsProvider.notifier).ensureLoaded(dir);
    if (!mounted) return;
    final String? saved = ref.read(extensionUserSettingsProvider).catalogUrl;
    if (saved != null && saved.trim().isNotEmpty && _catalog.text.trim().isEmpty) {
      _catalog.text = saved;
    }
  }

  /// 拉一份在线目录，成功后**把地址记下来**（「官方插件库」按钮一键重载要用）。
  Future<void> _fetchCatalog(String rawUrl) async {
    final String url = rawUrl.trim();
    await _controller.addCatalog(url);
    final ExtensionsState s = ref.read(extensionsProvider);
    if (s.catalogUri != null && s.phase == ExtensionsPhase.ready && s.catalog.isNotEmpty) {
      await ref.read(extensionUserSettingsProvider.notifier).rememberCatalogUrl(url);
    }
  }

  /// 「官方插件库」：用上次成功拉取的地址（没有就用出厂常量）再拉一次。
  ///
  /// 两个来源的分工（用户 2026-10-18 给了仓库：<https://github.com/dnciyun/DSAnima-plungin>）：
  /// * **出厂常量** `kOfficialExtensionsCatalogUrl` —— 开箱即用，不用先粘地址；
  /// * **上次成功拉过的地址**（`extension-settings.json` 的 `catalogUrl`）优先 ——
  ///   换仓库时用户只要重新粘一次，不用等发版改代码。代价是"换仓库后旧地址还会被用"，
  ///   所以交付说明里写了怎么回到出厂地址（清空输入框粘一次）。
  /// 下面 `url.isEmpty` 那条分支只是兜底（常量若被改回空串/还没配），不参与正常路径。
  Future<void> _loadOfficialCatalog() async {
    // 先把设置读进来：进页面那一次是 postFrame 里异步读的，用户手快时可能还没读完，
    // 不补这一步会把"上次拉过的地址"误判成"还没配地址"。
    await _loadUserSettings();
    if (!mounted) return;
    final core.ExtensionUserSettings settings = ref.read(extensionUserSettingsProvider);
    final String saved = (settings.catalogUrl ?? '').trim();
    final String url = saved.isNotEmpty ? saved : kOfficialExtensionsCatalogUrl;
    if (url.isEmpty) {
      _controller.note(
        '还没有官方插件库地址：把插件仓库的网页地址（https://github.com/作者/仓库）粘到上面'
        '「拉取在线目录」框里拉一次，之后这里就能一键重载',
      );
      return;
    }
    _catalog.text = url;
    await _fetchCatalog(url);
  }

  /// 这个扩展有没有可设置的项。
  ///
  /// 用户 2026-10-18：「在扩展页，一些扩展有设置按钮」—— **有设置项的才有按钮**，
  /// 没有的别放一个点进去空白的入口。目前有设置的是画面调节包（预设开关）。
  bool _hasSettings(core.ExtensionManifest manifest) =>
      manifest.kind == core.ExtensionKind.picturePack &&
      (manifest.picture?.presets.isNotEmpty ?? false);

  /// 「设置」对话框：画面调节包的预设开关（关掉的预设不进播放器右键菜单）。
  Future<void> _openSettings(InstalledExtension item) async {
    final core.PictureSpec? spec = item.manifest.picture;
    final List<core.PicturePreset> presets = spec?.presets ?? const <core.PicturePreset>[];
    if (presets.isEmpty) return;
    final core.ExtensionUserSettings settings = ref.read(extensionUserSettingsProvider);
    final Set<String> draft = <String>{...settings.hiddenPresetsOf(item.id)};
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setLocal) => AlertDialog(
          title: Text('「${item.name}」设置'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // 用户 2026-10-18：「右键菜单内不要有太多介绍，全在扩展内就好了」——
                  // 包自己的说明（`payload.picture.hint`）和每档预设的 `description`
                  // 都放这里（预设说明是下面每一项的 subtitle），播放器菜单只留名称。
                  if ((spec?.chainHint ?? '').trim().isNotEmpty) ...<Widget>[
                    Text(
                      spec!.chainHint,
                      style: TextStyle(
                        color: context.ds.text2,
                        fontSize: DsTypeScale.caption,
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Text(
                    '取消勾选的预设不会再出现在播放器右键菜单里（「调节…」滑杆面板不受影响）。'
                    '保存后，已经打开的播放窗口会重试一次；没重试过来的话重开播放窗口即可。',
                    style: TextStyle(
                      color: context.ds.text3,
                      fontSize: DsTypeScale.caption,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final core.PicturePreset preset in presets)
                    CheckboxListTile(
                      key: dsExtensionPresetToggleKey(item.id, preset.id),
                      value: !draft.contains(preset.id),
                      onChanged: (bool? on) => setLocal(() {
                        if (on == true) {
                          draft.remove(preset.id);
                        } else {
                          draft.add(preset.id);
                        }
                      }),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(
                        preset.name,
                        style: TextStyle(
                          color: context.ds.text,
                          fontSize: DsTypeScale.secondary,
                        ),
                      ),
                      subtitle: preset.description.isEmpty
                          ? null
                          : Text(
                              preset.description,
                              style: TextStyle(
                                color: context.ds.text3,
                                fontSize: DsTypeScale.caption,
                              ),
                            ),
                    ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              key: dsExtensionSettingsAllKey,
              onPressed: () => setLocal(draft.clear),
              child: const Text('全部开启'),
            ),
            TextButton(
              key: dsExtensionSettingsNoneKey,
              onPressed: () => setLocal(() => draft.addAll(presets.map((core.PicturePreset p) => p.id))),
              child: const Text('全部关闭'),
            ),
            TextButton(
              key: dsExtensionSettingsCancelKey,
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: dsExtensionSettingsSaveKey,
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;
    await ref.read(extensionUserSettingsProvider.notifier).setHiddenPresets(item.id, draft);
    if (!mounted) return;
    // 立刻让已打开的播放窗口重扫（走同一条"扩展变了"的通道）：预设开关存在
    // 数据根里，子窗口收到通知后自己读 —— 用户不用关掉播放器再看。
    _controller.bumpRevision();
    _controller.note(
      draft.isEmpty
          ? '已保存「${item.name}」：全部预设在播放器菜单里'
          : '已保存「${item.name}」：关掉了 ${draft.length} 个预设',
    );
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
              // 用户 2026-10-18：「识别 github 上面的」—— 贴仓库网页地址就行，
              // 换算成 raw 的规则在 `core/lib/extensions/urls.dart`（main/master、根/子目录都试）。
              label: '拉取在线目录（catalog.json 或 GitHub 仓库地址）',
              hint: 'https://github.com/作者/仓库',
              buttonLabel: '拉取在线目录',
              buttonIcon: Icons.cloud_download_outlined,
              busy: busy,
              onPressed: () => unawaited(_fetchCatalog(_catalog.text)),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                NeoButton(
                  key: dsExtensionsOfficialKey,
                  label: '官方插件库',
                  icon: Icons.public,
                  compact: true,
                  onPressed: busy ? null : () => unawaited(_loadOfficialCatalog()),
                ),
                Text(
                  '出厂就指向官方插件库（dnciyun/DSAnima-plungin）；拉过一次的地址会被记住，换仓库不用改代码。',
                  style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
                ),
              ],
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
          '本版本支持着色器包（shader-pack，装好后出现在播放器的「超分」菜单里）'
          '与画面调节包（picture-pack，锐度/线条/调色预设）；'
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
              // 包名本来就叫「音效包 / 画面调节包」时不再重复一遍（用户 2026-10-19：
              // 「名字不要这么叫，就叫音效包 画面调节包 超分包」——两行同名很难看）。
              if (core.ExtensionKind.labelOf(item.manifest.kind) != item.manifest.name)
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
                  // 会被翻成播放器的超分方案；装/卸/启停成功后主窗口会通知已打开的
                  // 播放窗口重扫（1.1.0 第六十四轮），没开窗时下次开窗扫描兜底。
                  // "用在哪儿"由 `domain/extensions.dart` 的 `extensionUseHint` 统一给：
                  // shader-pack 进「超分」菜单，picture-pack 是画面调节 —— 指错菜单
                  // 比不显示更糟（用户点进去找不到）。
                  extensionUseHint(item.manifest),
                  key: dsExtensionUseHintKey(item.id),
                  style: TextStyle(
                    color: usable ? t.success : t.text3,
                    fontSize: DsTypeScale.caption,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (_hasSettings(item.manifest)) ...<Widget>[
                NeoButton(
                  key: dsExtensionSettingsKey(item.id),
                  label: '设置',
                  icon: Icons.tune,
                  compact: true,
                  onPressed: busy ? null : () => unawaited(_openSettings(item)),
                ),
                const SizedBox(width: 6),
              ],
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
    final String kindLabel = core.ExtensionKind.labelOf(m.kind);
    final String meta = <String>[
      // 包名就叫「音效包」这类时不再重复类型（同已装列表）。
      if (kindLabel != m.name) kindLabel,
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
