/// 「画面调节」右键菜单项（纯函数）：关 / 预设（带勾选） / 调节…。
///
/// 守的是"菜单里点错、或者点了没反应"这类问题：勾选必须跟着当前生效的预设走，
/// 关着的时候一个预设都不能显示成选中。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/picture_menu.dart';
import 'package:shikiin/widgets/context_menu.dart';

/// 一个最小实现的假菜单（只回状态，不做任何事）。
class _FakeMenu implements PictureMenu {
  _FakeMenu({this.off = true, this.activePresetId, this.presets = const <PicturePresetInfo>[]});

  bool off;
  @override
  String? activePresetId;

  @override
  final List<PicturePresetInfo> presets;

  @override
  String get packName => '演示包';

  @override
  List<PictureParamInfo> get params => const <PictureParamInfo>[
        PictureParamInfo(
          key: 'sharpen',
          label: '锐度',
          min: 0,
          max: 2,
          step: 0.05,
          defaultValue: 1,
          group: '锐度与线条',
        ),
      ];

  @override
  bool get isOff => off;

  @override
  double valueOf(String key) => 1;

  @override
  Future<void> applyValues() async {}

  @override
  Future<void> reload() async {}

  @override
  Future<void> selectPack(String packId, {String? presetId}) async {}

  @override
  Future<void> selectPreset(String? presetId) async {}

  @override
  void setValue(String key, double value) {}

  @override
  Future<void> turnOff() async {}
}

void main() {
  const PicturePresetInfo crisp = PicturePresetInfo(id: 'demo/crisp', name: '清晰');
  const PicturePresetInfo soft = PicturePresetInfo(id: 'demo/soft', name: '柔和');

  test('菜单 = 关 + 各预设 + 调节…，顺序与 elementId 稳定', () {
    final List<SubmenuItem> items = pictureSubmenuItems(
      _FakeMenu(presets: const <PicturePresetInfo>[crisp, soft]),
    );
    expect(items.map((SubmenuItem i) => i.label), <String>['关', '清晰', '柔和', '调节…']);
    expect(items.map((SubmenuItem i) => i.elementId), <String>[
      'picture.off',
      'picture.demo/crisp',
      'picture.demo/soft',
      kPicturePanelElementId,
    ]);
  });

  // 用户 2026-10-18：「右键菜单内不要有太多介绍，全在扩展内就好了」。
  // 回归点：第一版把预设的 `description` 拼进 label、又塞进 `hint`（子菜单渲染成
  // 第二行灰字），六档预设直接让子菜单变成一片小字。这里守两件事：
  // 1) 每一项都不带 hint（菜单里不出现说明行的来源）；
  // 2) label 就是名称本身，不带「· 说明」后缀。
  test('每一项只有名称、不带说明文字（用户：菜单里不要太多介绍）', () {
    final List<SubmenuItem> items = pictureSubmenuItems(
      _FakeMenu(presets: const <PicturePresetInfo>[crisp, soft]),
    );
    expect(
      items.every((SubmenuItem i) => i.hint == null),
      isTrue,
      reason: '右键子菜单里不许再出现灰字说明（说明在扩展页「设置」里）',
    );
    expect(
      items.map((SubmenuItem i) => i.label).where((String s) => s.contains(' · ')),
      isEmpty,
      reason: '预设 label 不许拼「名称 · 说明」',
    );
  });

  test('关着时只有「关」被勾选；预设一个都不勾', () {
    final List<SubmenuItem> items =
        pictureSubmenuItems(_FakeMenu(presets: const <PicturePresetInfo>[crisp, soft]));
    expect(items.first.checked, isTrue);
    expect(items.where((SubmenuItem i) => i.checked), hasLength(1));
  });

  test('开着且预设匹配 → 该预设勾选、「关」不勾', () {
    final List<SubmenuItem> items = pictureSubmenuItems(_FakeMenu(
      off: false,
      activePresetId: 'demo/crisp',
      presets: const <PicturePresetInfo>[crisp, soft],
    ));
    expect(items[0].checked, isFalse);
    expect(items[1].checked, isTrue);
    expect(items[2].checked, isFalse);
  });

  test('点预设带的是组合 id；「调节…」带 openPanel 标记', () {
    final List<SubmenuItem> items =
        pictureSubmenuItems(_FakeMenu(presets: const <PicturePresetInfo>[crisp]));
    final PictureMenuSelection preset = items[1].value! as PictureMenuSelection;
    expect(preset.presetId, 'demo/crisp');
    expect(preset.openPanel, isFalse);

    final PictureMenuSelection panel = items.last.value! as PictureMenuSelection;
    expect(panel.openPanel, isTrue);
    expect(panel.presetId, isNull);

    final PictureMenuSelection off = items.first.value! as PictureMenuSelection;
    expect(off.presetId, isNull);
    expect(off.openPanel, isFalse);
  });

  test('没有预设时菜单仍然可用：只有「关」和「调节…」', () {
    final List<SubmenuItem> items = pictureSubmenuItems(_FakeMenu());
    expect(items, hasLength(2));
    expect(items.last.elementId, kPicturePanelElementId);
  });
}
