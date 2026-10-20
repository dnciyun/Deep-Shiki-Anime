/// 主窗口侧的「画面调节」编辑器：**主窗口没有画面**，这里只维护取值 + 写盘 + 通知播放窗口。
///
/// 为什么不复用 `PictureController`（`state/picture_pack.dart`）：那个类的存在理由是
/// "把渲染结果挂到 mpv 的 `glsl-shaders` 上"，它要一个真的 `Anime4kController`——而
/// 主窗口 `lazyPlayer: true`、一个 mpv 都没有（用户 2026-10-10：「只有弹出窗口播放」）。
/// 硬把播放器塞进来只会得到一堆"没接上"的空实现。所以职责切成两半：
/// * **主窗口（这里）**：选包 / 选预设 / 拖滑杆 / 存组合 → 写 `picture-settings.json`
///   → 发一条 `pictureChanged`（**只带"变了"**，见 spec §3 方案 A）；
/// * **播放窗口**：收到通知后重读文件、重读组合 → `PictureController.applySettings`
///   → 重渲染 + 重挂链。渲染与挂链**只在**那一侧发生。
///
/// 为什么"文件是唯一真相"而不是"把取值塞进通道"：
/// 两个窗口是独立 isolate，通道传值是**一次性**的 —— 播放窗口错过一条（还没装好处理器、
/// 窗口刚建）就永远落后了；而文件在那里，重读一次就追上了。所以通道只说明"变了"，
/// 内容一律从盘上读，重开窗口/重启程序也天然一致。
///
/// 三条硬规矩（每条都有用例钉着）：
/// 1. **防抖 220ms**：拖滑杆每帧只改内存，停手/松手之后才写盘 + 推送。
///    每帧写盘会把这个文件写成 IO 热点，每帧发通道更糟（对面要重渲染整条 shader 链）；
/// 2. **永久不抛**：写盘、通道、坏模板、坏组合文件都只退化 —— 这是配置页，不该崩；
/// 3. **`adopt` 不写盘、不再 push**：播放窗口回推的是"已经生效"的取值，主窗口只同步显示。
///    少了这套，会出现"页面显示旧值 → 用户一拖 → 把播放器刚调好的覆盖掉"。
library;

import 'dart:async';
import 'dart:io';

import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/picture_combo.dart';
import 'infra.dart' show supportDirProvider;
import 'packs_available.dart';
import 'picture_combos.dart';
import 'picture_pack.dart';
import 'picture_settings_io.dart';
import 'player_window.dart' show playerWindowServiceProvider;

/// 拖滑杆的防抖窗口。
///
/// 220ms 的取舍：再短就接近"每帧一条"，对面（播放窗口）光重渲染就忙不过来；
/// 再长用户会觉得"松手了还不生效"。松手（`onChangeEnd`）会**立刻**再调一次
/// [PictureEditorController.commit]，所以真正的手感是"松手即生效"，
/// 这个窗口只管"按住不放时别每帧写"。
const Duration kPictureEditorDebounce = Duration(milliseconds: 220);

/// 「通知播放窗口：画面设置变了」这件事本身。
///
/// 为什么抽成注入的函数：单测里不能真跨窗口发消息（没有引擎、没有子窗口），
/// 而"到底推了几次"正是防抖那条用例要断言的东西。测试里 override 成记录器即可，
/// 不必为它造一个假的 `PlayerWindowService`。
///
/// 默认实现 = `PlayerWindowService.send(kMethodPictureChanged)`：没有播放窗口时它是
/// **空操作**（这是正常路径，不是失败），所以"没开播放窗口 → 页面改动只写盘、不报错"
/// 这条不需要额外分支。
final Provider<Future<void> Function()> picturePushProvider =
    Provider<Future<void> Function()>(
  (Ref ref) => () => ref.read(playerWindowServiceProvider).sendPictureChanged(),
);

/// 编辑器看到的一切（页面直接 watch 它）。
@immutable
class PictureEditorState {
  const PictureEditorState({
    this.packs = const <PicturePack>[],
    this.settings = PictureSettings.off,
    this.values = const <String, double>{},
    this.combos = const <String, List<PictureCombo>>{},
    this.loaded = false,
    this.problem,
  });

  /// 现在可用的画面调节包（来自 `packAvailabilityProvider`，已按预设可见性过滤）。
  final List<PicturePack> packs;

