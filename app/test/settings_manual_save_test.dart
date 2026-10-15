/// 设置页**手动保存**的行为测试（2026-10-12 第十六轮）。
///
/// 用户原话：
/// > 「去除设置自动保存的逻辑，仅手动保存」
///
/// 所以这里断言的方向和第 6 项（自动保存）那一版**正好相反**：
/// * 改了控件、**不点**保存 → 不落盘、不生效（等多久都不行）；
/// * 点了「保存并生效」 → 落盘 + 生效**恰好一次**；
/// * 没改动时保存/撤销两个按钮都是禁用的（看不出"我改没改"最恼人）；
/// * 「撤销改动」丢掉草稿且不落盘。
library;

import 'dart:io';

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/state/cover_cache.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/ui/settings_page.dart';
import 'package:dsanima/ui/widgets/ds_cards.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 只记「生效被调用了几次」的生命周期端口替身。
class _RecordingLifecycle implements LifecyclePort {
  int applied = 0;
  AppSettings? last;

  @override
  Future<void> applySettings(AppSettings settings) async {
    applied++;
    last = settings;
  }
}

/// 落盘一定失败的存储：模拟真实世界里 `put` 会抛的情形
/// （磁盘满、Hive box 已被关、锁被别的实例占着）。
class _FailingPutStore extends InMemoryKeyValueStore {
  _FailingPutStore(super.seed);

  int attempted = 0;

  @override
  Future<void> put(String key, Object? value) async {
    attempted++;
    throw const FileSystemException('模拟落盘失败');
  }
}

/// 生效一定失败的生命周期端口（落盘成功、下发引擎失败的真实情形：
/// exe 路径不对、边车起不来、端口被占）。
class _FailingLifecycle implements LifecyclePort {
  int applied = 0;

  @override
  Future<void> applySettings(AppSettings settings) async {
    applied++;
    throw Exception('模拟生效失败');
  }
}

Widget _harness(InMemoryKeyValueStore store, LifecyclePort lifecycle, {Directory? supportDir}) =>
    ProviderScope(
      overrides: [
        keyValueStoreProvider.overrideWithValue(store),
        supportDirProvider.overrideWithValue(supportDir ?? Directory.systemTemp),
        lifecyclePortProvider.overrideWithValue(lifecycle),
        pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
        subsPortProvider.overrideWithValue(const UnavailableSubsPort()),
        queuePortProvider.overrideWithValue(const UnavailableQueuePort()),
      ],
      child: MaterialApp(
        theme: buildDsanimaTheme(),
        home: const Scaffold(body: SettingsPage()),
      ),
    );

void _sizeTo(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

InMemoryKeyValueStore _store() => InMemoryKeyValueStore(<String, Object?>{
  SettingsController.storageKey: const AppSettings(
    firstRunCompleted: true,
    downloadDir: r'F:\Anime',
  ).toJson(),
});

AppSettings _saved(InMemoryKeyValueStore store) => AppSettings.fromJson(
  (store.get(SettingsController.storageKey) as Map?)?.cast<Object?, Object?>(),
);

Finder _seedSwitch() => find.widgetWithText(SwitchListTile, '开启做种');

bool _seedSwitchValue(WidgetTester tester) =>
    tester.widget<SwitchListTile>(_seedSwitch()).value;

String _barText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(dsSettingsSaveBarTextKey)).data ?? '';

VoidCallback? _saveButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(dsSettingsSaveKey)).onPressed;

VoidCallback? _discardButton(WidgetTester tester) =>
    tester.widget<TextButton>(find.byKey(dsSettingsDiscardKey)).onPressed;

/// 读一个输入框屏幕上**真正的文字**。
///
/// 这些框是 `TextFormField(initialValue:)`（没有 controller），所以只能从它内部的
/// `EditableText` 拿 —— 而"盒子里的字"和"设置里的值"是不是一致，正是这一组用例要钉的。
String _fieldText(WidgetTester tester, String label) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.widgetWithText(TextFormField, label),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

