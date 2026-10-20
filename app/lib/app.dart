/// DSAnima 应用根：新拟态双外观（浅色默认 / 深色备用）+ 首启向导 / 主外壳切换。
///
/// 规范：`docs/specs/2026-10-10-dsanima-neo-theme.md`。
///
/// 为什么不用 shikiin 的 `ShikiinApp`：宿主外壳要按自己的 token 渲染，所以自己起
/// `MaterialApp`；播放器那半边走 shikiin（`shikiinOverrides` 注入实例）。
///
/// **换外观的过渡（第三十三轮改成 Circular Reveal）**：
/// * `themeAnimationDuration` = **0**：不做颜色插值 —— 白底黑字 ⇄ 黑底白字插到一半
///   两边都是中灰，文字与背景同色，用户报的「黑白字消失」就是这么来的（见
///   [kDsThemeAnimationDuration] 的注释）；
/// * `builder` 里套一层 [DsThemeRevealHost]：点外观时拍下旧界面，新配色立刻生效，
///   旧界面以一张快照被一个从**点击处**张开的圆逐步揭开（Android `createCircularReveal`
///   的语义）。提醒：这一层**不会**重建业务树 —— 第一子永远是业务树本身，
///   快照只是一个兄弟层（早先那版"用 `ClipPath` 包住整棵树"就是因为换包裹 widget
///   把整棵树重挂了一次：状态丢失 + 闪一下）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'domain/episode_group.dart';
import 'domain/error_text.dart';
import 'domain/models.dart';
import 'state/playback.dart';
import 'state/providers.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';
import 'ui/drop_intake.dart';
import 'ui/first_run.dart';
import 'ui/preview_page.dart';
import 'ui/shell.dart';
import 'ui/widgets/ds_theme_reveal.dart';
import 'ui/widgets/global_failure_listener.dart';

/// 外观切换的**颜色插值**时长：第三十三轮起是 **0**（不做插值）。
///
/// 用户 2026-10-15 第三十三轮：「点击外观直接转换，不用点保存，使用动画Circular Reveal」+
/// 「处于白色系时点击黑白，会出现黑白字消失的问题，可能是颜色混一起了」。
///
/// 那个"字消失"的真身就是颜色插值：白底黑字 → 黑底白字，`Color.lerp(白, 黑, 0.5)`
/// **两边都是中灰**，中点上文字与背景同色。所以这里**不再让 MaterialApp 插值**，
/// 换成 [DsThemeRevealHost] 的圆形揭开（新配色一步到位，旧界面以快照形式被揭开）——
/// 每一帧每个像素只可能是"旧配色"或"新配色"，不存在中间色，这条塌陷路径被结构性删掉。
///
/// 播放器子窗口（独立引擎、自己一套 token）仍走它自己的 [kDsTokenFadeDuration]。
const Duration kDsThemeAnimationDuration = Duration.zero;

/// 启动失败窗口里那句「为什么」的 key（单测据此断言，不靠中文匹配整页）。
const Key dsStartupFailureTextKey = Key('ds-startup-failure-text');

/// 启动装配失败时的**最小窗口**：只有「为什么」和「怎么办」。
///
/// 为什么必须有它：最常见的启动失败是"已经有一个 DSAnima 在后台常驻"—— Hive 的
/// `dsanima` box 锁被占着，`HiveKeyValueStore.open()` 直接抛 `PathAccessException`。
/// 旧代码让这个异常从 `main()` 冒出去：进程结束、窗口起不来，用户双击图标看到的是
/// **什么都没有**（没有窗口、没有托盘、没有提示），只能以为程序坏了。
/// 网络并发导致的 `PathAccessException`（同一份数据目录被两个进程抢）也走这条路。
class DsStartupFailureApp extends StatelessWidget {
  const DsStartupFailureApp({super.key, required this.failure});