  /// 现在生效的是哪一套（会原样写进 `picture-settings.json`）。
  ///
  /// ⚠️ 包被卸载时这里**仍然**保留 `packId`：盘上那份文件没变（我们不写"关"），
  /// 所以包重新装回来时旧取值原样回来（Review Focus 2）。别在这里"顺手归一化成关"。
  final PictureSettings settings;

  /// 完整取值（默认值 + 覆盖，已夹到区间）。包不在时为空表（没有区间可夹）。
  final Map<String, double> values;

  /// 按包分组的「我的组合」。
  final Map<String, List<PictureCombo>> combos;

  /// 是否已经从盘上读过一次（页面用它区分"空态"和"还没读"）。
  final bool loaded;

  /// 读不动的原因（没数据根 / 一个包都没有）。null = 一切正常。
  final String? problem;

  /// 当前包；null = 没选包（或者选中的包已经被卸载）。
  PicturePack? get currentPack {
    final String? id = settings.packId;
    if (id == null) return null;
    for (final PicturePack pack in packs) {
      if (pack.id == id) return pack;
    }
    return null;
  }

  /// 页面**正在调**的那个包：有选中的就是选中的，关着就是第一个。
  ///
  /// 为什么要与 [currentPack] 分开：关着的时候滑杆也得能画、能拖（拖一下就自动选包），
  /// 而"生效中的包"在没有选中时确实是 null。合成一个 getter 会让"关"这个状态
  /// 连滑杆都消失。
  PicturePack? get editingPack => currentPack ?? (packs.isEmpty ? null : packs.first);

  /// 正在调的那个包的自定义组合（别的包的不该出现在这一页的动作里）。
  List<PictureCombo> get currentCombos => combos[editingPack?.id] ?? const <PictureCombo>[];

  /// 有没有任何画面调节在生效。
  ///
  /// 判据是"当前包在不在"而不是 `settings.isOff`：包被卸载之后，文件里那个 packId
  /// 对用户来说什么也没生效（页面上该显示"关"，而不是"开着但什么都没有"）。
  bool get isOff => currentPack == null;

  bool get hasPacks => packs.isNotEmpty;

  PictureEditorState copyWith({
    List<PicturePack>? packs,
    PictureSettings? settings,
    Map<String, double>? values,
    Map<String, List<PictureCombo>>? combos,
    bool? loaded,
    String? problem,
  }) =>
      PictureEditorState(
        packs: packs ?? this.packs,
        settings: settings ?? this.settings,
        values: values ?? this.values,
        combos: combos ?? this.combos,
        loaded: loaded ?? this.loaded,
        problem: problem ?? this.problem,
      );

  @override
  String toString() => 'PictureEditorState(packs=${packs.length} '
      'pack=${settings.packId} preset=${settings.presetId} '
      'values=$values combos=${combos.length} loaded=$loaded problem=$problem)';
}

class PictureEditorController extends Notifier<PictureEditorState> {
  PictureSettingsStore? _settingsStore;
  PictureCombosStore? _combosStore;

  /// 防抖定时器（null = 没有待落盘的改动）。
  Timer? _debounce;

  /// 上一次读盘时"数据根 + 包清单"的指纹：没变就不重读。
  String _signature = '';

  /// 组合 id 的自增部分（同一微秒内连存两套也必须得到不同 id）。
  int _comboSeq = 0;

  /// 读盘队列：保证"先来的先读完"，后来的排在它后面。
  ///
  /// 为什么需要排队（而不是"有在跑的就直接复用它"）：包清单刚变时会连来两次
  /// （`ref.listen` 一次、页面/测试再一次）。复用同一个 future 的话，第二次拿到的可能是
  /// **按旧包清单**读到的那一份 —— 表现为"包装回来了但页面还是空的"。排队则两次
  /// 都按"开始执行时的"清单判定，第二次自然重读。
  Future<void> _pending = Future<void>.value();

  @override
  PictureEditorState build() {
    // 装/卸/启停/改预设可见性都会刷新可用包：页面开着的时候也要跟上
    //（否则用户卸载了包，这一页还挂着一套点不动的滑杆）。
    ref.listen<PackAvailability>(packAvailabilityProvider,
        (PackAvailability? previous, PackAvailability next) {
      unawaited(ensureLoaded());
    });
    ref.onDispose(() {
      _debounce?.cancel();
      _debounce = null;
    });
    return const PictureEditorState();
  }

