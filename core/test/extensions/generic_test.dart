/// 通用扩展载荷（`preset-pack` / `list-pack`）解析的离线判据。
///
/// 每条测试对应 `generic.dart` 里的一条判据：surface 白名单、`surfaceSchema`、
/// 值类型/区间/颜色、assets 与 files[] 的对应、形状互斥、上限、未知面只 warning。
/// 断言精确到 [ManifestIssue.field]，而不是只看 `issues.isEmpty`。
library;

import 'package:dsanima_core/dsanima_core.dart';
import 'package:flutter_test/flutter_test.dart';

// ── 夹具 ────────────────────────────────────────────────────────────────────

/// 一个预设（默认合法：id/name/values 都齐）。
Map<String, Object?> _preset(
  Map<String, Object?> values, {
  String id = 'cinema',
  String name = '影院',
  Object? description = '',
}) =>
    <String, Object?>{
      'id': id,
      'name': name,
      'description': ?description,
      'values': values,
    };

/// 一个字体资产（默认合法）。
Map<String, Object?> _fontAsset(
  String path, {
  String role = 'font',
  String family = '字体 A',
}) =>
    <String, Object?>{'path': path, 'role': role, 'family': family};

/// `player.subtitle` 的合法载荷（一个预设 + 一个字体资产）。
Map<String, Object?> _presetPayload({
  String surface = 'player.subtitle',
  Object? surfaceSchema = 1,
  List<Object?>? assets,
  List<Object?>? presets,
}) =>
    <String, Object?>{
      'surface': surface,
      'surfaceSchema': surfaceSchema,
      'assets': ?assets,
      'presets': presets ??
          <Object?>[
            _preset(<String, Object?>{'scale': 1.6}),
          ],
    };

/// 测试内注入的列表面（默认注册表里没有列表面）。
const ExtensionSurface _fakeListSurface = ExtensionSurface(
  id: 'test.list',
  payloadKind: SurfacePayloadKind.list,
  schema: 1,
  label: '测试列表',
  hostHint: '测试用',
  hostWindow: 'main',
  itemFields: <SurfaceField>[
    SurfaceField(key: 'title', type: SurfaceValueType.string, required: true),
    SurfaceField(key: 'count', type: SurfaceValueType.integer),
    SurfaceField(key: 'cover', type: SurfaceValueType.url),
  ],
);

Map<String, Object?> _listPayload({
  String surface = 'test.list',
  List<Object?>? lists,
}) =>
    <String, Object?>{
      'surface': surface,
      'surfaceSchema': 1,
      'lists': lists ??
          <Object?>[
            <String, Object?>{
              'id': 'weekly',
              'name': '本周精选',
              'items': <Object?>[
                <String, Object?>{'title': '葬送的芙莉莲'},
              ],
            },
          ],
    };

GenericPayloadParseResult _parse(Map<String, Object?> payload,
        {List<ExtensionSurface> surfaces = kExtensionSurfaces,
        Set<String> declaredPathsLower = const <String>{}}) =>
    parseGenericPayload(kPresetPackKind, payload,
        declaredPathsLower: declaredPathsLower, surfaces: surfaces);

/// 所有 issue 的 field 列表（断言用）。
List<String> _fields(GenericPayloadParseResult r) =>
    r.issues.map((ManifestIssue i) => i.field).toList();

// ── preset-pack ─────────────────────────────────────────────────────────────