  final DsFailure failure;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'DSAnima 启动失败',
      theme: buildDsanimaTheme(),
      home: Builder(
        builder: (BuildContext context) {
          final DsTokens t = context.ds;
          return Scaffold(
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'DSAnima 没能启动',
                        style: TextStyle(
                          color: t.text,
                          fontSize: DsTypeScale.title,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        failure.message,
                        key: dsStartupFailureTextKey,
                        style: TextStyle(color: t.text2, fontSize: DsTypeScale.body, height: 1.5),
                      ),
                      if (failure.hint != null) ...<Widget>[
                        const SizedBox(height: 10),
                        Text(
                          '怎么办：${failure.hint}',
                          style: TextStyle(
                            color: t.text2,
                            fontSize: DsTypeScale.body,
                            height: 1.5,
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Text(
                        '若是「已经有一个 DSAnima 在跑」：从系统托盘的 DSAnima 图标把它退出'
                        '（或等上一次的进程退干净）再启动。设置库文件在数据目录的 store 下。',
                        style: TextStyle(
                          color: t.textDim,
                          fontSize: DsTypeScale.secondary,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class DsanimaApp extends ConsumerWidget {
  const DsanimaApp({super.key, this.previewMode = false});

  /// `--preview` / `DSANIMA_PREVIEW=1`：直接进组件总览页（决策 A36）。
  final bool previewMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DsTokens tokens = ref.watch(themeTokensProvider);
    return MaterialApp(
      navigatorKey: dsNavigatorKey,
      debugShowCheckedModeBanner: false,
      title: previewMode ? 'DSAnima 组件总览' : 'DSAnima',
      theme: buildDsanimaTheme(tokens: tokens),
      themeAnimationDuration: kDsThemeAnimationDuration,
      themeAnimationCurve: Curves.easeOutCubic,
      // 圆形揭开的宿主：包在**整个 MaterialApp 内容**外面（含弹出的详情/对话框），
      // 这样"旧界面快照"盖住的是整窗，不会露出半边新半边旧的接缝。
      //
      // 再外面套一层 [DsGlobalFailureListener]（第四十二轮 §2.1）：未捕获异常原来只写
      // stderr，用户侧零反馈；这一层把它变成一条带「怎么办」的提示。位置就在
      // `ScaffoldMessenger` 里面、业务树与所有弹层外面 —— 向导页和主外壳都覆盖得到。
      //
      // 最外层再套一层 [DsDropIntake]（用户 2026-10-20：拖入视频直接播 / 拖入种子
      // 先确认再入队）。放在 builder 的最外面 = **整窗**都能接住拖放，包括正开着的
      // 对话框上面（`DropTarget` 靠 native 的 OLE 拖放，与 Flutter 的点击区域无关）。
      builder: (BuildContext context, Widget? child) => DsDropIntake(
        child: DsGlobalFailureListener(
          child: DsThemeRevealHost(child: child ?? const SizedBox.shrink()),
        ),
      ),
      home: _WindowEnvBridge(
        child: previewMode ? const PreviewPage() : const DsanimaHome(),
      ),
    );
  }
}

/// 把主窗口的「环境」推给弹出播放窗口。
///
/// 子窗口是**独立 Flutter 引擎**（独立 isolate）：它读不到主窗口的 provider 容器，
/// 所以外观（浅/深、简洁模式）与剧集分组只能由主窗口推过去。这里挂在
/// `MaterialApp.home` 外层，整个进程只挂一次，不参与任何页面的重建。
///
/// 没有播放窗口时 `pushArgs` 是空操作（不建窗口、不起 mpv）。
class _WindowEnvBridge extends ConsumerStatefulWidget {
  const _WindowEnvBridge({required this.child});

  final Widget child;

  @override
  ConsumerState<_WindowEnvBridge> createState() => _WindowEnvBridgeState();
}

class _WindowEnvBridgeState extends ConsumerState<_WindowEnvBridge> {
  @override
  Widget build(BuildContext context) {
    // 浅/深切换（决策 A6/B22：一套 token 贯穿两边）。
    ref.listen<DsTokens>(themeTokensProvider, (DsTokens? _, DsTokens next) {
      unawaited(ref
          .read(playerWindowServiceProvider)
          .pushArgs(tokens: encodeTokens(next)));
    });
    // 当前集所在的那一组变了（换集/换片）就重推一次。
    ref.listen<EpisodeGrouping?>(currentEpisodeGroupProvider,
        (EpisodeGrouping? _, EpisodeGrouping? next) {
      unawaited(ref.read(playerWindowServiceProvider).pushArgs(
            episodeGroup: encodeEpisodeGroup(
              next,
              autoNext: ref.read(settingsProvider).autoPlayNext,
            ),
          ));
    });
    // 「设置 → 播放器 → 画面正中也唤起」改了（第二十七轮）：正在开着的播放窗口要立刻
    // 跟上 —— 子窗口是独立 isolate，只能靠推送（同值不推由 `pushArgs` 把关）。
    ref.listen<bool>(
      settingsProvider.select((AppSettings s) => s.wakeChromeAtCenter),
      (bool? _, bool next) {
        unawaited(
            ref.read(playerWindowServiceProvider).pushArgs(wakeChromeAtCenter: next));
      },
    );
    // 播放窗口从「可见」变成「收起/关闭」= 这一集看完了：让队列收尾（下完 → 已完成，
    // 没下完 → 已暂停）并让引擎那一份停下。
    //
    // 为什么挂在这里：宿主以前**没有任何地方**监听这个变化 —— 用户关掉播放器后，点播
    // 建的那条队列任务永远停在"下载中"，边车也一直挂着那个 torrent（用户 2026-10-11
    // 「为什么队列里总是有东西」）。`_WindowEnvBridge` 整个进程只挂一次、不参与任何页面
    // 重建，正是这种"跨页面生命周期"该待的地方。
    ref.listen<bool>(playerWindowVisibleProvider, (bool? was, bool now) {
      if (was == true && !now) {
        unawaited(ref.read(playbackProvider.notifier).onPlayerWindowHidden());
        // 这里**不再对主窗口做任何事**（用户 2026-10-12 第八轮：「播放后不要去动主窗口」）。
        //
        // 原来这里还会把主窗口 `show()` 出来再 `focus()`，理由是"用户刚关掉播放器，
        // 接下来要操作的是主窗口"（起因是用户 2026-10-11 报"主窗口被播放窗口整个盖住"）。
        // 但那是**播放窗口落点**造成的，第七轮落点改成居中、播放窗口不再铺满整屏之后，
        // 这条补救就没必要了；而它本身是在动一扇用户没碰的窗口 —— 用户可能正在别的
        // 程序里操作，也不该被抢走焦点。现在播放全程（开窗 → 播放 → 收起/关闭）
        // 对主窗口**零操作**：不 show / focus / maximize / 移动 / 改尺寸。
        //
        // 守卫：`test/neo_guard_test.dart` 里有一条源码守卫盯着这件事，别再顺手加回来。
      }
    });
    return widget.child;
  }
}

/// 全局 Navigator（关窗询问对话框要在没有 widget context 的地方弹）。
final GlobalKey<NavigatorState> dsNavigatorKey = GlobalKey<NavigatorState>();

/// 首启未完成 → 向导；完成 → 主外壳。
class DsanimaHome extends ConsumerWidget {
  const DsanimaHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool needsFirstRun = ref.watch(needsFirstRunProvider);
    return needsFirstRun ? const FirstRunPage() : const DsShell();
  }
}
