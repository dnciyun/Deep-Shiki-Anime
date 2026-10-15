/// 主页状态：mikan 追番更新表（spec §7.5）。
///
/// 两件事严格分开：
/// * [scheduleProvider] —— **一次拉全周**，切星期不再打站点；
/// * [selectedDayProvider] —— 只是「现在看星期几」，默认本机今天。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models.dart';
import '../domain/ports.dart';
import '../domain/unavailable.dart';

/// 主页数据端口。真实实现（core `MikanSource.schedule()`）由 main.dart 注入；
/// 未注入时是显式报错（[UnavailableSchedulePort]），不会显示空表装成「今天没更新」。
final Provider<SchedulePort> schedulePortProvider =
    Provider<SchedulePort>((Ref ref) => const UnavailableSchedulePort());

/// 追番表（整周）。切星期只换选中项，**不 invalidate 它**。
final FutureProvider<ScheduleView> scheduleProvider =
    FutureProvider<ScheduleView>((Ref ref) async {
  final SchedulePort port = ref.watch(schedulePortProvider);
  if (!port.isAvailable) {
    throw UnavailableSchedulePort.failure;
  }
  return port.schedule();
});

/// 番剧详情（`/Home/Bangumi/<id>`）：字幕组 + 剧集（带磁力，可入队播放）。
final bangumiDetailProvider =
    FutureProvider.family<BangumiDetailView, String>((Ref ref, String bangumiId) {
  final SchedulePort port = ref.watch(schedulePortProvider);
  if (!port.isAvailable) {
    throw UnavailableSchedulePort.failure;
  }
  return port.bangumi(bangumiId);
});

/// 「今天」（本地时间）。
///
/// 单独成 provider 是为了**可测**：测试 override 成固定日期，
/// 不用改系统时钟、也不会让断言随跑测试的日期漂移。
final Provider<DateTime> todayProvider =
    Provider<DateTime>((Ref ref) => DateTime.now());

/// 今天是星期几（0=周日…6=周六，与 core 的 `byDay` 同口径）。
final Provider<int> todayDowProvider =
    Provider<int>((Ref ref) => dsTodayDow(ref.watch(todayProvider)));

/// 主页选中的星期键（0=周日…6=周六，7/8=未定档）。**默认今天**。
class SelectedDayController extends Notifier<int> {
  @override
  int build() => ref.read(todayDowProvider);

  void select(int dayOfWeek) => state = dayOfWeek;
}

final NotifierProvider<SelectedDayController, int> selectedDayProvider =
    NotifierProvider<SelectedDayController, int>(SelectedDayController.new);