void main() {
  test('preset-pack：合法载荷解析出 1 个预设与 1 个字体资产', () {
    final r = _parse(
      _presetPayload(
        assets: <Object?>[_fontAsset('fonts/a.ttf')],
        presets: <Object?>[
          _preset(<String, Object?>{'scale': 1.6, 'color': '#FFFFFF'}),
        ],
      ),
      declaredPathsLower: <String>{'fonts/a.ttf'},
    );
    expect(_fields(r), isEmpty);
    expect(r.warnings, isEmpty);
    expect(r.payload!.surface, 'player.subtitle');
    expect(r.payload!.surfaceSchema, 1);
    expect(r.payload!.assets.single.family, '字体 A');
    expect(r.payload!.presets.single.values['scale'], 1.6);
    // 6 位颜色补成 ARGB（与 SubtitleStyle 的字符串同口径）
    expect(r.payload!.presets.single.values['color'], '#FFFFFFFF');
  });

  test('preset-pack：未知 surface 只 warning、不拒装', () {
    final r = _parse(
      <String, Object?>{
        'surface': 'future.thing',
        'surfaceSchema': 1,
        'presets': <Object?>[
          // 未知面不校验 values 的键（宿主还不认识它）
          _preset(<String, Object?>{'whatever': 1}),
        ],
      },
    );
    expect(_fields(r), isEmpty);
    expect(r.warnings.single.field, 'payload.surface');
    expect(r.payload!.surface, 'future.thing');
  });

  test('preset-pack：surfaceSchema 必须是声称的那个版本', () {
    final r = _parse(_presetPayload(surfaceSchema: 2));
    expect(_fields(r), contains('payload.surfaceSchema'));
  });

  test('preset-pack：surface 缺失 → 拒', () {
    final r = _parse(<String, Object?>{
      'surfaceSchema': 1,
      'presets': <Object?>[_preset(<String, Object?>{})],
    });
    expect(_fields(r), contains('payload.surface'));
  });

  test('preset-pack：values 拼错字段 → 拒，field 指到具体参数', () {
    final r = _parse(
      _presetPayload(
        presets: <Object?>[
          _preset(<String, Object?>{'scael': 1.6}),
        ],
      ),
    );
    expect(_fields(r), contains('payload.presets[0].values.scael'));
  });

  test('preset-pack：number 越界 → 拒', () {
    final r = _parse(
      _presetPayload(
        presets: <Object?>[
          _preset(<String, Object?>{'scale': 9}),
        ],
      ),
    );
    expect(_fields(r), contains('payload.presets[0].values.scale'));
  });

  test('preset-pack：integer 写成小数 → 拒', () {
    final r = _parse(
      _presetPayload(
        presets: <Object?>[
          _preset(<String, Object?>{'pos': 1.5}),
        ],
      ),
    );
    expect(_fields(r), contains('payload.presets[0].values.pos'));
  });

  test('preset-pack：颜色格式坏 → 拒', () {
    final r = _parse(
      _presetPayload(
        presets: <Object?>[
          _preset(<String, Object?>{'color': '#12345'}),
        ],
      ),
    );
    expect(_fields(r), contains('payload.presets[0].values.color'));
  });

  test('preset-pack：boolean 类型错 → 拒', () {
    final r = _parse(
      _presetPayload(
        presets: <Object?>[
          _preset(<String, Object?>{'bold': 'yes'}),
        ],
      ),
    );
    expect(_fields(r), contains('payload.presets[0].values.bold'));
  });

  test('preset-pack：重复预设 id → 拒', () {
    final r = _parse(
      _presetPayload(
        presets: <Object?>[
          _preset(<String, Object?>{}, id: 'cinema'),
          _preset(<String, Object?>{}, id: 'cinema', name: '另一个'),
        ],
      ),
    );
    expect(_fields(r), contains('payload.presets[1].id'));
  });

  test('assets：路径没列进 files[] → 拒', () {
    final r = _parse(
      _presetPayload(assets: <Object?>[_fontAsset('fonts/a.ttf')]),
    );
    expect(_fields(r), contains('payload.assets[0].path'));
  });

  test('assets：role 不是 font → 拒', () {
    final r = _parse(
      _presetPayload(assets: <Object?>[_fontAsset('fonts/a.ttf', role: 'image')]),
      declaredPathsLower: <String>{'fonts/a.ttf'},
    );
    expect(_fields(r), contains('payload.assets[0].role'));
  });

  test('assets：字体后缀不是 ttf/otf → 拒', () {
    final r = _parse(
      _presetPayload(assets: <Object?>[_fontAsset('fonts/a.woff')]),
      declaredPathsLower: <String>{'fonts/a.woff'},
    );
    expect(_fields(r), contains('payload.assets[0].path'));
  });

  test('形状互斥：preset-pack 带 lists / list-pack 带 assets → 拒', () {
    final presetWithLists = _parse(<String, Object?>{
      'surface': 'player.subtitle',
      'surfaceSchema': 1,
      'presets': <Object?>[_preset(<String, Object?>{})],
      'lists': <Object?>[],
    });
    expect(_fields(presetWithLists), contains('payload.lists'));

    final listWithAssets = parseGenericPayload(
      kListPackKind,
      <String, Object?>{
        ..._listPayload(),
        'assets': <Object?>[_fontAsset('fonts/a.ttf')],
      },
      declaredPathsLower: <String>{'fonts/a.ttf'},
      surfaces: <ExtensionSurface>[_fakeListSurface],
    );
    expect(_fields(listWithAssets), contains('payload.assets'));
  });

  test('上限：presets 33 / assets 17 → 拒', () {
    final presets = <Object?>[
      for (int i = 0; i < 33; i++) _preset(<String, Object?>{}, id: 'p$i'),
    ];
    expect(_fields(_parse(_presetPayload(presets: presets))),
        contains('payload.presets'));

    final assets = <Object?>[
      for (int i = 0; i < 17; i++) _fontAsset('fonts/a$i.ttf'),
    ];
    final declared = <String>{
      for (int i = 0; i < 17; i++) 'fonts/a$i.ttf',
    };
    expect(
      _fields(_parse(_presetPayload(assets: assets),
          declaredPathsLower: declared)),
      contains('payload.assets'),
    );
  });

  // ── list-pack ────────────────────────────────────────────────────────────

  test('list-pack：注入的列表面能解析 items', () {
    final r = parseGenericPayload(
      kListPackKind,
      _listPayload(lists: <Object?>[
        <String, Object?>{
          'id': 'weekly',
          'name': '本周精选',
          'items': <Object?>[
            <String, Object?>{'title': '芙莉莲', 'count': 2},
          ],
        },
      ]),
      declaredPathsLower: <String>{},
      surfaces: <ExtensionSurface>[_fakeListSurface],
    );
    expect(_fields(r), isEmpty);
    final items = r.payload!.lists.single.items;
    expect(items.single['title'], '芙莉莲');
    expect(items.single['count'], 2);
  });

  test('list-pack：默认注册表没有列表面 → 未知面 warning（可装）', () {
    final r = parseGenericPayload(
      kListPackKind,
      _listPayload(),
      declaredPathsLower: <String>{},
    );
    expect(_fields(r), isEmpty);
    expect(r.warnings.single.field, 'payload.surface');
  });

  test('kind 与面吃的载荷类型写反 → 拒（field 指向 payload.surface）', () {
    // player.subtitle 吃的是预设；写成 list-pack 会出现「装得上、扩展页指错入口、播放器 0 预设」。
    final r = parseGenericPayload(
      kListPackKind,
      _listPayload(surface: 'player.subtitle'),
      declaredPathsLower: <String>{},
    );
    expect(_fields(r), contains('payload.surface'));
  });

  test('list-pack：item 缺必填字段 / 多未知字段 / URL 不安全 → 拒', () {
    List<String> fieldsOf(Object? item) => _fields(parseGenericPayload(
          kListPackKind,
          _listPayload(lists: <Object?>[
            <String, Object?>{
              'id': 'weekly',
              'name': '本周',
              'items': <Object?>[item],
            },
          ]),
          declaredPathsLower: <String>{},
          surfaces: <ExtensionSurface>[_fakeListSurface],
        ));

    expect(fieldsOf(<String, Object?>{'count': 1}),
        contains('payload.lists[0].items[0].title'));
    expect(fieldsOf(<String, Object?>{'title': 'x', 'nope': 1}),
        contains('payload.lists[0].items[0].nope'));
    expect(fieldsOf(<String, Object?>{'title': 'x', 'cover': 'ftp://a/b'}),
        contains('payload.lists[0].items[0].cover'));
  });

  test('上限：lists 9 / items 201 → 拒', () {
    final nineLists = <Object?>[
      for (int i = 0; i < 9; i++)
        <String, Object?>{
          'id': 'l$i',
          'name': '列表 $i',
          'items': <Object?>[
            <String, Object?>{'title': 'x'},
          ],
        },
    ];
    final r1 = parseGenericPayload(
      kListPackKind,
      _listPayload(lists: nineLists),
      declaredPathsLower: <String>{},
      surfaces: <ExtensionSurface>[_fakeListSurface],
    );
    expect(_fields(r1), contains('payload.lists'));

    final r2 = parseGenericPayload(
      kListPackKind,
      _listPayload(lists: <Object?>[
        <String, Object?>{
          'id': 'weekly',
          'name': '本周',
          'items': <Object?>[
            for (int i = 0; i < 201; i++) <String, Object?>{'title': 'x$i'},
          ],
        },
      ]),
      declaredPathsLower: <String>{},
      surfaces: <ExtensionSurface>[_fakeListSurface],
    );
    expect(_fields(r2), contains('payload.lists[0].items'));
  });

  // ── 外形与颜色 ───────────────────────────────────────────────────────────

  test('payload 不是对象 / 顶层多了未知键 → 拒', () {
    final notMap = parseGenericPayload(kPresetPackKind, 'x',
        declaredPathsLower: <String>{});
    expect(_fields(notMap), contains('payload'));

    final extra = _parse(<String, Object?>{
      ..._presetPayload(),
      'shader': <String, Object?>{},
    });
    expect(_fields(extra), contains('payload.shader'));
  });

  test('非通用 kind → 拒', () {
    final r = parseGenericPayload('shader-pack', <String, Object?>{},
        declaredPathsLower: <String>{});
    expect(_fields(r), contains('kind'));
  });

  test('normalizeExtensionColor：6 位补 ARGB、8 位转大写、坏值 null', () {
    expect(normalizeExtensionColor('#AABBCC'), '#FFAABBCC');
    expect(normalizeExtensionColor('aabbccdd'), '#AABBCCDD');
    expect(normalizeExtensionColor('#ABC'), isNull);
    expect(normalizeExtensionColor('#GGGGGG'), isNull);
    expect(normalizeExtensionColor(''), isNull);
  });
}
