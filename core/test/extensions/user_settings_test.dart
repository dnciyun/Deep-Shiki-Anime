/// 扩展用户设置（`core/lib/extensions/user_settings.dart`）：预设开关 + 目录地址。
///
/// 两件事必须钉住：
/// * **脏数据不许抛**：这个文件在数据根里，用户可能手改、旧版本可能写坏，扩展页
///   起不来比丢一条设置糟得多；
/// * **写出去要能读回来**：`toJson → fromJson` 必须稳定（否则用户关了预设、重启又回来）。
library;

import 'package:dsanima_core/dsanima_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('预设开关', () {
    test('关掉的预设能写能读（含排序，稳定）', () {
      final ExtensionUserSettings s = ExtensionUserSettings.empty
          .withHiddenPresets('pack.a', <String>{'warm', 'extreme'});
      final Map<String, Object?> json = s.toJson();
      expect(
        (json['extensions']! as Map<String, Object?>)['pack.a'],
        <String, Object?>{
          'hiddenPresets': <String>['extreme', 'warm'],
        },
      );
      final ExtensionUserSettings back = ExtensionUserSettings.fromJson(json);
      expect(back.hiddenPresetsOf('pack.a'), <String>{'extreme', 'warm'});
      expect(back, s);
    });

    test('空集合 = "设置过、但一个都没关"（与"从没设置过"可区分）', () {
      final ExtensionUserSettings s =
          ExtensionUserSettings.empty.withHiddenPresets('pack.a', <String>{});
      expect(s.hasExtensionSettings('pack.a'), isTrue);
      expect(s.hiddenPresetsOf('pack.a'), isEmpty);
      expect(ExtensionUserSettings.empty.hasExtensionSettings('pack.a'), isFalse);
    });

    test('没有设置过的扩展返回空集合（调用方不用判 null）', () {
      expect(ExtensionUserSettings.empty.hiddenPresetsOf('nope'), isEmpty);
    });

    test('卸载扩展时可以把它的设置清掉', () {
      final ExtensionUserSettings s = ExtensionUserSettings.empty
          .withHiddenPresets('a', <String>{'x'})
          .withHiddenPresets('b', <String>{'y'});
      final ExtensionUserSettings cut = s.withoutExtension('a');
      expect(cut.hasExtensionSettings('a'), isFalse);
      expect(cut.hiddenPresetsOf('b'), <String>{'y'});
      // 没有的 id：原样返回（不白造一份新对象也无所谓，语义一样）
      expect(cut.withoutExtension('zzz'), cut);
    });
  });

  group('catalogUrl', () {
    test('记上一次成功的目录地址，空串当没填', () {
      expect(
        ExtensionUserSettings.empty.withCatalogUrl(' https://example.com/c.json ').catalogUrl,
        'https://example.com/c.json',
      );
      expect(ExtensionUserSettings.empty.withCatalogUrl('   ').catalogUrl, isNull);
      expect(ExtensionUserSettings.empty.withCatalogUrl(null).catalogUrl, isNull);
    });
  });

  group('脏数据容忍（不抛、只丢那一条）', () {
    test('不是对象 / 字段类型不对 → 空设置', () {
      expect(ExtensionUserSettings.fromJson(null), ExtensionUserSettings.empty);
      expect(ExtensionUserSettings.fromJson('nope'), ExtensionUserSettings.empty);
      expect(ExtensionUserSettings.fromJson(<Object?>[1, 2]), ExtensionUserSettings.empty);
      expect(
        ExtensionUserSettings.fromJson(<String, Object?>{
          'schema': 1,
          'catalogUrl': 42,
          'extensions': 'nope',
        }),
        ExtensionUserSettings.empty,
      );
    });

    test('单条坏条目不影响其它条目', () {
      final ExtensionUserSettings s = ExtensionUserSettings.fromJson(<String, Object?>{
        'extensions': <String, Object?>{
          'good': <String, Object?>{
            'hiddenPresets': <Object?>['a', 3, '', 'b'],
          },
          'bad-map': 7,
          'bad-list': <String, Object?>{'hiddenPresets': 'a'},
        },
      });
      expect(s.hiddenPresetsOf('good'), <String>{'a', 'b'});
      expect(s.hasExtensionSettings('bad-map'), isFalse);
      expect(s.hasExtensionSettings('bad-list'), isFalse);
    });

    test('超量 id 被截断（防手改文件写几万条）', () {
      final Object huge = <Object?>[
        for (int i = 0; i < kMaxHiddenPresetsPerExtension + 50; i++) 'p$i',
      ];
      final ExtensionUserSettings s = ExtensionUserSettings.fromJson(<String, Object?>{
        'extensions': <String, Object?>{
          'x': <String, Object?>{'hiddenPresets': huge},
        },
      });
      expect(s.hiddenPresetsOf('x'), hasLength(kMaxHiddenPresetsPerExtension));
    });

    test('schema 不认识的版本也照读（未来加字段只加不改）', () {
      final ExtensionUserSettings s = ExtensionUserSettings.fromJson(<String, Object?>{
        'schema': 9,
        'unknownFutureField': true,
        'extensions': <String, Object?>{
          'x': <String, Object?>{'hiddenPresets': <String>['a']},
        },
      });
      expect(s.hiddenPresetsOf('x'), <String>{'a'});
    });
  });
}
