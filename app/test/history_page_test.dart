/// 「观看记录」页（第二十七轮）：列表、进度、保留档位文案、导出/清空按钮的门槛。
///
/// 不联网、不起引擎：全部走内存 KV 与不可用端口。
library;

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/domain/watch_history.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/ui/history_page.dart';
import 'package:dsanima/ui/widgets/neo.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

WatchRecord _record({
  String id = 'mikan:3887|ANi|e8',
  String title = '葬送的芙莉莲',
  String group = 'ANi',
  int episode = 8,
  int positionMs = 600000,
  int durationMs = 1440000,
  DateTime? at,
}) => WatchRecord(
  id: id,
  title: title,
  group: group,
  episode: episode,
  watchedAt: at ?? DateTime.now().subtract(const Duration(hours: 3)),
  positionMs: positionMs,
  durationMs: durationMs,
  coverUrl: 'https://mikanani.me/images/Bangumi/x.jpg',
);

Widget _harness({
  required List<WatchRecord> records,
  int retentionDays = 30,
  bool recordProgress = true,
}) => ProviderScope(
  overrides: [
    keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore(<String, Object?>{
      SettingsController.storageKey: const AppSettings(firstRunCompleted: true)
          .copyWith(historyRetentionDays: retentionDays, recordWatchProgress: recordProgress)
          .toJson(),
      if (records.isNotEmpty)
        WatchHistoryStore.defaultKey:
            records.map((WatchRecord r) => r.toJson()).toList(growable: false),
    })),
    enginePortProvider.overrideWithValue(const UnavailableEnginePort()),
    queuePortProvider.overrideWithValue(const UnavailableQueuePort()),
    subsPortProvider.overrideWithValue(const UnavailableSubsPort()),
    playerPortProvider.overrideWithValue(const UnavailablePlayerPort()),
    pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
    sourcePortProvider.overrideWithValue(const UnavailableSourcePort()),
  ],
  child: MaterialApp(theme: buildDsanimaTheme(), home: const Scaffold(body: HistoryPage())),
);

void main() {
  testWidgets('空态：说明会记什么、并给出去处；导出/清空都点不动', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(records: const <WatchRecord>[]));
    await tester.pumpAndSettle();

    expect(find.text('还没有观看记录'), findsOneWidget);
    expect(find.textContaining('用播放器看过一集就会记在这里'), findsOneWidget);
    // 没有记录时两颗按钮都禁用（不能"点了没反应"）。
    NeoButton buttonNamed(String label) =>
        tester.widgetList<NeoButton>(find.byType(NeoButton)).firstWhere((NeoButton b) => b.label == label);
    expect(buttonNamed('导出观看记录').onPressed, isNull);
    expect(buttonNamed('清空').onPressed, isNull);
  });

  testWidgets('有记录：番名 / 集数 / 字幕组 / 进度都在，保留档位来自设置', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(records: <WatchRecord>[_record()]));
    await tester.pumpAndSettle();

    expect(find.text('1 条记录 · 保留 30 天'), findsOneWidget);
    expect(find.text('葬送的芙莉莲'), findsOneWidget);
    expect(find.text('第 08 集'), findsOneWidget);
    expect(find.text('ANi'), findsOneWidget);
    // 进度：看到 10:00 / 24:00（41%）。
    expect(find.textContaining('看到 10:00 / 24:00'), findsOneWidget);
    expect(find.textContaining('41%'), findsNothing);
    expect(find.textContaining('42%'), findsOneWidget, reason: '600/1440 秒 = 41.7% → 四舍五入 42%');
    expect(find.text('继续播放'), findsOneWidget);
    // 记进度开着时的说明文案。
    expect(find.textContaining('记进度：打开「设置 → 观看记录 · 播放器」可以关掉'), findsOneWidget);
  });

  testWidgets('「不删除」档位与「关掉记进度」都在页头说实话', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _harness(records: <WatchRecord>[_record(durationMs: 0, positionMs: 0)], retentionDays: 0, recordProgress: false),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 条记录 · 不自动删除'), findsOneWidget);
    expect(find.textContaining('只记时间不记进度'), findsOneWidget);
    // 时长未知时**不假装进度**：写明"时长未知"，也不显示百分比。
    expect(find.textContaining('没有进度记录'), findsOneWidget);
  });

  testWidgets('超出保留档位的那条在页面里就不出现（加载即清理）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(
      records: <WatchRecord>[
        _record(id: 'a', title: '过期的番', at: DateTime.now().subtract(const Duration(days: 40))),
        _record(id: 'b', title: '还留着的番'),
      ],
    ));
    await tester.pumpAndSettle();

    expect(find.text('还留着的番'), findsOneWidget);
    expect(find.text('过期的番'), findsNothing, reason: '超过 30 天的记录加载时就被清掉');
    expect(find.text('1 条记录 · 保留 30 天'), findsOneWidget);
  });

  testWidgets('常驻运行也能清：pruneNow 按当前档位清掉过期记录（不必重启）', (WidgetTester tester) async {
    // 复核抓到的口径问题：`build()` 只在 provider 重建时清 ⇒ 常驻不重启就是"启动时清理"。
    // 这里用 `pruneNow(retentionDays:, now:)` 这两条缝把"时间往后走"表达出来
    //（真实调用不带参数，走当前设置与当前时间）。
    final InMemoryKeyValueStore store = InMemoryKeyValueStore(<String, Object?>{
      // 档位 0 = 不删除：build 时不会把这条清掉，它才留在内存状态里。
      SettingsController.storageKey: const AppSettings(
        firstRunCompleted: true,
        historyRetentionDays: 0,
      ).toJson(),
      WatchHistoryStore.defaultKey: <Object?>[
        WatchRecord(
          id: 'old',
          title: '过期的番',
          watchedAt: DateTime(2026, 9, 1),
        ).toJson(),
      ],
    });
    final ProviderContainer container = ProviderContainer(
      overrides: [keyValueStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    expect(container.read(watchHistoryProvider), hasLength(1));

    // 时间走到 2026-10-14、档位选 30 天 → 这条该清。
    final int dropped = await container.read(watchHistoryProvider.notifier).pruneNow(
          retentionDays: 30,
          now: DateTime(2026, 10, 14),
        );
    expect(dropped, 1);
    expect(container.read(watchHistoryProvider), isEmpty);
    // 真的落到盘上（不是只清内存）。
    expect(WatchHistoryStore(store).load(), isEmpty);

    // 再清一次：没东西可清 → 0（不重复写盘）。
    expect(
      await container.read(watchHistoryProvider.notifier).pruneNow(
            retentionDays: 30,
            now: DateTime(2026, 10, 14),
          ),
      0,
    );
  });
}
