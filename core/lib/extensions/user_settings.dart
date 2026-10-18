/// 扩展的**用户设置**（不是扩展自己的清单）：目前两件事 ——
/// 上次成功拉取的目录地址（「官方插件库」按钮要用）、以及某个包被用户关掉的预设。
///
/// 为什么单独一个文件、而不是塞进 `extensions/state.json`：state.json 是**安装**状态
/// （装了什么、开没开、从哪儿装的），由安装器整份读写；用户设置是"我个人的偏好"，
/// 升级/重装扩展都不该丢。两者写同一份文件的话，一边重写就会把另一边抹掉。
///
/// 为什么放在 `dsanima_core`：解析必须**不抛**（用户手改/旧版本写坏的文件只能退化，
/// 不能让扩展页起不来），这种"脏数据容忍"逻辑归 core 用测试钉住；读写磁盘留在宿主。
///
/// 文件位置：`<数据根>/dsanima/extension-settings.json`。
/// 结构（schema 1，未来加字段只加不改）：
/// ```json
/// {
///   "schema": 1,
///   "catalogUrl": "https://raw.githubusercontent.com/owner/repo/main/catalog.json",
///   "extensions": {
///     "dsanima-picture-crisp": {"hiddenPresets": ["warm"]}
///   }
/// }
/// ```
library;

/// 每个扩展最多记多少个"关掉的预设"（防御手改文件写四万个 id）。
const int kMaxHiddenPresetsPerExtension = 200;

/// 最多记多少个扩展的设置（同上）。
const int kMaxExtensionSettingsEntries = 200;

/// 扩展的用户设置（不可变；改一份就用 `with…` 造新的）。
class ExtensionUserSettings {
  const ExtensionUserSettings({
    this.catalogUrl,
    this.hiddenPresets = const <String, Set<String>>{},
  });

  /// 扩展 id → 被用户关掉的预设 id。
  final Map<String, Set<String>> hiddenPresets;

  /// 上一次成功拉取的目录地址（原样保存，可能是 GitHub 网页地址或 raw/json 直链）。
  final String? catalogUrl;

  static const ExtensionUserSettings empty = ExtensionUserSettings();

  /// 某个扩展被关掉的预设 id（没有设置 = 空集合，调用方不用判 null）。
  Set<String> hiddenPresetsOf(String extensionId) =>
      hiddenPresets[extensionId] ?? const <String>{};

  /// 这个扩展**有没有**打开过设置（用于界面区分"从没设置过" vs "全部设为默认"）。
  bool hasExtensionSettings(String extensionId) => hiddenPresets.containsKey(extensionId);

  /// 换某个扩展的"关掉的预设"（空集合 = 设置过、但一个都没关；用来在界面上
  /// 表达"我确认过这个包的预设"）。
  ExtensionUserSettings withHiddenPresets(String extensionId, Set<String> presetIds) {
    final Map<String, Set<String>> next = <String, Set<String>>{
      ...hiddenPresets,
      extensionId: Set<String>.unmodifiable(<String>{...presetIds}.take(kMaxHiddenPresetsPerExtension)),
    };
    return ExtensionUserSettings(catalogUrl: catalogUrl, hiddenPresets: next);
  }

  /// 去掉某个扩展的设置（卸载扩展时清掉它，免得状态文件无限长）。
  ExtensionUserSettings withoutExtension(String extensionId) {
    if (!hiddenPresets.containsKey(extensionId)) return this;
    return ExtensionUserSettings(
      catalogUrl: catalogUrl,
      hiddenPresets: <String, Set<String>>{
        for (final MapEntry<String, Set<String>> e in hiddenPresets.entries)
          if (e.key != extensionId) e.key: e.value,
      },
    );
  }

  ExtensionUserSettings withCatalogUrl(String? url) {
    final String? clean = url == null || url.trim().isEmpty ? null : url.trim();
    return ExtensionUserSettings(catalogUrl: clean, hiddenPresets: hiddenPresets);
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'schema': 1,
        if (catalogUrl != null) 'catalogUrl': catalogUrl,
        if (hiddenPresets.isNotEmpty)
          'extensions': <String, Object?>{
            for (final MapEntry<String, Set<String>> e in hiddenPresets.entries)
              e.key: <String, Object?>{
                'hiddenPresets': e.value.toList(growable: false)..sort(),
              },
          },
      };

  /// 从 json 读；**任何一项不合法都不抛**，只把那一条丢掉（旧版本/手改文件只该退化）。
  static ExtensionUserSettings fromJson(Object? json) {
    if (json is! Map) return empty;
    final Object? rawCatalog = json['catalogUrl'];
    final String? catalogUrl =
        rawCatalog is String && rawCatalog.trim().isNotEmpty ? rawCatalog.trim() : null;

    final Object? rawExtensions = json['extensions'];
    final Map<String, Set<String>> hidden = <String, Set<String>>{};
    if (rawExtensions is Map) {
      int count = 0;
      for (final MapEntry<Object?, Object?> entry in rawExtensions.entries) {
        if (count >= kMaxExtensionSettingsEntries) break;
        final String id = '${entry.key}'.trim();
        if (id.isEmpty) continue;
        final Object? value = entry.value;
        if (value is! Map) continue;
        final Object? rawPresets = value['hiddenPresets'];
        if (rawPresets is! List) continue;
        final Set<String> presets = <String>{};
        for (final Object? item in rawPresets) {
          if (presets.length >= kMaxHiddenPresetsPerExtension) break;
          if (item is String && item.trim().isNotEmpty) presets.add(item.trim());
        }
        hidden[id] = Set<String>.unmodifiable(presets);
        count++;
      }
    }
    return ExtensionUserSettings(catalogUrl: catalogUrl, hiddenPresets: hidden);
  }

  @override
  bool operator ==(Object other) {
    if (other is! ExtensionUserSettings) return false;
    if (other.catalogUrl != catalogUrl) return false;
    if (other.hiddenPresets.length != hiddenPresets.length) return false;
    for (final MapEntry<String, Set<String>> e in hiddenPresets.entries) {
      final Set<String>? theirs = other.hiddenPresets[e.key];
      if (theirs == null || theirs.length != e.value.length) return false;
      if (!theirs.containsAll(e.value)) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        catalogUrl,
        hiddenPresets.length,
        Object.hashAll(<Object>[
          for (final MapEntry<String, Set<String>> e in hiddenPresets.entries)
            Object.hash(e.key, Object.hashAll(e.value.toList()..sort())),
        ]),
      );

  @override
  String toString() =>
      'ExtensionUserSettings(catalogUrl: $catalogUrl, hidden: ${hiddenPresets.length} 个扩展)';
}
