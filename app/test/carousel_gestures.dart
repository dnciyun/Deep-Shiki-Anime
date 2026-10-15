/// 测试用：点轮播里**看得见的那张邻卡**。
///
/// 为什么不再用 `Key('carousel-neighbour-right')`（第三十三轮）：那个 key 的**侧别会变**
/// —— 同一张卡先当右邻卡、再当主卡 —— 而"随主卡轮换的 key"本身就是一次元素重建，
/// 正是用户报的「轮播切换时会闪烁」的成因之一（逐帧探针实测：一次切换整批重建 4 遍）。
/// 组件里因此**不再有侧别 key**，测试改成按**位置**点：
/// 邻卡中心 = 轮播块中点 ± `carouselSlotOffset(geometry)`，竖直方向与主卡同高
/// （Stack 是 `Alignment.center` 对齐的，主卡区就在轮播块顶部，高 = `main.height`）。
///
/// 这与用户做的事完全一致（他点的就是那半张露出来的卡），比认一个内部 key 更接近现场。
library;

import 'package:dsanima/theme/tokens.dart';
import 'package:dsanima/ui/widgets/ds_carousel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 点左/右侧半露的邻卡（**不**自动 pump，与 `tester.tap` 同语义）。
Future<void> tapCarouselNeighbour(
  WidgetTester tester, {
  required bool right,
  required DsCarouselGeometry geometry,
}) async {
  final Rect block = tester.getRect(find.byType(DsCarousel));
  await tester.tapAt(
    Offset(
      block.center.dx + (right ? 1 : -1) * carouselSlotOffset(geometry),
      block.top + geometry.main.height / 2,
    ),
  );
}
