/// 设置页新增的「观看记录 · 播放器」分组（第二十七轮）。
///
/// 用户这一轮要求：
/// > 「超 30 天自动移除，可在设置内更改删除时间或不删除」
/// > 「添加观看进度逻辑同观看记录一起记录，可在设置关闭」
/// > 「画面正中仍不唤起逻辑可在设置中关闭」
///
/// 所以这里钉三件事：默认档位（**第三十三轮起 = 不删除** / 记进度开 / 画面正中间不唤起）、
/// 三处都能改、改完点「保存并生效」真的落盘。
library;

import 'dart:io';

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/domain/watch_history.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/theme/tokens.dart';
import 'package:dsanima/ui/settings_page.dart';
import 'package:dsanima/ui/widgets/neo.dart';
import 'package:dsanima/ui/widgets/neo_dropdown.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Lifecycle implements LifecyclePort {
  @override
  Future<void> applySettings(AppSettings settings) async {}
}

InMemoryKeyValueStore _store() => InMemoryKeyValueStore(<String, Object?>{
  SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
});

AppSettings _saved(InMemoryKeyValueStore store) => AppSettings.fromJson(
  (store.get(SettingsController.storageKey) as Map?)?.cast<Object?, Object?>(),
);

Widget _harness(InMemoryKeyValueStore store) => ProviderScope(
  overrides: [
    keyValueStoreProvider.overrideWithValue(store),
    supportDirProvider.overrideWithValue(Directory.systemTemp),
    lifecyclePortProvider.overrideWithValue(_Lifecycle()),
    pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
    subsPortProvider.overrideWithValue(const UnavailableSubsPort()),
    queuePortProvider.overrideWithValue(const UnavailableQueuePort()),
  ],
  child: MaterialApp(
    theme: buildDsanimaTheme(),
    home: const Scaffold(body: SettingsPage()),
  ),
);

Finder _switch(String label) => find.widgetWithText(SwitchListTile, label);

Future<void> _save(WidgetTester tester) async {
  // 底部保存条在页面最下面：页面滚到上面的分组时它不在视口里，直接 tap 会打空
  // （第二十九轮加外观区用例时踩到：点了"保存并生效"但什么都没落盘）。
  await tester.ensureVisible(find.byKey(dsSettingsSaveKey));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(dsSettingsSaveKey));
  await tester.pumpAndSettle();
}

