/// 播放窗口的默认落点：**工作区正中间**（用户 2026-10-12：「播放器应该在中心位置出现」）。
///
/// 历史（别再改回去 —— 这条路来回走过一次）：
/// * 2026-10-10：播放窗口 `center: true` 且 1600×900，比主窗口（1375×850）大，
///   主窗口被 100% 盖住，用户报「只要启动了播放器，主窗口就没办法使用了」；
/// * 2026-10-11（第五/六轮）：于是改成"算一个不盖住主窗口的落点"。真机上主窗口
///   1100×680 居中后，两侧只剩 ~462 逻辑 px，播放窗口被挤成 462×260 甚至更小 ——
///   用户看到的是一个贴在工作区角落、小得看不清画面的窗；
/// * 2026-10-12（第七轮）：用户明确要求「播放器应该在中心位置出现」。
///   默认落点回到**居中**，并且**不再为了腾地方去动主窗口**（见下面那段）。
///
/// 三层兜底把"盖住主窗口"限制在可接受的范围内（**都不碰窗口尺寸**，
/// 所以不会像第五轮那把上限锁那样把全屏/拖边框一起夹死）：
/// 1. 默认尺寸是 [kPlayerWindowPreferredSize] 按工作区比例缩出来的，不会铺满整屏；
/// 2. 子窗口 `setMaximizable(false)`（去掉 `WS_MAXIMIZEBOX`），拖到屏幕顶边也不会 Aero Snap；
/// 3. 子窗口收到"被最大化"事件立刻退回（`player_window_app.dart` 的 `_undoMaximize`）。
///
/// **我们不再做什么**：原来主窗口铺满工作区时会先 `unmaximize()` 把它降回还原尺寸，
/// 好给播放窗口腾一块空地（收起播放器时再 `maximize()` 还原）。用户 2026-10-12 报的
/// 「点开播放后为什么会取消主窗口的最大化」就是它 —— 那是**用户自己的窗口状态**，
/// 我们不该在播放这条路上顺手改掉；而且落点改成居中之后，"腾地方"本身也没意义了。
///
/// 全部是**逻辑像素**（`window_manager.getBounds()` / `setBounds()` 与
/// `screen_retriever` 的 `Display.visiblePosition/visibleSize` 都是逻辑像素）。
library;

import 'dart:math';

import 'package:flutter/widgets.dart';

/// 播放窗口首选尺寸（16:9）。
///
/// 960×540 是"够看"与"别铺满"之间的折中：真机 2560×1600 @125%（工作区 2048×1232 逻辑）
/// 上占工作区不到一半，还留得下主窗口的边；比它更小的屏幕会按工作区比例自动缩（见
/// [centeredPlayerWindowBounds]）。
const Size kPlayerWindowPreferredSize = Size(960, 540);

/// 播放窗口最小尺寸（默认落点与"记住的位置"都不得低于它）。
///
/// 为什么是 400×240 而不是更小：第六轮把播放器标题栏调到 40、控制栏调到 44
/// （用户原话「标题栏控制栏全都调大些，包括控件文字」），两条栏就吃掉 84px；
/// 再加上进度条/时间那一行的内边距，窗口低于约 240 高时视频画面只剩一条缝，
/// 用户点全屏之前根本看不清自己点的是哪一集。
///
/// 注意：这只是"开窗时别给太小"，**不是** `setMaximumSize` 那种上限
/// （上限会把全屏和拖边框一起夹死，见文件末尾那段"删掉 playerWindowMaxSize"的注释）。
const Size kPlayerWindowMinSize = Size(400, 240);

/// 默认尺寸最多占工作区的比例（每个方向各算一次）。
///
/// 0.8 是"居中但别把整屏吃掉"的上限：小屏笔记本（工作区 1366×768）上首选尺寸仍然放得下，
/// 所以这条平时不生效；它兜的是"工作区比首选尺寸还小"的情况（例如 1024×600 的小屏），
/// 那时按比例缩到 80% 以内，四周还能看见底下的窗口、也还能拖边框。
const double kPlayerWindowMaxAreaRatio = 0.8;

/// 播放窗口与工作区边缘的最小缝隙（居中时用不到，供将来贴边放置时统一口径）。
const double kPlayerWindowGap = 12;

/// 算播放窗口该出现在哪（逻辑像素坐标系，左上原点 = 显示器工作区左上角）。
///
/// [workArea] 目标显示器的工作区矩形（`Display.visiblePosition + visibleSize`，
/// 已排除任务栏）。返回的矩形保证：
/// 1. 完整落在 [workArea] 内；
/// 2. **水平垂直都居中**（这就是用户 2026-10-12 要的"中心位置"）；
/// 3. 尺寸 = [preferred] 按工作区 [kPlayerWindowMaxAreaRatio] 等比缩，
///    并且不低于 [minimum]（等比抬：直接把一个 16:9 的窗改成 5:3，画面立刻有黑边，
///    用户对黑边很敏感）。
///
/// 纯函数：无插件、无全局状态，单测直接喂矩形。
Rect centeredPlayerWindowBounds({
  required Rect workArea,
  Size preferred = kPlayerWindowPreferredSize,
  Size minimum = kPlayerWindowMinSize,
  double maxAreaRatio = kPlayerWindowMaxAreaRatio,
}) {
  final Rect area = _normalize(workArea);
  if (area.width <= 0 || area.height <= 0) {
    // 工作区还没测出来（插件最先几毫秒会给 0）：给首选尺寸，位置交给系统居中。
    return Rect.fromLTWH(area.left, area.top, preferred.width, preferred.height);
  }

  final double ratio = maxAreaRatio <= 0 ? 1 : maxAreaRatio;
  final double fit = min(
    1.0,
    min(
      (area.width * ratio) / preferred.width,
      (area.height * ratio) / preferred.height,
    ),
  );
  Size size = Size(preferred.width * fit, preferred.height * fit);

  // 低于最小尺寸就**等比**抬到最小尺寸；工作区本身比最小尺寸还小时不抬
  //（否则窗口会超出屏幕）。
  final double capW = min(minimum.width, area.width);
  final double capH = min(minimum.height, area.height);
  final double lift = max(capW / size.width, capH / size.height);
  if (lift > 1.0) size = Size(size.width * lift, size.height * lift);

  // 兜底：任何情况下都不许超出工作区（浮点误差 + 极小工作区）。
  size = Size(min(size.width, area.width), min(size.height, area.height));

  return Rect.fromLTWH(
    area.left + (area.width - size.width) / 2,
    area.top + (area.height - size.height) / 2,
    size.width,
    size.height,
  );
}

