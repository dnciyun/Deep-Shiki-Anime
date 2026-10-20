/// 「我的组合」：用户自己把一套画面取值存下来的命名集合。
///
/// 为什么单独一个领域对象、单独一份文件（`picture-combos.json`）：
/// * `picture-settings.json` 是"**现在生效的是哪一套**"（两个窗口都会写：主窗口页面写、
///   播放窗口每次真正下发后写回），而组合是"**用户攒下来的几套**"（只有主窗口页面写）。
///   两者放同一份文件，两边同时写必然互相覆盖 —— 播放窗口一次 `apply` 就会把用户刚存的
///   组合抹掉。这一点和 `picture-settings.json` 与 `extension-settings.json` 分家的
///   理由完全一样（见 `state/picture_settings_io.dart` 文件头）。
/// * 组合要进播放器右键菜单（「我的 · 夜间」），而菜单是**跨包扁平**的：需要一个
///   「包 + 组合」合起来的 id，于是这里给出 [pictureComboIdOf] / [parsePictureComboId]
///   这一对拼装函数 —— 菜单里只认得字符串，别让菜单自己拼格式。
///
/// 编码约定（与 `PictureMenuAdapter` 里预设的组合 id 同构）：
/// `<包 id> / custom: <组合 id>`，例如 `picture-demo/custom:c1712...`。
/// `custom:` 这个前缀就是"这不是包自带预设、而是我自己存的组合"的唯一标记：
/// 包自带预设的 id 里有 `:` 是不可能的（core 的预设 id 判据只允许小写字母/数字/`._-`），
/// 所以两者永远不会撞。
///
/// 坏数据一律**只退化**：手改/半截的文件读出来最多是"没有这个组合"，
/// 绝不能让画面页或播放窗口起不来。
library;

import 'package:flutter/foundation.dart';

/// 自定义组合 id 的前缀（见文件头的编码约定）。
const String kPictureComboPrefix = 'custom:';

/// 一个「我的组合」：一个名字 + 一套完整取值。
///
/// [values] 存的是**完整取值**（默认值 + 覆盖），因为组合可能是在某个预设基础上微调的：
/// 只存差异的话，"包换了默认值"之后同一套组合会变成另一套画面。
@immutable
class PictureCombo {
  const PictureCombo({
    required this.id,
    required this.name,
    this.values = const <String, double>{},
  });

  /// 包内唯一（不需要全局唯一：全局 id 由 [pictureComboIdOf] 拼上包 id）。
  final String id;

  /// 用户起的名字（界面上显示成「我的 · <名字>」）。
  final String name;

  /// 参数名 → 取值。
  final Map<String, double> values;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'values': <String, Object?>{for (final MapEntry<String, double> e in values.entries) e.key: e.value},
      };

  @override
  bool operator ==(Object other) =>
      other is PictureCombo &&
      other.id == id &&
      other.name == name &&
      mapEquals(other.values, values);

  @override
  int get hashCode => Object.hash(id, name, values.length);

  @override
  String toString() => 'PictureCombo($id $name $values)';
}

/// 菜单/选中状态里用的全局组合 id：`<包 id>/custom:<组合 id>`。
String pictureComboIdOf(String packId, String comboId) =>
    '$packId/$kPictureComboPrefix$comboId';

/// 反向拆 [pictureComboIdOf]；不是自定义组合（或格式不对）返回 null。
///
/// 为什么"格式不对"返回 null 而不是抛/猜：菜单里的值是我们自己造的，但持久化的
/// `preset` 字段可能被手改过（用户/旧版本），那时只该"当没有这个组合"。
({String packId, String comboId})? parsePictureComboId(String id) {
  final int slash = id.indexOf('/');
  if (slash <= 0 || slash >= id.length - 1) return null;
  final String rest = id.substring(slash + 1);
  if (!rest.startsWith(kPictureComboPrefix)) return null;
  final String comboId = rest.substring(kPictureComboPrefix.length);
  if (comboId.isEmpty) return null;
  return (packId: id.substring(0, slash), comboId: comboId);
}

/// `picture-combos.json` 的正文 → 按包分组的组合表。
///
/// 期望形状：`{"<packId>": [{"id","name","values":{...}}, ...]}`。
/// **永不抛**：不是 Map、某一项不是 Map、缺 id/name/values 项 → 跳过那一项
/// （"坏一项丢一项"比"整份作废"更接近用户预期：手改坏一个组合不该把其余的清空）。
Map<String, List<PictureCombo>> combosFromJson(Object? json) {
  if (json is! Map) return const <String, List<PictureCombo>>{};
  final Map<String, List<PictureCombo>> out = <String, List<PictureCombo>>{};
  for (final MapEntry<Object?, Object?> entry in json.entries) {
    final String packId = '${entry.key}'.trim();
    if (packId.isEmpty) continue;
    final Object? rawList = entry.value;
    if (rawList is! List) continue;
    final List<PictureCombo> combos = <PictureCombo>[];
    for (final Object? raw in rawList) {
      final PictureCombo? combo = _comboOf(raw);
      if (combo != null) combos.add(combo);
    }
    if (combos.isEmpty) continue;
    out[packId] = List<PictureCombo>.unmodifiable(combos);
  }
  return out;
}

/// 一项组合的解析；形状不对返回 null（调用方跳过它）。
PictureCombo? _comboOf(Object? raw) {
  if (raw is! Map) return null;
  final Object? id = raw['id'];
  final Object? name = raw['name'];
  if (id is! String || id.trim().isEmpty) return null;
  if (name is! String || name.trim().isEmpty) return null;
  final Object? rawValues = raw['values'];
  // 缺 values 的组合没有意义（套上去 = 什么都不改），按坏项跳过。
  if (rawValues is! Map) return null;
  final Map<String, double> values = <String, double>{};
  for (final MapEntry<Object?, Object?> e in rawValues.entries) {
    final Object? v = e.value;
    if (v is num) values['${e.key}'] = v.toDouble();
  }
  return PictureCombo(
    id: id.trim(),
    name: name.trim(),
    values: Map<String, double>.unmodifiable(values),
  );
}

/// 组合表 → 文件正文。
///
/// 空列表的包**不写**：用户删掉某包的最后一个组合之后，文件里不该留下一个空数组
/// （否则"包卸载了，键还一直在"）。
Map<String, Object?> combosToJson(Map<String, List<PictureCombo>> byPack) =>
    <String, Object?>{
      for (final MapEntry<String, List<PictureCombo>> e in byPack.entries)
        if (e.key.trim().isNotEmpty && e.value.isNotEmpty)
          e.key: <Object?>[for (final PictureCombo combo in e.value) combo.toJson()],
    };