/// 第 ④ 组在设置页最下面：`ListView` 只建可见的 child，不滚过去 `find` 是找不到的。
Future<void> _scrollToHistorySection(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('记录保留'),
    320,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('「观看记录 · 播放器」分组在：默认 30 天 / 记进度开 / 画面正中间不唤起', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(_store()));
    await tester.pumpAndSettle();
    await _scrollToHistorySection(tester);

    // 分组标题 + 两个区块都在（第二十七轮新增的第 ④ 组）。
    expect(find.textContaining('观看记录 · 播放器'), findsOneWidget);
    expect(find.text('记录保留'), findsOneWidget);
    expect(find.text('不删除'), findsOneWidget,
        reason: '第三十三轮默认改成不删除（用户：「历史记录从默认30天改为不删」）');
    expect(_switch('记录观看进度'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(_switch('记录观看进度')).value, isTrue,
        reason: '默认记进度');
    expect(tester.widget<SwitchListTile>(_switch('鼠标移到画面正中也叫出控制栏')).value, isFalse,
        reason: '默认保持第十四/二十六轮的语义：画面正中不唤起');
    // 档位清单里有「不删除」（用户：「或不删除」）。
    expect(kHistoryRetentionDays, containsAll(<int>[7, 30, 90, 0]));
  });

  testWidgets('改档位 + 关掉记进度 + 打开「画面正中唤起」→ 保存后真的落盘', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final InMemoryKeyValueStore store = _store();
    await tester.pumpWidget(_harness(store));
    await tester.pumpAndSettle();
    await _scrollToHistorySection(tester);

    // 记录保留：默认（不删除）→ 7 天（第三十三轮起默认档就是"不删除"，
    // 所以这一条改成选另一档，手动保存的语义照样被钉住）。
    await tester.tap(find.byType(NeoDropdown<int>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('7 天').last);
    await tester.pumpAndSettle();
    expect(find.text('7 天'), findsOneWidget);

    // 关掉记进度 + 打开画面正中唤起。
    await tester.tap(_switch('记录观看进度'));
    await tester.pumpAndSettle();
    await tester.tap(_switch('鼠标移到画面正中也叫出控制栏'));
    await tester.pumpAndSettle();

    // 没点保存之前，盘上还是原来的值（手动保存）。
    expect(_saved(store).historyRetentionDays, 0, reason: '默认 = 不删除，且还没落盘');

    await _save(tester);
    final AppSettings saved = _saved(store);
    expect(saved.historyRetentionDays, 7, reason: '刚选的档位真的落盘了');
    expect(saved.recordWatchProgress, isFalse);
    expect(saved.wakeChromeAtCenter, isTrue);
  });

  testWidgets('「不删除」的档位文案说实话（不写"30 天"）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(InMemoryKeyValueStore(<String, Object?>{
      SettingsController.storageKey: const AppSettings(
        firstRunCompleted: true,
        historyRetentionDays: 0,
      ).toJson(),
    })));
    await tester.pumpAndSettle();
    await _scrollToHistorySection(tester);

    expect(find.text('不删除'), findsOneWidget);
    expect(find.textContaining('不自动删除：记录会一直留在这台机器上'), findsOneWidget);
  });

  testWidgets('外观区：8 格选择器 + 封面大小/轮播封面/轮播大小三行；「简洁模式」已删除（F6/F16/F23/F24）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final InMemoryKeyValueStore store = _store();
    await tester.pumpWidget(_harness(store));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('封面大小'),
      320,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    for (final DsAppearance a in DsAppearance.values) {
      expect(find.byKey(Key('settings-appearance-${a.code}')), findsOneWidget,
          reason: '缺 $a 这一格');
    }
    expect(find.text('简洁模式'), findsNothing, reason: '决策 F16：简洁模式开关整块删除');
    expect(find.text('封面大小'), findsOneWidget);
    expect(find.text('轮播封面'), findsOneWidget);
    expect(find.text('轮播大小'), findsOneWidget);

    // 四项都改掉：外观 → 紫白、封面大小 → 大、轮播封面 → 竖版、轮播大小 → 小。
    //
    // ⚠️ 每次点之前都要 `ensureVisible`：这一页很长，滚到「封面大小」时上面的选择器
    // 已经滚出视口，直接 `tap` 会打空（第二十九轮第一版就是这么"点了没反应"的）。
    Future<void> tapVisible(Finder f) async {
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    await tapVisible(find.byKey(const Key('settings-appearance-w_purple')));
    await tapVisible(find.descendant(
      of: find.byType(NeoSegmented<DsCoverSize>),
      matching: find.text('大'),
    ));
    await tapVisible(find.descendant(
      of: find.byType(NeoSegmented<DsCarouselShape>),
      matching: find.text('竖版'),
    ));
    await tapVisible(find.descendant(
      of: find.byType(NeoSegmented<DsCarouselSize>),
      matching: find.text('小'),
    ));

    // ⚠️ 第三十三轮：**外观破了"只动草稿"这条规矩**（用户：「点击外观直接转换，
    // 不用点保存」）—— 点一下就必须已经落盘；而同一页的其它项照旧等保存。
    expect(_saved(store).themeId, 'w_purple', reason: '外观点一下立刻生效并落盘');
    expect(_saved(store).homeCoverSize, 'm', reason: '封面大小仍然只动草稿');

    await _save(tester);

    expect(_saved(store).themeId, 'w_purple');
    expect(_saved(store).homeCoverSize, 'l');
    expect(_saved(store).carouselShape, 'portrait');
    expect(_saved(store).carouselSize, 's');
  });
}