/// 开窗计划：**只是落点**。
///
/// 这里**故意不再算尺寸上限**（原来的 [playerWindowMaxSize] 已删除，见文件末尾注释）：
/// 用户 2026-10-11 第五次报「播放器全屏不了 / 右边拉不大」，真因就是那把上限锁。
@immutable
class PlayerWindowPlan {
  const PlayerWindowPlan({required this.bounds});

  /// 开窗落点与尺寸（逻辑像素）。
  final Rect bounds;
}

/// ⚠️ **这里原来有一个 `playerWindowMaxSize()`，2026-10-11 第五轮已删除，别再写回来。**
///
/// 它当时是这么想的：给播放窗口一个"落点所在那条空地"的尺寸上限
/// （右侧那条 462×260），于是最大化 / Aero Snap / 贴边都长不到主窗口身上。
///
/// 但它**锁死的正是用户要的东西**（用户 2026-10-11 第五次报的原话：
/// 「播放器全屏不了的 bug，无法……右边拉伸」）：
/// * 那把上限走 `WindowOptions.maximumSize` → `setMaximumSize` → 原生
///   `WM_GETMINMAXINFO` 的 `ptMaxTrackSize`；
/// * `ptMaxTrackSize` **不只管用户拖边框和最大化，它连 `SetWindowPos` 一起夹**
///   （本机实测：`ptMaxTrackSize=462x260` 的窗口在 `SetWindowPos(0,0,2560,1440)`
///   之后仍然是 462×260）；
/// * 而 `window_manager` 的"真全屏"就是 `SetWindowPos` 到显示器尺寸
///   （`window_manager.cpp` 的 `SetFullScreen`：`SetWindowPos(mainWindow, HWND_TOP, 0, 0,
///   rcMonitor 宽, rcMonitor 高, SWP_NOMOVE)`）——被同一把锁夹在原地。
///   表现就是：点全屏 / 双击画面没反应（窗口不长大），拖右边框也到 462 就顶死。
///
/// 所以封顶这条路整条撤掉，改由**不影响窗口尺寸**的三层兜底（见文件头注释）。
/// 以后想再"限制播放窗口长多大"，先想清楚它会不会再一次把全屏/拖边框一起夹掉。

/// 记住的落点还能不能直接用？
///
/// 用户自己拖出来的位置必须被尊重（否则每次播放都跳回原位，更烦人），但**不能无条件信**：
/// 用户 2026-10-11 那台机器上 store 里躺着的就是 `-7,-7 2062x1246`（主窗口最大化时的
/// 播放窗口矩形）—— 直接拿来用就是"开启播放器后整个程序都不能用了"。
///
/// 2026-10-12 起判据只剩两条（用户要求"播放器居中弹出"，所以**不再**拿"盖住主窗口"
/// 当否决理由 —— 居中本来就压在最大化的主窗口上）：
/// 0. 尺寸不能小到没用（[tooSmall]）—— 比它小的记录多半是第六轮之前被上限锁死的产物；
/// 1. 必须完整落在**目标工作区内**（旧记录可能来自另一块显示器 / 另一种分辨率）。
bool reusableSavedBounds({
  required Rect saved,
  required Rect workArea,
  /// 比这个还小的旧记录一律当坏记录（理由见函数注释第 0 条）。
  Size tooSmall = kPlayerWindowMinSize,
}) {
  if (saved.width < 1 || saved.height < 1) return false;
  if (saved.width < tooSmall.width || saved.height < tooSmall.height) return false;
  final Rect area = _normalize(workArea);
  const double slack = 1;
  if (saved.left < area.left - slack ||
      saved.top < area.top - slack ||
      saved.right > area.right + slack ||
      saved.bottom > area.bottom + slack) {
    return false;
  }
  return true;
}

/// 反着给的矩形（负宽高）在真机上出现过：统一成正的。
Rect _normalize(Rect r) => Rect.fromLTRB(
      min(r.left, r.right),
      min(r.top, r.bottom),
      max(r.left, r.right),
      max(r.top, r.bottom),
    );

/// 找到包含 [point]（逻辑像素）的显示器工作区；都找不到时用第一个/主显示器。
Rect workAreaFor(List<({Offset position, Size size})> displays, Offset point) {
  if (displays.isEmpty) return const Rect.fromLTWH(0, 0, 1920, 1080);
  for (final ({Offset position, Size size}) d in displays) {
    final Rect r = Rect.fromLTWH(d.position.dx, d.position.dy, d.size.width, d.size.height);
    if (r.contains(point)) return r;
  }
  final ({Offset position, Size size}) first = displays.first;
  return Rect.fromLTWH(first.position.dx, first.position.dy, first.size.width, first.size.height);
}
