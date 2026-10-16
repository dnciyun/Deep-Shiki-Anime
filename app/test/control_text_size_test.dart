/// 「框里的字」尺寸契约（第四十六轮）。
///
/// 用户原话：
/// > 「优化一些框里字太大的问题，比如默认源 代理模式，动漫库的筛选年份等」
///
/// 三处各是一个**组件默认值**的坑，所以这一份按"哪一档、谁定的"来钉：
/// * **`NeoDropdown`**：默认从 `body`（15）改成 `caption`（12）—— 小凹槽控件里的字
///   一直是这一档（`NeoPill` / `NeoActionChip` / 队列页那几处都显式传了它），
///   动漫库右栏那 5 格、搜索页的源选择、追番详情的偏好分辨率都**没传**，
///   于是成了"同一排里最大的字"（出图：`build/probe-size/B_rail.png`）；
/// * **`NeoSegmented`**：同上（默认 15 → 12），设置页显式传 `kSettingsBodySize`（13），
///   否则「封面大小 / 轮播封面 / 轮播大小」那段比左边的行标题还大
///   （出图：`build/probe-size/C_segmented.png`）；
/// * **设置页的 4 个 Material `DropdownButtonFormField`**（代理模式 / 并发下载数 /
///   默认源 / 搜索模式）：不给 `style:` 就吃 `textTheme.titleMedium` = **17 + w600**，
///   比同一行的输入框（13）大一圈（出图：`build/probe-size/S_settings_network.png`）。
///
/// ⚠️ 这一条顺带钉住"字体族"：`DropdownButton` 把 `style:` **整份**当文字样式用
/// （不与主题 `textTheme` 合并），裸写 `TextStyle(fontSize: 13)` 会把
/// `fontFamily: dsFontFamily` 丢掉（探针里是一排方框）—— 所以断言里带 family。
library;

import 'dart:io';

import 'package:dsanima/domain/bangumi.dart';
import 'package:dsanima/domain/bangumi_library.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/state/library_provider.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/theme/tokens.dart';
import 'package:dsanima/ui/library_page.dart';
import 'package:dsanima/ui/settings_page.dart';
import 'package:dsanima/ui/widgets/neo.dart';
import 'package:dsanima/ui/widgets/neo_dropdown.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 动漫库页面：右栏那 5 格下拉 + 类型胶囊
// ─────────────────────────────────────────────────────────────────────────────

class _LibPort implements BangumiLibraryPort {
  @override
  bool get isAvailable => true;

  @override
  Future<BangumiLibraryPage> search(
    BangumiLibraryQuery query, {
    int offset = 0,
    int limit = kLibraryDefaultPageSize,
  }) async =>
      BangumiLibraryPage(
        items: <BangumiSubject>[
          BangumiSubject(
            id: 1,
            name: 'Frieren',
            nameCn: '葬送的芙莉莲',
            date: '2023-09-29',
            eps: 28,
            score: 8.5,
            rank: 43,
            ratingTotal: 36596,
            coverUrl: '',
            tags: const <String>['奇幻'],
            platform: 'TV',
            type: 2,
          ),
        ],
        total: 1,
        startOffset: 0,
        nextOffset: 1,
        hasMore: false,
      );

  @override
  Future<BangumiSubject> detail(int id) async =>
      (await search(const BangumiLibraryQuery())).items.first;

  @override
  Future<BangumiSubjectExtra> extras(int id) async => BangumiSubjectExtra.empty;
}