void main() {
  testWidgets('改了设置但**不点**保存：等多久都不落盘、不生效', (WidgetTester tester) async {
    // 视口给足高度：设置页很长，滚到开关再点会引入无关的滚动逻辑。
    _sizeTo(tester, const Size(1400, 3000));
    final InMemoryKeyValueStore store = _store();
    final _RecordingLifecycle lifecycle = _RecordingLifecycle();
    await tester.pumpWidget(_harness(store, lifecycle));
    await tester.pumpAndSettle();

    expect(_barText(tester), '设置已保存', reason: '刚进页面：干净');
    expect(_saveButton(tester), isNull, reason: '干净时保存按钮就该禁用');
    expect(_discardButton(tester), isNull, reason: '干净时也不该有东西可撤销');

    await tester.tap(_seedSwitch());
    await tester.pumpAndSettle();

    // 草稿变了（开关亮起、提示变脏），但**一个字节都没写出去**。
    expect(_seedSwitchValue(tester), isTrue);
    expect(_barText(tester), contains('有未保存的改动'));
    expect(_saveButton(tester), isNotNull, reason: '脏了就该能点保存');
    expect(_saved(store).seedEnabled, isFalse, reason: '没点保存 → 不落盘');
    expect(lifecycle.applied, 0, reason: '没点保存 → 不生效');

    // 关键：自动保存已经被去掉，等再久也不会自己动。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(_saved(store).seedEnabled, isFalse, reason: '等多久都不许自动落盘');
    expect(lifecycle.applied, 0, reason: '等多久都不许自动生效');
  });

  testWidgets('点「保存并生效」：落盘 + 生效恰好一次，底部条回到「设置已保存」', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1400, 3000));
    final InMemoryKeyValueStore store = _store();
    final _RecordingLifecycle lifecycle = _RecordingLifecycle();
    await tester.pumpWidget(_harness(store, lifecycle));
    await tester.pumpAndSettle();

    await tester.tap(_seedSwitch());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(dsSettingsSaveKey));
    await tester.pumpAndSettle();

    expect(lifecycle.applied, 1, reason: '一次保存 = 一次生效');
    expect(lifecycle.last?.seedEnabled, isTrue, reason: '生效的那份要带上新值');
    expect(_saved(store).seedEnabled, isTrue, reason: '必须真的落盘（重启后还在）');
    expect(
      find.textContaining('已保存并已生效'),
      findsOneWidget,
      reason: '保存成功后底部条换成成功横幅，不再说"有未保存的改动"',
    );
    expect(find.textContaining('有未保存的改动'), findsNothing);
    expect(_saveButton(tester), isNull, reason: '保存后没改动 → 按钮回到禁用');

    // 再点一次（现在按钮已禁用）不该重复生效。
    await tester.pump(const Duration(seconds: 1));
    expect(lifecycle.applied, 1);

    // 保存完之后接着改：屏幕上必须立刻回到"还没写进去"，
    // 不能继续挂着上一轮那句"已保存并已生效"（那会让用户以为改的东西已经生效了）。
    await tester.tap(find.widgetWithText(SwitchListTile, '后台常驻（关闭主程序后继续下载）'));
    await tester.pumpAndSettle();
    expect(_barText(tester), contains('有未保存的改动'));
    expect(find.textContaining('已保存并已生效'), findsNothing);
    expect(_saved(store).backgroundResident, isFalse, reason: '同样要等点保存才落盘');
  });

  testWidgets('「撤销改动」：草稿回到已保存那份，不落盘、不生效', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1400, 3000));
    final InMemoryKeyValueStore store = _store();
    final _RecordingLifecycle lifecycle = _RecordingLifecycle();
    await tester.pumpWidget(_harness(store, lifecycle));
    await tester.pumpAndSettle();

    await tester.tap(_seedSwitch());
    await tester.pumpAndSettle();
    expect(_seedSwitchValue(tester), isTrue);

    await tester.tap(find.byKey(dsSettingsDiscardKey));
    await tester.pumpAndSettle();

    expect(_seedSwitchValue(tester), isFalse, reason: '撤销后开关回到已保存的值');
    expect(_barText(tester), '设置已保存');
    expect(_saved(store).seedEnabled, isFalse);
    expect(lifecycle.applied, 0);
  });

  testWidgets('后台（不是设置页）写了设置：干净时跟着走，不会误报「有未保存的改动」', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1400, 3000));
    final InMemoryKeyValueStore store = _store();
    final _RecordingLifecycle lifecycle = _RecordingLifecycle();
    await tester.pumpWidget(_harness(store, lifecycle));
    await tester.pumpAndSettle();

    // 第 15 轮的搜索页勾选就是这么写的（`settingsProvider.patch`）。
    final ProviderContainer container =
        ProviderScope.containerOf(tester.element(find.byType(SettingsPage)));
    await container
        .read(settingsProvider.notifier)
        .patch((AppSettings s) => s.copyWith(aggregateExcludedSourceIds: <String>['sukebei']));
    await tester.pumpAndSettle();

    expect(
      _barText(tester),
      '设置已保存',
      reason: '后台写进来的东西不是"用户在改" —— 不该让底部条说"有未保存的改动"',
    );
    expect(_saveButton(tester), isNull);

    // 之后用户在页面上改一样东西并保存：后台写进去的那个字段**不能**被退回旧值。
    await tester.tap(_seedSwitch());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(dsSettingsSaveKey));
    await tester.pumpAndSettle();
    expect(_saved(store).seedEnabled, isTrue);
    expect(
      _saved(store).aggregateExcludedSourceIds,
      <String>['sukebei'],
      reason: '草稿里没碰过的字段要保留"现在的已保存值"（见 mergeDraftForSave）',
    );
  });

  testWidgets('在输入框里打字（这些 onChanged 刻意不 setState）也要立刻变成「有未保存的改动」', (
    WidgetTester tester,
  ) async {
    _sizeTo(tester, const Size(1400, 3000));
    final InMemoryKeyValueStore store = _store();
    final _RecordingLifecycle lifecycle = _RecordingLifecycle();
    await tester.pumpWidget(_harness(store, lifecycle));
    await tester.pumpAndSettle();
    expect(_saveButton(tester), isNull);

    // 全页 13 个输入框都是 `onChanged: (v) => _draft = ...`（不 setState，免得每敲一下重铺整页）。
    // 去掉自动保存之后，如果没人重建，底部条会一直写「设置已保存」、按钮一直灰着 —— 用户改完
    // 却点不动保存（真机截图时就是这么发现的第一版 bug）。
    await tester.enterText(find.widgetWithText(TextFormField, '上传限速 (KB/s)'), '999');
    await tester.pumpAndSettle();

    expect(_barText(tester), contains('有未保存的改动'), reason: '打字也要立刻反映到保存条上');
    expect(_saved(store).uploadLimitKbps, 100, reason: '没点保存 → 不落盘');

    await tester.tap(find.byKey(dsSettingsSaveKey));
    await tester.pumpAndSettle();
    expect(_saved(store).uploadLimitKbps, 999, reason: '输入框里打的字也必须能保存下去');
    expect(lifecycle.applied, 1);
  });

  testWidgets('⚠️「撤销改动」要连输入框里的字一起还原（非受控 initialValue 的老问题）', (WidgetTester tester) async {
    // 审查发现：13 个输入框都是 `TextFormField(initialValue:)`、没有 controller，
    // 而 Flutter 只在 **controller 实例变化**时才把 initialValue 同步到屏幕上
    // （`_TextFormFieldState.didUpdateWidget`）；`FormFieldState.didUpdateWidget`
    // 也不看 initialValue。于是所有"程序化改草稿"的路径（撤销/导入配置/后台对齐/
    // 保存后回填）都改不动屏幕：底部条说已还原，框里还是旧字。
    _sizeTo(tester, const Size(1400, 3000));
    final InMemoryKeyValueStore store = _store();
    final _RecordingLifecycle lifecycle = _RecordingLifecycle();
    await tester.pumpWidget(_harness(store, lifecycle));
    await tester.pumpAndSettle();
    expect(_fieldText(tester, '上传限速 (KB/s)'), '100', reason: '已保存的默认值');

    await tester.enterText(find.widgetWithText(TextFormField, '上传限速 (KB/s)'), '999');
    await tester.pumpAndSettle();
    expect(_fieldText(tester, '上传限速 (KB/s)'), '999');

    await tester.tap(find.byKey(dsSettingsDiscardKey));
    await tester.pumpAndSettle();

    expect(_fieldText(tester, '上传限速 (KB/s)'), '100', reason: '撤销 = 屏幕也要回到已保存那份');
    expect(_barText(tester), '设置已保存');
  });

  testWidgets('⚠️ 后台写了设置且页面干净：输入框要跟着走（不能框里旧值、屏幕说「已保存」）', (
    WidgetTester tester,
  ) async {
    _sizeTo(tester, const Size(1400, 3000));
    final InMemoryKeyValueStore store = _store();
    final _RecordingLifecycle lifecycle = _RecordingLifecycle();
    await tester.pumpWidget(_harness(store, lifecycle));
    await tester.pumpAndSettle();

    // 首启向导 / tracker 每日刷新 / 搜索页勾选都是这么写的。
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPage)),
    );
    await container
        .read(settingsProvider.notifier)
        .patch((AppSettings s) => s.copyWith(uploadLimitKbps: 777));
    await tester.pumpAndSettle();

    expect(_barText(tester), '设置已保存', reason: '这是后台写的，不是"用户在改"');
    expect(
      _fieldText(tester, '上传限速 (KB/s)'),
      '777',
      reason: '干净时草稿跟着后台走 → 屏幕上的字也必须跟着走，否则就是在撒谎',
    );
  });

  testWidgets('⚠️ 生效失败：切页三选里点「保存并生效」也必须留在页面上（走了横幅就看不见了）', (
    WidgetTester tester,
  ) async {
    // 审查发现：`_resolveUnsaved` 里是 `await _save(); return !_dirty;`，
    // 而 `_save()` 落盘成功后会把 baseline 推进到 payload（不再脏）——
    // 于是**生效失败**时它也返回 true 放行离开，注释承诺的"留在页面上用横幅说明"落空。
    _sizeTo(tester, const Size(1400, 3000));
    final InMemoryKeyValueStore store = _store();
    final _FailingLifecycle lifecycle = _FailingLifecycle();
    await tester.pumpWidget(_harness(store, lifecycle));
    await tester.pumpAndSettle();

    await tester.tap(_seedSwitch());
    await tester.pumpAndSettle();

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPage)),
    );
    final guard = container.read(settingsDraftGuardProvider).value;
    expect(guard, isNotNull, reason: '设置页在的时候必须把自己登记给守卫');
    final Future<bool> canLeave = guard!.resolve(tester.element(find.byType(SettingsPage)));
    await tester.pumpAndSettle();
    expect(find.text('设置有未保存的改动'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '保存并生效'),
      ),
    );
    await tester.pumpAndSettle();

    expect(lifecycle.applied, 1, reason: '试过生效');
    expect(_saved(store).seedEnabled, isTrue, reason: '落盘是成功的');
    expect(
      await canLeave,
      isFalse,
      reason: '生效失败必须留住用户：走了那条失败横幅用户就永远看不到',
    );
    expect(find.textContaining('操作失败'), findsOneWidget, reason: '底部条要说明生效失败');
  });

  testWidgets('⚠️ 落盘失败：不许说「已保存」，不许让异常逃出去，内存态要回滚', (WidgetTester tester) async {
    // 审查发现：`_save()` 只 try/finally 没有 catch，而 `replace()` 是"先改内存 state、
    // 再 await put"。put 抛错时异常一路逃到 `onPressed` 的异步闭包（未处理异步错误），
    // 界面却因为 `failure == null` 照旧写「已保存并已生效」——内存里是新值、磁盘上是旧值。
    _sizeTo(tester, const Size(1400, 3000));
    final _FailingPutStore store = _FailingPutStore(<String, Object?>{
      SettingsController.storageKey: const AppSettings(
        firstRunCompleted: true,
        downloadDir: r'F:\Anime',
      ).toJson(),
    });
    final _RecordingLifecycle lifecycle = _RecordingLifecycle();
    await tester.pumpWidget(_harness(store, lifecycle));
    await tester.pumpAndSettle();

    await tester.tap(_seedSwitch());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(dsSettingsSaveKey));
    await tester.pumpAndSettle();

    expect(store.attempted, 1, reason: '确实试过落盘');
    expect(tester.takeException(), isNull, reason: '落盘失败要被自己接住并说明，不能变成未处理异常');
    expect(lifecycle.applied, 0, reason: '没落盘成功就不许下发：否则边车用着一份重启后就消失的设置');
    expect(find.textContaining('文件系统错误'), findsOneWidget, reason: '底部条要说明失败原因');
    expect(
      find.textContaining('已保存并已生效'),
      findsNothing,
      reason: '写盘失败却说"已保存"就是静默假成功（§9 明令禁止）',
    );
    expect(_saveButton(tester), isNotNull, reason: '草稿还是脏的：用户要能重试');
    expect(_discardButton(tester), isNotNull, reason: '草稿还是脏的：用户要能撤销');

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPage)),
    );
    expect(
      container.read(settingsProvider).seedEnabled,
      isFalse,
      reason: '写盘失败 → 内存态回滚到磁盘上那份，不许"界面亮着、重启就没了"',
    );
  });

  testWidgets('引擎路径输入框清空 = 真的清掉（「留空 = 自动查找」不能是空话）', (WidgetTester tester) async {
    // 审查发现：`copyWith(enginePath: null)` 是**空操作**（null 的语义是"不改"），
    // 于是清空输入框后 draft 一个字节都没变 → 脏标记恒 false → 保存按钮一直灰着、
    // 切页/关窗也不拦 —— 框里是空的、设置里还是旧路径，引擎照旧拿旧路径启动。
    _sizeTo(tester, const Size(1400, 3000));
    final InMemoryKeyValueStore store = InMemoryKeyValueStore(<String, Object?>{
      SettingsController.storageKey: const AppSettings(
        firstRunCompleted: true,
        downloadDir: r'F:\Anime',
        enginePath: r'F:\old\rqbit-engine.exe',
      ).toJson(),
    });
    final _RecordingLifecycle lifecycle = _RecordingLifecycle();
    await tester.pumpWidget(_harness(store, lifecycle));
    await tester.pumpAndSettle();
    expect(_saveButton(tester), isNull, reason: '刚进页面：干净');

    await tester.enterText(
      find.widgetWithText(TextFormField, 'rqbit-engine.exe 路径（留空 = 自动查找）'),
      '',
    );
    await tester.pumpAndSettle();

    expect(_barText(tester), contains('有未保存的改动'), reason: '清空路径也是"改了设置"');
    expect(_saveButton(tester), isNotNull, reason: '清空后必须能点保存');

    await tester.tap(find.byKey(dsSettingsSaveKey));
    await tester.pumpAndSettle();
    expect(
      _saved(store).enginePath,
      isNull,
      reason: '标签写着「留空 = 自动查找」，就必须真的把设置里的路径清成 null',
    );
    expect(_saved(store).downloadDir, r'F:\Anime', reason: '清一个字段不许动别的字段');
    expect(lifecycle.applied, 1);
  });

  testWidgets('设置页：封面缓存区块在（周期下拉 + 清理按钮），点清理不炸（第 7 项）', (WidgetTester tester) async {    _sizeTo(tester, const Size(1400, 3000));
    // 用一个**自己的**支持目录：清理逻辑只会在它下面的 covers 里动文件，
    // 绝不碰别的地方（真实运行里那是 `<支持目录>/dsanima/cache/covers`）。
    final Directory support = Directory.systemTemp.createTempSync('dsanima_settings_cache_');
    addTearDown(() {
      if (support.existsSync()) support.deleteSync(recursive: true);
    });
    final Directory covers = coverCacheDirOf(support)..createSync(recursive: true);
    File(
      p.join(covers.path, 'stale.webp'),
    ).writeAsBytesSync(List<int>.filled(2048, 0x41)); // 刚写的：默认周期下不该删

    await tester.pumpWidget(_harness(_store(), _RecordingLifecycle(), supportDir: support));
    await tester.pumpAndSettle();

    // 区块在了（区块缺失/布局溢出这条测试会直接红）。
    expect(find.text('封面缓存'), findsOneWidget);
    expect(find.text('自动清理'), findsOneWidget);
    expect(find.text('一个月'), findsOneWidget, reason: '默认周期 = 一个月');
    expect(find.text('立即清理'), findsOneWidget);
    expect(find.textContaining('缓存'), findsWidgets, reason: '占用/空态文案总得有一条');

    // 点一下「立即清理」：不该抛；新鲜的封面（刚写）在默认周期下也不该被删。
    // 注：真实文件 IO 在 `testWidgets` 的 fake async 里回调不一定会回来，
    // 所以"到底删了哪些"由 `cover_cache_gc_test.dart` 的纯函数测试负责钉住，
    // 这里只保证 UI 这条链路点得动、不崩。
    await tester.tap(find.text('立即清理'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 用户 2026-10-11「不要没用的缓存」：源缓存/推荐/番剧信息那三处也能看见、能一键清
    // （以前只涨不减）。清扫规则本身由 `cache_sweep_test.dart` 钉住。
    expect(find.text('源缓存 / 番剧信息'), findsOneWidget);
    expect(find.text('清空'), findsOneWidget);
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  // ── 第二十五轮：设置页「文字颇多且杂乱一体，多做点区分」 ──────────────────────

  testWidgets('设置页分成 3 组：三颗分组大标题都在、按顺序排，6 个区块一个不少', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1400, 3000));

    await tester.pumpWidget(_harness(_store(), _RecordingLifecycle()));
    await tester.pumpAndSettle();

    const List<String> groups = <String>['引擎 · 下载 · 网络', '外观 · 省流量 · 缓存', 'tracker · 后台 · 做种'];
    for (final String title in groups) {
      expect(find.text(title), findsOneWidget, reason: '缺分组大标题：$title');
    }
    final double y1 = tester.getTopLeft(find.text(groups[0])).dy;
    final double y2 = tester.getTopLeft(find.text(groups[1])).dy;
    final double y3 = tester.getTopLeft(find.text(groups[2])).dy;
    expect(y1, lessThan(y2), reason: '分组顺序 = 页面顺序');
    expect(y2, lessThan(y3));

    // 分组的**语义**：每一组的标题必须排在它那两个区块**之上**。
    for (final (String group, List<String> sections) in <(String, List<String>)>[
      (groups[0], <String>['引擎（rqbit-engine 边车）', '网络 · 限速 · 做种']),
      (groups[1], <String>['外观', '省流量策略']),
      (groups[2], <String>['tracker 来源', '做种与后台']),
    ]) {
      final double yGroup = tester.getTopLeft(find.text(group)).dy;
      for (final String section in sections) {
        expect(find.text(section), findsOneWidget, reason: '缺区块：$section');
        expect(yGroup, lessThan(tester.getTopLeft(find.text(section)).dy),
            reason: '「$group」要排在「$section」上面');
      }
    }
  });

  testWidgets('第二十六轮：说明**不再折叠** —— 没有「展开」控件，长说明全文显示', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1400, 3000));

    await tester.pumpWidget(_harness(_store(), _RecordingLifecycle()));
    await tester.pumpAndSettle();

    // 用户这一轮：「设置页去除上次改动的『展开』内容」——
    // 第二十五轮那套「展开说明 / 收起说明」整段删掉，一颗都不许剩。
    expect(find.text('展开说明'), findsNothing, reason: '「展开说明」必须消失（用户明确要去掉）');
    expect(find.text('收起说明'), findsNothing, reason: '「收起说明」必须消失');

    // 长说明改成**全文换行**显示：既在树里、也不被 maxLines 截断。
    const String longNote =
        '代理只作用于源抓取（nyaa/mikan/RSS）；限速与做种比是边车启动参数（0 = 不限），改完需「保存并生效」';
    expect(find.text(longNote), findsOneWidget);
    expect(tester.widget<Text>(find.text(longNote)).maxLines, isNull, reason: '不折叠 ⇒ 不截断');

    // 区块标题下的那句长说明（`DsSection.subtitle`）同样全文显示。
    final Finder section =
        find.ancestor(of: find.text(longNote), matching: find.byType(DsSection));
    expect(section, findsOneWidget);
    const String sectionSubtitle = '拉起的进程参数：下载目录 · 限速 · 做种比 · tracker';
    final Finder engineSection = find.ancestor(
      of: find.text(sectionSubtitle),
      matching: find.byType(DsSection),
    );
    expect(engineSection, findsOneWidget);
    expect(find.descendant(of: engineSection, matching: find.text('展开说明')), findsNothing);

    // 开关行里的长说明（>34 字，上一轮会被折叠的那类）也全文显示。
    const String switchNote = '播放结束或切到下一集时对该 torrent pause()，不再上传';
    expect(find.text(switchNote), findsOneWidget);
    expect(tester.widget<Text>(find.text(switchNote)).maxLines, isNull);
  });
}
