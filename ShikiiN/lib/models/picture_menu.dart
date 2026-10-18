/// 播放器侧「画面调节」菜单/面板的只读视图 + 动作接口。
///
/// 为什么不直接把扩展包模型塞进 shikiin：`picture-pack` 的清单格式属于
/// `dsanima_core`（宿主的格式），播放器不该认识它。这里只定义播放器真正需要的三件事：
/// 有哪些包/预设、每个参数当前是多少、改完怎么让宿主去渲染并挂上。
///
/// 实现在宿主（`app/lib/state/picture_menu_adapter.dart`）：它把「扩展目录 + 模板渲染 +
/// 缓存文件」那套藏在自己的包里，播放器只看到一个 [PictureMenu]。
///
/// 一张菜单/一次面板交互都是**即时读**当前值（右键菜单是每次打开现建的），
/// 所以这里故意不实现 `ChangeNotifier`：谁改了值，谁负责在下次打开菜单时给出新值。
library;

/// 一个可调参数（面板上的一个滑杆）。
class PictureParamInfo {
  const PictureParamInfo({
    required this.key,
    required this.label,
    required this.min,
    required this.max,
    required this.step,
    required this.defaultValue,
    this.group = '',
    this.unit = '',
  });

  final String key;
  final String label;
  final double min;
  final double max;
  final double step;
  final double defaultValue;

  /// 分组名（「锐度与线条」「对比与饱和」…），空串 = 不分组。
  final String group;

  /// 单位后缀（显示用）。
  final String unit;
}

/// 一个预设（菜单里的一档）。
///
/// 只有名字、**没有说明文字**（用户 2026-10-18：「右键菜单内不要有太多介绍，
/// 全在扩展内就好了」）：第一版把预设的 `description` 拼进菜单标签、又原样塞给
/// 子项的 `hint`（子菜单把它渲染成第二行灰字），六档预设直接把子菜单撑成一片小字，
/// 而且同一句话在标签和灰字里各出现一次。预设是干什么的、推荐什么，在扩展页的
/// 「设置」里逐条列着；播放器菜单只留「勾选 + 名称」。
class PicturePresetInfo {
  const PicturePresetInfo({required this.id, required this.name});

  /// 全局唯一的组合 id：`<包 id>/<预设 id>`（菜单是跨包的扁平列表）。
  final String id;
  final String name;
}

/// 播放器与「画面调节」宿主实现之间的唯一契约。
abstract class PictureMenu {
  /// 当前选中的包名（「关」时是最后一次选过的包，可能为空）。
  String get packName;

  /// 当前包的全部参数（面板按这个顺序摆滑杆）。
  List<PictureParamInfo> get params;

  /// 全部包的全部预设（扁平，id 是 `<包>/<预设>`）。
  List<PicturePresetInfo> get presets;

  /// 当前预设 id（null = 手调或关）。
  String? get activePresetId;

  /// 是否处于关闭状态（没有任何画面调节在生效）。
  bool get isOff;

  /// 参数当前值（不在生效状态时按默认值给，面板仍然能拖）。
  double valueOf(String key);

  /// 关掉画面调节。
  Future<void> turnOff();

  /// 套一个预设（null = 关）。
  Future<void> selectPreset(String? presetId);

  /// 选一个包（用于面板第一次打开时把当前包定下来）。
  Future<void> selectPack(String packId, {String? presetId});

  /// 改一个滑杆的值（**只记状态**，面板负责防抖后再调 [applyValues]）。
  void setValue(String key, double value);

  /// 把当前取值渲染成文件并挂上（面板松手/关闭时调用）。
  Future<void> applyValues();

  /// 重新扫盘：扩展目录变了、或用户在扩展页改了**这个包的设置**（预设开关）之后调。
  ///
  /// 为什么放在接口上而不是"重开播放窗口"：播放子窗口是独立引擎，包清单是开窗时扫的
  /// （见 `app/lib/main.dart` 的 `_runPlayerWindow`）。用户 2026-10-18 的新要求里，
  /// 「关闭不需要的预设」是在**扩展页**改的 —— 改完还要关掉播放器再开，用户会以为
  /// 设置没生效。带上这个方法，主窗口改完点一下通知，已开的窗口自己重扫。
  ///
  /// 实现必须**永不抛**：扫不出来最坏是菜单还是旧的，不能把播放窗口弄崩。
  Future<void> reload();
}

/// 菜单里点中的一项：套某个预设 / 关 / 打开滑杆面板。
///
/// 用**一个类**而不是三种回调：右键菜单的 `SubmenuItem.value` 只有一个字段，
/// 界面那边按类型分派（`v is PictureMenuSelection`）最省事。
class PictureMenuSelection {
  const PictureMenuSelection.preset(this.presetId) : openPanel = false;
  const PictureMenuSelection.off()
      : presetId = null,
        openPanel = false;
  const PictureMenuSelection.openPanel()
      : presetId = null,
        openPanel = true;

  /// 要套的预设 id（null = 关）。
  final String? presetId;

  /// true = 不套预设，打开滑杆面板。
  final bool openPanel;
}