Future<void> _pumpLibrary(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 950);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore(<String, Object?>{})),
        bangumiLibraryProvider.overrideWithValue(_LibPort()),
      ],
      child: MaterialApp(
        theme: buildDsanimaTheme(),
        home: const Scaffold(body: LibraryPage()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 触发器里那行字的**实际**字号（`NeoDropdown` 的 `fontSize` 字段是"要它多小"，
/// 渲染出来是多少才算数）。
double? _triggerSize(WidgetTester tester, Key key) {
  final Finder text = find.descendant(of: find.byKey(key), matching: find.byType(Text));
  return (tester.widget<Text>(text.first).style)?.fontSize;
}

// ─────────────────────────────────────────────────────────────────────────────
// 设置页
// ─────────────────────────────────────────────────────────────────────────────

class _Sources extends UnavailableSourcePort {
  @override
  List<SourceOption> get sources => const <SourceOption>[
        SourceOption(id: 'mikan', displayName: 'Mikan（蜜柑计划）'),
        SourceOption(id: 'nyaa', displayName: 'Nyaa（动漫区）'),
      ];
}

class _Lifecycle implements LifecyclePort {
  @override
  Future<void> applySettings(AppSettings settings) async {}
}

Future<void> _pumpSettings(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 950);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyValueStoreProvider.overrideWithValue(
          InMemoryKeyValueStore(<String, Object?>{
            SettingsController.storageKey: const AppSettings(
              firstRunCompleted: true,
              downloadDir: r'F:\Anime',
            ).toJson(),
          }),
        ),
        supportDirProvider.overrideWithValue(Directory.systemTemp),
        lifecyclePortProvider.overrideWithValue(_Lifecycle()),
        pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
        subsPortProvider.overrideWithValue(const UnavailableSubsPort()),
        queuePortProvider.overrideWithValue(const UnavailableQueuePort()),
        sourcePortProvider.overrideWithValue(_Sources()),
      ],
      child: MaterialApp(
        theme: buildDsanimaTheme(),
        home: const Scaffold(body: SettingsPage()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 滚到某个锚点（`ListView` 是懒的，目标不在屏上时它根本不在树里）。
///
/// 为什么不用 `tester.scrollUntilVisible`（两个坑都踩过）：
/// * 它结尾用 `element(finder)` = `evaluate().single` —— 目标**一个都没建出来**时抛
///   `Bad state: No element`，**匹配到两个**时（`Text` + `TextContaining` 之类）抛
///   `Bad state: Too many elements`；
/// * 它只往一个方向拖，目标在当前位置上方时会一路拖到底。
///
/// 所以这里自己拖：空就继续往下拖，到位后用 `.first` 对齐。
Future<void> _scrollTo(WidgetTester tester, Finder anchor) async {
  for (int i = 0; i < 80 && anchor.evaluate().isEmpty; i++) {
    await tester.drag(find.byType(ListView).first, const Offset(0, -240));
    await tester.pumpAndSettle();
  }
  expect(anchor, findsWidgets, reason: '一路拖到底也没找到这个锚点');
  await tester.ensureVisible(anchor.first);
  await tester.pumpAndSettle();
}

/// 当下这屏里每一个 Material 下拉都必须"设置页的字号 + 主题字体族"。
int _expectDropdownsAtSettingsSize(WidgetTester tester) {
  final Finder finder = find.byWidgetPredicate(
    (Widget w) => w.runtimeType.toString().startsWith('DropdownButton<'),
  );
  final int n = finder.evaluate().length;
  for (final Element e in finder.evaluate()) {
    // ignore: avoid_dynamic_calls
    final dynamic w = e.widget;
    final TextStyle? style = w.style as TextStyle?;
    expect(
      style?.fontSize,
      kSettingsBodySize,
      reason: '设置页的 Material 下拉不给 style 就是 titleMedium（17）——'
          '比同一行的输入框（13）大一圈。',
    );
    expect(
      style?.fontFamily,
      dsFontFamily,
      reason: '这个 style 不与主题 textTheme 合并：裸写 TextStyle(...) 会把字体族丢掉，'
          '框里的字会掉回系统默认字体（探针里是一排方框）。',
    );
  }
  return n;
}

void main() {
  group('NeoDropdown：小凹槽控件里的字 = caption(12)', () {
    testWidgets('动漫库右栏那 5 格没传字号，也是 12（不是 body 的 15）', (WidgetTester tester) async {
      await _pumpLibrary(tester);

      const List<Key> triggers = <Key>[
        Key('library-year'),
        Key('library-quarter'),
        Key('library-form'),
        Key('library-sort'),
        Key('library-score'),
      ];
      for (final Key key in triggers) {
        expect(find.byKey(key), findsOneWidget, reason: '$key 应该还在右栏里');
        expect(
          _triggerSize(tester, key),
          DsTypeScale.caption,
          reason: '$key 的字号必须跟同一栏的「类型」胶囊（12）与上面那行小标题一致 —— '
              '这正是用户说的「动漫库的筛选年份」字太大。',
        );
      }
      // 参考：同一栏的胶囊也是 12（两者一致才算"看起来是一套"）。
      expect(
        tester
            .widget<NeoPill>(find.byKey(const Key('library-genre-all')))
            .label,
        '全部',
      );
    });

    testWidgets('展开的菜单条目跟触发器同一档（不是只有框里变小了）', (WidgetTester tester) async {
      await _pumpLibrary(tester);
      await tester.tap(find.byKey(const Key('library-year')));
      await tester.pumpAndSettle();

      final Finder items = find.descendant(
        of: find.byType(PopupMenuItem<int>),
        matching: find.byType(Text),
      );
      expect(items, findsWidgets, reason: '年份菜单应该开出来了');
      for (final Element e in items.evaluate()) {
        expect(
          (e.widget as Text).style?.fontSize,
          DsTypeScale.caption,
          reason: '「全部年份 / 2024 年」这些条目也要是 12',
        );
      }
      // 菜单里第一项就是「全部年份」（`NeoDropdownItem` 的 label）。
      expect(find.text('全部年份'), findsOneWidget);
    });

    testWidgets('调用方显式传字号时以它为准（队列页那几处显式传的就是 12）', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildDsanimaTheme(),
          home: Scaffold(
            body: NeoDropdown<int>(
              key: const Key('probe'),
              value: 1,
              fontSize: DsTypeScale.secondary,
              label: '一起下载 · 1 条',
              items: const <NeoDropdownItem<int>>[NeoDropdownItem<int>(1, '一起下载 1 条')],
              onSelected: (int _) {},
            ),
          ),
        ),
      );
      expect(_triggerSize(tester, const Key('probe')), DsTypeScale.secondary);
    });
  });

  group('NeoSegmented：默认 12，设置页显式 13', () {
    testWidgets('默认 caption（12）', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildDsanimaTheme(),
          home: Scaffold(
            body: NeoSegmented<DsCoverSize>(
              options: DsCoverSize.values,
              value: DsCoverSize.m,
              onChanged: (DsCoverSize _) {},
            ),
          ),
        ),
      );
      final Finder labels = find.descendant(
        of: find.byType(NeoSegmented<DsCoverSize>),
        matching: find.byType(Text),
      );
      expect(labels, findsNWidgets(DsCoverSize.values.length));
      for (final Element e in labels.evaluate()) {
        expect((e.widget as Text).style?.fontSize, DsTypeScale.caption);
      }
    });

    testWidgets('设置页那三段控件是 13（= kSettingsBodySize，与行标题同档）', (WidgetTester tester) async {
      await _pumpSettings(tester);
      await _scrollTo(tester, find.text('封面大小'));

      expect(
        tester
            .widget<NeoSegmented<DsCoverSize>>(find.byType(NeoSegmented<DsCoverSize>))
            .fontSize,
        kSettingsBodySize,
      );
      expect(
        tester
            .widget<NeoSegmented<DsCarouselShape>>(find.byType(NeoSegmented<DsCarouselShape>))
            .fontSize,
        kSettingsBodySize,
      );
      expect(
        tester
            .widget<NeoSegmented<DsCarouselSize>>(find.byType(NeoSegmented<DsCarouselSize>))
            .fontSize,
        kSettingsBodySize,
      );
    });
  });

  group('设置页的 Material 下拉：13 + 主题字体族', () {
    testWidgets('代理模式 / 默认源 / 搜索模式 / 并发下载数 四个都是 13', (WidgetTester tester) async {
      await _pumpSettings(tester);

      // 四个分布在两个分组里（① 引擎·下载·网络 与 ② 外观·省流量·缓存），
      // `ListView` 懒建 ⇒ 自上而下逐个锚点滚过去、每到一处就断言当屏那几颗。
      await _scrollTo(tester, find.text('代理模式'));
      expect(
        _expectDropdownsAtSettingsSize(tester),
        greaterThanOrEqualTo(2),
        reason: '「代理模式」这一屏应该至少有它自己与「默认源」',
      );

      await _scrollTo(tester, find.text('搜索模式'));
      _expectDropdownsAtSettingsSize(tester);
      // 「搜索模式」那句长选项在 13 下装得下（17 时它被截成「聚合（全部 / 动漫 / 全…」）。
      expect(find.text('聚合（全部 / 动漫 / 全集）'), findsOneWidget);

      await _scrollTo(tester, find.textContaining('并发下载数'));
      _expectDropdownsAtSettingsSize(tester);
    });
  });
}