  /// 读一次盘（包清单 + 设置 + 组合）。**永不抛**，同一份输入只读一次。
  ///
  /// 为什么"同一份输入只读一次"而不是每次进页面都重读：重读会把用户正在拖、
  /// 还没过防抖的那几个取值冲掉（页面的 `initState` 与本监听都会调到这里）。
  Future<void> ensureLoaded() {
    // 串成一条链（见 [_pending]）。`_load` 自己永不抛，链不会断。
    _pending = _pending.then((_) => _load());
    return _pending;
  }

  Future<void> _load() async {
    try {
      await _loadOnce();
    } catch (error, stack) {
      // 兜底（文件系统/Provider 被销毁这类意外）：配置页最坏只该"读不出取值"，
      // 绝不能把主窗口拖崩，也不能让下一次 ensureLoaded 卡在一条断掉的链上。
      debugPrint('[picture] 读取画面设置失败（按空处理）：$error\n$stack');
      if (ref.mounted && !state.loaded) {
        state = const PictureEditorState(loaded: true, problem: '画面设置读不出来（不影响播放）');
      }
    }
  }

  Future<void> _loadOnce() async {
    final Directory? dir = ref.read(supportDirProvider);
    final List<PicturePack> packs = ref.read(packAvailabilityProvider).picturePacks;
    final String signature = '${dir?.path}|'
        '${packs.map((PicturePack pack) => '${pack.id}@${pack.version}').join(',')}';
    if (state.loaded && signature == _signature) return;
    // 还有一次改动没落盘：先把它写下去，再按盘上的状态重读 —— 顺序反了就把用户
    // 刚拖的那一下丢了。
    if (_debounce != null) await commit();

    _signature = signature;
    _settingsStore = dir == null ? null : PictureSettingsStore(dir);
    _combosStore = dir == null ? null : PictureCombosStore(dir);

    if (dir == null) {
      // 装配问题（组件测试/没注入数据根）：整页只显示一句说明，绝不去猜取值。
      state = PictureEditorState(
        packs: packs,
        loaded: true,
        problem: '没有数据根目录，画面设置读不出来',
      );
      return;
    }

    final PictureSettings settings = await _settingsStore!.load();
    final Map<String, List<PictureCombo>> combos = await _combosStore!.load();
    if (!ref.mounted) return;
    state = PictureEditorState(
      packs: List<PicturePack>.unmodifiable(packs),
      settings: settings,
      values: _valuesFor(settings, packs),
      combos: combos,
      loaded: true,
      problem: packs.isEmpty
          ? '没找到画面调节包：在「扩展」里装一个画面调节包之后，这里才有可调的东西'
          : null,
    );
  }

  /// 选一个包（[presetId] 为空 = 用它的第一个预设，与播放窗口同一套语义）。
  Future<void> selectPack(String packId, {String? presetId}) async {
    final PicturePack? pack = _packOf(packId);
    if (pack == null) return;
    final core.PicturePreset? preset = presetId == null
        ? (pack.hasPresets ? pack.spec.presets.first : null)
        : _presetOf(pack, presetId);
    final Map<String, double> values =
        preset == null ? pack.spec.defaults : pack.spec.valuesOf(preset);
    _applySettings(PictureSettings(packId: pack.id, presetId: preset?.id, values: values));
    await commit();
  }

  /// 套一个包自带的预设（关着也直接生效：点预设本来就是"就这样看"）。
  Future<void> applyPreset(String presetId) async {
    final PicturePack? pack = _targetPack;
    if (pack == null) return;
    final core.PicturePreset? preset = _presetOf(pack, presetId);
    if (preset == null) return;
    _applySettings(PictureSettings(
      packId: pack.id,
      presetId: preset.id,
      values: pack.spec.valuesOf(preset),
    ));
    await commit();
  }

  /// 套本包的一个「我的组合」（[comboId] 是组合自己的 id，不是菜单里的全局 id）。
  Future<void> applyCombo(String comboId) async {
    final PicturePack? pack = state.currentPack;
    if (pack == null) return;
    PictureCombo? combo;
    for (final PictureCombo candidate in state.currentCombos) {
      if (candidate.id == comboId) {
        combo = candidate;
        break;
      }
    }
    if (combo == null) return;
    _applySettings(PictureSettings(
      packId: pack.id,
      // 记成 `custom:<id>`：播放器的右键菜单据此把「我的 · <名字>」勾上，
      // 两个窗口对"现在亮着哪一项"才有同一个答案。
      presetId: '$kPictureComboPrefix$comboId',
      values: pack.spec.normalizeValues(combo.values),
    ));
    await commit();
  }

