/// 轮播状态（决策 F14）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 轮播是否自动播放。
///
/// 默认 `true`（真机行为）；**测试里一律 `overrideWithValue(false)`** —— 自动播放是
/// 唯一允许的"常驻循环"，它会让 `pumpAndSettle` 永远不 settle（规范 §2 第 4 条 / §8.4）。
/// 想验自动播放的用例请用精确 `pump(interval)` 断言，别用 `pumpAndSettle`。
final Provider<bool> carouselAutoPlayProvider = Provider<bool>((Ref ref) => true);
