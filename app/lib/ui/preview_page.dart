/// 组件总览页（调试用，决策 A36）。
///
/// 用途：把新拟态**全部组件与状态**摆在一页，先确认风格再铺到真页面；
/// 之后任何人改 token，都能一页看出回归。
///
/// 打开方式：`dsanima.exe --preview`，或环境变量 `DSANIMA_PREVIEW=1`。
///
/// 版式原则（用户 2026-10-10 反馈「字过多、过于拥挤」后重做）：
/// * **一件事一句话**，注释性文字最多 8 字，决策编号只留在标题末尾；
/// * 组与组之间留 40px、卡片内 24px 内边距，宁可拉长滚动也不挤；
/// * 不写解释段落（规范在 `docs/specs/2026-10-10-dsanima-neo-theme.md` 里，这里只展示）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/error_text.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import 'widgets/ds_spinner.dart';
import 'widgets/neo.dart';
import 'widgets/neo_appearance_picker.dart';
import 'widgets/state_views.dart';

/// 组间距（留白优先）。
const double _kGroupGap = 40;

/// 组内边距。
const double _kGroupPad = 24;

class PreviewPage extends ConsumerWidget {
  const PreviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DsTokens t = context.ds;
    final DsAppearance appearance = ref.watch(themeAppearanceProvider);