  /// 改一个滑杆。**只改内存**（拖滑杆时每帧调），返回真正生效的值（可能被夹过）。
  ///
  /// 夹值/量化一律交给 `PictureParam.clampValue`：界面、写盘、渲染三处必须同一套数，
  /// 否则会出现"界面 0.7 / 存 0.7000000000000001 / 渲染 0.7000"（spec §3 第 5 条）。
  double setValue(String key, double value) {
    PicturePack? pack = state.currentPack;
    // 关着的时候也能拖：第一次拖就把第一个包选起来。否则用户会遇到"滑杆能拖但没反应"
    // ——与播放窗口面板同一条规矩（`PictureController.setValue`）。
    if (pack == null && state.packs.isNotEmpty) pack = state.packs.first;
    final core.PictureParam? param = pack?.spec.paramByKey(key);
    if (pack == null || param == null) return value;
    final double clamped = param.clampValue(value);
    final Map<String, double> values = <String, double>{...state.values, key: clamped};
    // 手调之后不再算某个预设（预设是一组固定取值，改一项就不再是它）。
    _applySettings(PictureSettings(packId: pack.id, values: values));
    _scheduleCommit();
    return clamped;
  }

  /// 落盘 + 推送。防抖到点、滑杆松手、点预设/关/重置都会走到这里。
  ///
  /// 幂等：没有待落盘的改动也照写一次（用户点「存为组合」之后取值没变，
  /// 但"哪个预设亮着"变了，那一份也要写下去）。
  Future<void> commit() async {
    _debounce?.cancel();
    _debounce = null;
    final PictureSettingsStore? store = _settingsStore;
    if (store != null) {
      // `save` 自己排队 + 原子写，且**永不抛**（存不下来最坏是这次没记住）。
      await store.save(state.settings);
    }
    await _push();
  }

  /// 关掉画面调节（文件里写成"空的那一份"，下次开播不会又挂回去）。
  Future<void> turnOff() async {
    // 关掉之后滑杆仍显示**包的默认值**（与播放窗口面板 `valueOf` 的回退一致）：
    // 显示上一套自定义值会让人以为"关了但还在用"。
    state = state.copyWith(
      settings: PictureSettings.off,
      values: _valuesFor(PictureSettings.off, state.packs),
    );
    await commit();
  }

  /// 回到当前包的默认值，但**仍然是"开"**（用户要的是"别调了"，不是"关掉"）。
  Future<void> resetPack() async {
    final PicturePack? pack = _targetPack;
    if (pack == null) return;
    _applySettings(PictureSettings(packId: pack.id, values: pack.spec.defaults));
    await commit();
  }

  /// 把当前取值存成「我的组合」；空名字（或没有当前包）返回 null。
  ///
  /// 返回值是菜单/选中状态用的**全局 id**（`<包>/custom:<组合>`），页面拿它立刻把
  /// 刚存的那一项点亮；不需要它时可以忽略。
  Future<String?> saveCombo(String name) async {
    final String trimmed = name.trim();
    final PicturePack? pack = _targetPack;
    if (trimmed.isEmpty || pack == null) return null;
    final PictureCombo combo = PictureCombo(
      id: _newComboId(),
      // 组合存的是**完整取值**：只存差异的话，包换了默认值这套组合就变形了。
      values: Map<String, double>.unmodifiable(state.values),
      name: trimmed,
    );
    final List<PictureCombo> list = <PictureCombo>[
      ...?state.combos[pack.id],
      combo,
    ];
    final Map<String, List<PictureCombo>> combos = <String, List<PictureCombo>>{
      ...state.combos,
      pack.id: list,
    };
    state = state.copyWith(
      combos: combos,
      // 存下来的这一套就是现在这一套：顺手把包选起来（关着的时候"存组合"等于
      // "就用这套" —— 否则页面会显示一个刚存好、却不生效的组合，让人以为没存上）。
      settings: PictureSettings(
        packId: pack.id,
        presetId: '$kPictureComboPrefix${combo.id}',
        values: state.values,
      ),
    );
    await _combosStore?.save(combos);
    // 取值没变，但"亮着哪一项"变了、播放窗口的右键菜单也要多出这一项 → 走同一条 commit。
    await commit();
    return pictureComboIdOf(pack.id, combo.id);
  }

