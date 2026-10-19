/// `domain/extensions.dart` 的 `extensionUseHint`：扩展页/安装成功提示的**唯一口径**。
///
/// 通用包（preset-pack / list-pack）必须按它声明的「面」说清"装完在哪儿用"；
/// 未知面如实说"本版本不接运行时"；老的 shader/picture 文案一个字都不许变
/// （用户点进去找不到菜单就是这里指错的）。
library;

import 'package:dsanima/domain/extensions.dart';
import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter_test/flutter_test.dart';

final String _sha = 'a' * 64;

Map<String, Object?> _base(String kind) => <String, Object?>{
      'schema': 1,
      'id': 'p1',
      'name': 'P',
      'version': '1.0.0',
      'kind': kind,
      // 通用包必须写 minAppVersion（1.0.0 = 本用例不触发版本上限检查）。
      'minAppVersion': '1.0.0',
      'files': <Object?>[
        <String, Object?>{'path': 'data/a.bin', 'size': 10, 'sha256': _sha},
      ],
    };

core.ExtensionManifest _preset(String surface) =>
    core.parseExtensionManifest(<String, Object?>{
      ..._base('preset-pack'),
      'files': <Object?>[], // 通用包允许空 files[]
      'payload': <String, Object?>{
        'surface': surface,
        'surfaceSchema': 1,
        'presets': <Object?>[
          <String, Object?>{
            'id': 'a',
            'name': 'A',
            'values': <String, Object?>{},
          },
        ],
      },
    }).manifest!;

core.ExtensionManifest _list(String surface) =>
    core.parseExtensionManifest(<String, Object?>{
      ..._base('list-pack'),
      'files': <Object?>[],
      'payload': <String, Object?>{
        'surface': surface,
        'surfaceSchema': 1,
        'lists': <Object?>[
          <String, Object?>{
            'id': 'weekly',
            'name': '本周',
            'items': <Object?>[
              <String, Object?>{'bangumiId': 1},
            ],
          },
        ],
      },
    }).manifest!;

core.ExtensionManifest _picture() =>
    core.parseExtensionManifest(<String, Object?>{
      ..._base('picture-pack'),
      'files': <Object?>[
        <String, Object?>{'path': 'shaders/p.glsl', 'size': 10, 'sha256': _sha},
      ],
      'payload': <String, Object?>{
        'picture': <String, Object?>{
          'template': 'shaders/p.glsl',
          'params': <Object?>[
            <String, Object?>{
              'key': 'a',
              'label': 'A',
              'min': 0,
              'max': 1,
              'default': 0.5,
            },
          ],
          'presets': <Object?>[
            <String, Object?>{
              'id': 'p',
              'name': 'P',
              'values': <String, Object?>{'a': 0.5},
            },
          ],
        },
      },
    }).manifest!;

core.ExtensionManifest _shader() =>
    core.parseExtensionManifest(<String, Object?>{
      ..._base('shader-pack'),
      'files': <Object?>[
        <String, Object?>{'path': 'shaders/a.glsl', 'size': 10, 'sha256': _sha},
      ],
      'payload': <String, Object?>{
        'shader': <String, Object?>{
          'dir': 'shaders',
          'files': <Object?>['a.glsl'],
        },
      },
    }).manifest!;

core.ExtensionManifest _kind(String kind) =>
    core.parseExtensionManifest(_base(kind)).manifest!;

void main() {
  test('已知面：提示指向播放器设置 →「字幕样式」', () {
    expect(
      extensionUseHint(_preset('player.subtitle')),
      '预设包：装完在播放器设置 →「字幕样式」里选预设',
    );
  });

  test('未知面：明说本版本不接运行时', () {
    expect(
      extensionUseHint(_preset('future.thing')),
      '预设包（面「future.thing」本版本不接运行时）：装得上、暂时不会有新功能',
    );
  });

  test('列表包未知面：同样如实说，不冒充能用', () {
    expect(
      extensionUseHint(_list('home.recommend')),
      '列表包（面「home.recommend」本版本不接运行时）：装得上、暂时不会有新功能',
    );
  });

  test('picture-pack / shader-pack 老文案逐字不变', () {
    expect(
      extensionUseHint(_picture()),
      '画面调节包：装上后进播放器右键菜单的「画面调节」（预设 + 滑杆面板）',
    );
    expect(
      extensionUseHint(_shader()),
      '可在播放器的「超分」菜单里选用',
    );
  });

  test('data-pack / 未知 kind 的老文案逐字不变', () {
    expect(
      extensionUseHint(_kind('data-pack')),
      '本版本不接运行时（数据包装得上、用不上，暂时不会有新功能）',
    );
    expect(
      extensionUseHint(_kind('future-pack')),
      '类型「future-pack」本版本不接运行时，暂时不会有新功能',
    );
  });
}