    return Scaffold(
      backgroundColor: t.base,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // ── 顶栏：8 套外观选择器（两行，所以比普通工具条高一倍）──────────
            Container(
              height: 88,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              decoration: BoxDecoration(
                color: t.raised,
                border: Border(bottom: BorderSide(color: t.divider)),
              ),
              child: Row(
                children: <Widget>[
                  Text('组件总览',
                      style: TextStyle(
                          color: t.text,
                          fontSize: DsTypeScale.display,
                          fontWeight: FontWeight.w600,
                          height: 1.25)),
                  const SizedBox(width: 16),
                  Text('扁平 v1',
                      style: TextStyle(
                          color: t.text3, fontSize: DsTypeScale.caption)),
                  const Spacer(),
                  NeoAppearancePicker(
                    keyPrefix: 'preview-appearance',
                    value: appearance,
                    // 总览页（`--preview`）只用来配色板，不演动画。
                    onChanged: (DsAppearance a, Offset _) => ref
                        .read(settingsProvider.notifier)
                        .patch((s) => s.copyWith(themeId: a.code)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(32, 32, 32, 64),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _Group(
                      title: '面与阴影',
                      child: Wrap(
                        spacing: 24,
                        runSpacing: 24,
                        children: <Widget>[
                          _Tile(name: 'base', color: t.base),
                          _Tile(name: 'raised', color: t.raised),
                          _Tile(name: 'sunken', color: t.sunken),
                          // 扁平化（决策 F1/F9）：面 + 1px 描边是常态，阴影只剩悬浮层一档。
                          _ShadowTile(name: '面 + 1px line'),
                          _ShadowTile(name: 'high · 悬浮层', overlay: true),
                        ],
                      ),
                    ),
                    _Group(
                      title: '凹槽',
                      child: Wrap(
                        spacing: 24,
                        runSpacing: 20,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          SizedBox(
                            width: 220,
                            child: DsInset(
                              height: 44,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 14),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text('空',
                                    style: TextStyle(
                                        color: t.text3,
                                        fontSize: DsTypeScale.body)),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 220,
                            child: DsInset(
                              height: 44,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 14),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text('有内容',
                                    style: TextStyle(
                                        color: t.text,
                                        fontSize: DsTypeScale.body)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 220, child: NeoSlider(value: 62)),
                          SizedBox(
                            width: 220,
                            child: NeoProgress(value: 0.62, label: '62%'),
                          ),
                          SizedBox(
                            width: 220,
                            child: NeoProgress(
                                value: 0.31, color: t.warning, label: '31%'),
                          ),
                        ],
                      ),
                    ),
                    _Group(
                      title: '加载态（iOS 风格圆环）',
                      child: Wrap(
                        spacing: 32,
                        runSpacing: 20,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          _SpinnerTile(
                              name: '页面 16 · 带底轨',
                              child: DsSpinner.page()),
                          _SpinnerTile(name: '行内 14', child: DsSpinner.inline()),
                          _SpinnerTile(name: '按钮 13', child: DsSpinner.button()),
                          const NeoButton(label: '正在准备…', busy: true),
                          const SizedBox(
                              width: 260, child: DsLoading(label: '加载中…')),
                        ],
                      ),
                    ),
                    _Group(
                      title: '按钮',
                      child: Wrap(
                        spacing: 16,
                        runSpacing: 16,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          NeoButton(label: '次按钮', onPressed: () {}),
                          NeoButton(
                              label: '主按钮',
                              kind: NeoButtonKind.primary,
                              icon: Icons.play_arrow,
                              onPressed: () {}),
                          NeoButton(
                              label: '危险',
                              kind: NeoButtonKind.danger,
                              icon: Icons.delete_outline,
                              onPressed: () {}),
                          NeoButton(label: '禁用', onPressed: null),
                          const NeoButton(label: '忙', busy: true),
                          NeoButton(
                              label: '小号', compact: true, onPressed: () {}),
                          NeoIconButton(
                              icon: Icons.settings_outlined, onPressed: () {}),
                          const NeoIconButton(
                              icon: Icons.close, selected: true),
                        ],
                      ),
                    ),
                    _Group(
                      title: '开关 / 分段 / 滑块',
                      child: Wrap(
                        spacing: 32,
                        runSpacing: 20,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          NeoSwitch(value: true, onChanged: (_) {}),
                          NeoSwitch(value: false, onChanged: (_) {}),
                          NeoSegmented<String>(
                            options: const <String>['全部', '有更新', '下载中'],
                            value: '有更新',
                            onChanged: (_) {},
                          ),
                          SizedBox(width: 220, child: NeoSlider(value: 40)),
                        ],
                      ),
                    ),
                    _Group(
                      title: '标签与状态',
                      child: Wrap(
                        spacing: 16,
                        runSpacing: 16,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          NeoPill(label: '1080p'),
                          NeoPill(
                              label: '超分 · 标准',
                              icon: Icons.auto_awesome,
                              color: t.accent,
                              selected: true),
                          NeoPill(label: '合集', color: t.warning),
                          NeoPill(label: '可点', icon: Icons.touch_app, onTap: () {}),
                          const SizedBox(width: 8),
                          Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                            NeoDot(color: t.success),
                            const SizedBox(width: 8),
                            NeoDot(color: t.warning),
                            const SizedBox(width: 8),
                            NeoDot(color: t.danger),
                          ]),
                        ],
                      ),
                    ),
                    _Group(
                      title: '语义色',
                      child: Wrap(
                        spacing: 32,
                        runSpacing: 16,
                        children: <Widget>[
                          for (final (String label, Color c)
                              in <(String, Color)>[
                            // 用户 2026-10-11「把做种数去掉」：这一组原来拿「做种 12/3/0」
                            // 当语义色样例。做种数不再上屏，样例换成现在界面上真实存在的
                            // 四个状态字（可播 / 已完成 / 引擎未连接 / 无磁力链），
                            // 免得总览页还教人认一个已经不在界面里的数字。
                            ('可播', t.success),
                            ('已完成', t.success),
                            ('引擎未连接', t.danger),
                            ('无磁力链', t.warning),
                            ('强调', t.accent),
                          ])
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                NeoDot(color: c, size: 8),
                                const SizedBox(width: 8),
                                Text(label,
                                    style: TextStyle(
                                        color: c,
                                        fontSize: DsTypeScale.body,
                                        fontWeight: FontWeight.w600,
                                        fontFeatures: DsTokens.tabular)),
                              ],
                            ),
                        ],
                      ),
                    ),
                    _Group(
                      title: '输入框',
                      child: Wrap(
                        spacing: 20,
                        runSpacing: 24,
                        children: <Widget>[
                          const SizedBox(
                              width: 260,
                              child: TextField(
                                decoration:
                                    InputDecoration(hintText: '搜索番剧'),
                              )),
                          const SizedBox(
                              width: 260,
                              child: TextField(
                                decoration: InputDecoration(hintText: '聚焦态'),
                              )),
                          const SizedBox(
                            width: 260,
                            child: TextField(
                              decoration: InputDecoration(
                                hintText: '错误态',
                                errorText: '标题为空',
                              ),
                            ),
                          ),
                          const SizedBox(
                              width: 260,
                              child: TextField(
                                enabled: false,
                                decoration: InputDecoration(hintText: '禁用态'),
                              )),
                        ],
                      ),
                    ),
                    _Group(
                      title: '卡片',
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Expanded(
                            child: NeoSurface(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text('列表卡片',
                                      style: TextStyle(
                                          color: t.text,
                                          fontSize: DsTypeScale.body,
                                          fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 10),
                                  Text('列表内用这一档，模糊 ≤ 2px。',
                                      style: TextStyle(
                                          color: t.text2,
                                          fontSize: DsTypeScale.secondary)),
                                  const SizedBox(height: 16),
                                  Row(children: <Widget>[
                                    NeoButton(
                                        label: '次',
                                        compact: true,
                                        onPressed: () {}),
                                    const SizedBox(width: 8),
                                    NeoButton(
                                        label: '主',
                                        kind: NeoButtonKind.primary,
                                        compact: true,
                                        onPressed: () {}),
                                  ]),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 24),
                          Expanded(
                            child: NeoSurface(
                              onTap: () {},
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text('可点卡片',
                                      style: TextStyle(
                                          color: t.text,
                                          fontSize: DsTypeScale.body,
                                          fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 10),
                                  Text('点一下看按下效果。',
                                      style: TextStyle(
                                          color: t.text2,
                                          fontSize: DsTypeScale.secondary)),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    _Group(title: '表格', child: _DemoTable()),
                    _Group(
                      title: '空态与错误',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          SizedBox(
                            height: 260,
                            child: Row(
                              children: <Widget>[
                                const Expanded(
                                  child: DsEmpty(
                                    icon: Icons.search,
                                    title: '还没有内容',
                                    message: '到「搜索」页找一集。',
                                  ),
                                ),
                                Expanded(
                                  child: DsErrorPanel(
                                    failure: const DsFailure(
                                      '引擎未连接',
                                      hint: '到「设置 → 引擎」检查边车路径',
                                    ),
                                    onRetry: () {},
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    _Group(
                      title: '提示条',
                      child: Wrap(
                        spacing: 20,
                        runSpacing: 20,
                        children: <Widget>[
                          SizedBox(
                            width: 340,
                            child: NeoBanner(
                                text: '已保存，重启边车后生效',
                                kind: NeoBannerKind.info),
                          ),
                          SizedBox(
                            width: 340,
                            child: NeoBanner(
                                text: '订阅已添加', kind: NeoBannerKind.success),
                          ),
                          SizedBox(
                            width: 340,
                            child: NeoBanner(
                                text: '磁盘剩余 2.1 GB',
                                kind: NeoBannerKind.warning),
                          ),
                          SizedBox(
                            width: 340,
                            child: NeoBanner(
                                text: '边车启动超时（exit=2）',
                                kind: NeoBannerKind.error),
                          ),
                        ],
                      ),
                    ),
                    _Group(
                      title: '弹窗与菜单',
                      child: Wrap(
                        spacing: 16,
                        runSpacing: 16,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          NeoButton(
                            label: '打开对话框',
                            kind: NeoButtonKind.primary,
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (BuildContext ctx) => AlertDialog(
                                title: const Text('确认删除这一集？'),
                                content: const Text('已缓存的部分会丢失。'),
                                actions: <Widget>[
                                  TextButton(
                                      onPressed: () => Navigator.of(ctx).pop(),
                                      child: const Text('取消')),
                                  FilledButton(
                                      onPressed: () => Navigator.of(ctx).pop(),
                                      child: const Text('删除')),
                                ],
                              ),
                            ),
                          ),
                          PopupMenuButton<String>(
                            itemBuilder: (BuildContext ctx) =>
                                <PopupMenuEntry<String>>[
                              const PopupMenuItem<String>(
                                  value: 'a', child: Text('全屏')),
                              const PopupMenuItem<String>(
                                  value: 'b', child: Text('音轨')),
                            ],
                            child: NeoSurface(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 12),
                              child: Text('右键菜单',
                                  style: TextStyle(
                                      color: t.text,
                                      fontSize: DsTypeScale.body)),
                            ),
                          ),
                          const Tooltip(
                            message: '工具提示',
                            child: Padding(
                              padding: EdgeInsets.all(12),
                              child: Text('悬停看提示'),
                            ),
                          ),
                        ],
                      ),
                    ),
                    _Group(
                      title: '字号阶梯',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          // 只列 5 档的名字与数字，不再解释用途（规范里有）。
                          Row(
                            children: <Widget>[
                              for (final double size in DsTypeScale.all)
                                Padding(
                                  padding: const EdgeInsets.only(right: 28),
                                  child: Text(
                                    size.toStringAsFixed(0),
                                    style: TextStyle(
                                        color: t.text,
                                        fontSize: size,
                                        fontFeatures: DsTokens.tabular),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text('0123456789 · 正文示例',
                              style: TextStyle(
                                  color: t.text2,
                                  fontSize: DsTypeScale.body,
                                  fontFeatures: DsTokens.tabular)),
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

/// 一个圆环 + 底下那行小字（说明它是哪一档尺寸）。
class _SpinnerTile extends StatelessWidget {
  const _SpinnerTile({required this.name, required this.child});

  final String name;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        child,
        const SizedBox(height: 10),
        Text(name,
            style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption)),
      ],
    );
  }
}

/// 一组组件：标题 + 一块留白充足的展示面板。
class _Group extends StatelessWidget {
  const _Group({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return Padding(
      padding: const EdgeInsets.only(bottom: _kGroupGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 14),
            child: Text(title,
                style: TextStyle(
                    color: t.text,
                    fontSize: DsTypeScale.title,
                    fontWeight: FontWeight.w600)),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(_kGroupPad),
            decoration: BoxDecoration(
              color: t.base,
              borderRadius: BorderRadius.circular(t.radiusCard),
              border: Border.all(color: t.line, width: 1),
            ),
            child: child,
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.name, required this.color});

  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return Container(
      width: 132,
      height: 84,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(t.radiusControl),
      ),
      child: Text(name,
          style: TextStyle(color: t.text, fontSize: DsTypeScale.caption)),
    );
  }
}

/// 演示瓦片：扁平化后**只演示两件事** —— 「面 + 1px line」是常态，阴影只剩悬浮层一档
/// （决策 F1/F9；旧的四档阴影阶梯已随新拟态删除）。
class _ShadowTile extends StatelessWidget {
  const _ShadowTile({required this.name, this.overlay = false});

  final String name;

  /// true = 按悬浮层画（`high` 阴影）；false = 普通面 + 1px `line` 描边。
  final bool overlay;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return Container(
      width: 132,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: t.raised,
        borderRadius: BorderRadius.circular(t.radiusControl),
        border: Border.all(color: t.line, width: 1),
        boxShadow:
            overlay ? t.shadows(NeoShadowLevel.high) : const <BoxShadow>[],
      ),
      child: Text(name,
          style: TextStyle(color: t.text, fontSize: DsTypeScale.caption)),
    );
  }
}

class _DemoTable extends StatelessWidget {
  const _DemoTable();

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    // 第三列从「做种数」换成「状态」，与搜索结果表同构：用户 2026-10-11
    //「把做种数去掉」后，总览页不该再拿一个界面上已经删掉的数字当样例
    //（语义色这一课由「可播 / 无磁力链 / 引擎未连接」三个真实状态字来上）。
    const List<(String, String, String)> rows = <(String, String, String)>[
      ('遭到流放的转生重骑士', '1.4 GB', '可播'),
      ('公主殿下，「拷问」的时间到了', '380 MB', '无磁力链'),
      ('SPY×FAMILY Season 3', '1.1 GB', '引擎未连接'),
    ];
    return Container(
      decoration: BoxDecoration(
        color: t.raised,
        borderRadius: BorderRadius.circular(t.radiusCard),
        border: Border.all(color: t.line, width: 1),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: Row(
              children: <Widget>[
                Expanded(flex: 5, child: Text('标题', style: dsTableHeaderStyle(t))),
                Expanded(flex: 2, child: Text('大小', style: dsTableHeaderStyle(t))),
                Expanded(flex: 2, child: Text('状态', style: dsTableHeaderStyle(t))),
              ],
            ),
          ),
          Divider(height: 1, color: t.divider),
          for (final (String a, String b, String c) in rows)
            _DemoRow(a: a, b: b, c: c),
        ],
      ),
    );
  }
}

class _DemoRow extends StatefulWidget {
  const _DemoRow({required this.a, required this.b, required this.c});

  final String a;
  final String b;
  final String c;

  @override
  State<_DemoRow> createState() => _DemoRowState();
}

class _DemoRowState extends State<_DemoRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    // 状态字的配色与真实表格一致（可播=成功、无磁力链=警告、引擎未连接=失败）。
    final Color statusColor = switch (widget.c) {
      '可播' => t.success,
      '无磁力链' => t.warning,
      _ => t.danger,
    };
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        decoration: BoxDecoration(
          color: _hover ? t.sunken.withValues(alpha: 0.6) : Colors.transparent,
          border: Border(bottom: BorderSide(color: t.divider)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
        child: Row(
          children: <Widget>[
            Expanded(
              flex: 5,
              child: Text(widget.a,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.text, fontSize: DsTypeScale.body)),
            ),
            Expanded(
                flex: 2,
                child: Text(widget.b,
                    style: TextStyle(
                        color: t.text2,
                        fontSize: DsTypeScale.secondary,
                        fontFeatures: DsTokens.tabular))),
            Expanded(
              flex: 2,
              child: Text(widget.c,
                  style: TextStyle(
                      color: statusColor,
                      fontSize: DsTypeScale.secondary))),
          ],
        ),
      ),
    );
  }
}