  /// 删掉本包的一个组合。
  Future<void> deleteCombo(String comboId) async {
    final PicturePack? pack = _targetPack;
    if (pack == null) return;
    final List<PictureCombo> list = <PictureCombo>[
      for (final PictureCombo combo in state.currentCombos)
        if (combo.id != comboId) combo,
    ];
    final Map<String, List<PictureCombo>> combos = <String, List<PictureCombo>>{...state.combos};
    if (list.isEmpty) {
      combos.remove(pack.id); // 空数组不写进文件（否则包卸载了键还一直在）
    } else {
      combos[pack.id] = list;
    }
    final bool wasActive = state.settings.presetId == '$kPictureComboPrefix$comboId';
    state = state.copyWith(
      combos: combos,
      settings: wasActive ? state.settings.copyWith(clearPreset: true) : state.settings,
    );
    await _combosStore?.save(combos);
    // 播放窗口的右键菜单也要少一项 → 走同一条"变了"通道（顺带把清掉的 preset 写下去）。
    await commit();
  }

  /// 播放窗口回推的取值（那边**已经生效**了）。
  ///
  /// 只同步显示：**不写盘、不再 push** —— 文件已经是那边写好的那一份，再写一遍只会让
  /// 两个窗口互相打乒乓；不再 push 是因为对面就是下发者。
  ///
  /// 同时取消待落盘的那一次（关键）：否则"播放器刚调好 → 页面还在显示旧值 →
  /// 220ms 后主窗口把自己那份旧取值写下去"，刚好把刚调好的覆盖掉。
  void adopt(Map<String, Object?> raw) {
    _debounce?.cancel();
    _debounce = null;
    _applySettings(PictureSettings.fromJson(raw));
  }

  // ── 内部 ──────────────────────────────────────────────────────────────────

  /// 把一份设置落进状态（取值统一走 `normalizeValues`，别自己再写一套夹值）。
  void _applySettings(PictureSettings settings) {
    state = state.copyWith(settings: settings, values: _valuesFor(settings, state.packs));
  }

  /// 取出完整取值：**关着的时候也给第一个包的默认值**。
  ///
  /// 为什么不是空表：页面在没有"当前包"时也要画出能拖的滑杆（拖一下就自动选包，
  /// 与播放窗口面板同一条规矩）。空表会让滑杆全贴在最小值上，看起来像坏了。
  ///
  /// [packs] 显式传进来而不是读 `state.packs`：`_load` 里要按**新读到的清单**算，
  /// 那时 `state` 还是上一份。
  Map<String, double> _valuesFor(PictureSettings settings, List<PicturePack> packs) {
    PicturePack? pack;
    for (final PicturePack candidate in packs) {
      if (candidate.id == settings.packId) {
        pack = candidate;
        break;
      }
    }
    pack ??= packs.isEmpty ? null : packs.first;
    if (pack == null) return const <String, double>{};
    return pack.spec.normalizeValues(settings.values);
  }

  void _scheduleCommit() {
    _debounce?.cancel();
    _debounce = Timer(kPictureEditorDebounce, () {
      _debounce = null;
      // 定时器回调里不能 await：fire-and-forget，`commit` 自己永不抛。
      unawaited(commit());
    });
  }

  Future<void> _push() async {
    try {
      await ref.read(picturePushProvider)();
    } catch (error) {
      // 没开播放窗口是**正常路径**（`send` 自己就是空操作）；真出错也只记日志：
      // 取值已经落盘，下次开播按文件恢复 —— 配置页不该因为通知失败弹失败横幅。
      debugPrint('[picture] 通知播放窗口失败（下次开播生效）：$error');
    }
  }

  /// 动作作用在哪个包上：当前选中的；关着就用第一个（与 `setValue` 同一条规矩）。
  PicturePack? get _targetPack =>
      state.currentPack ?? (state.packs.isEmpty ? null : state.packs.first);

  PicturePack? _packOf(String? id) {
    if (id == null) return null;
    for (final PicturePack pack in state.packs) {
      if (pack.id == id) return pack;
    }
    return null;
  }

  core.PicturePreset? _presetOf(PicturePack pack, String id) {
    for (final core.PicturePreset preset in pack.spec.presets) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  /// 组合 id：时间戳（36 进制）+ 自增，包内唯一即可。
  ///
  /// 不需要人类可读（组合的**名字**才是给人看的）；不能用名字当 id，否则存两套同名的
  /// 第二套会覆盖第一套。
  String _newComboId() {
    _comboSeq++;
    final String stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return 'c$stamp${_comboSeq.toRadixString(36)}';
  }
}

/// 主窗口唯一写入口。
final NotifierProvider<PictureEditorController, PictureEditorState> pictureEditorProvider =
    NotifierProvider<PictureEditorController, PictureEditorState>(
  PictureEditorController.new,
);
