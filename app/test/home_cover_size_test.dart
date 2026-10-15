/// 「封面大小 / 轮播封面 / 轮播大小」三个设置项的契约测试（决策 F23/F24）。
///
/// 覆盖三件事：
/// 1. 枚举的 code 往返与非法值回落（旧 JSON 缺键、乱码都不能炸）；
/// 2. `AppSettings` 的 JSON 往返 + **旧数据的迁移口径**（旧键 `simpleMode` 忽略、
///    `themeId='light'` 落到白黑、三个新键缺省成 中/横版/中）；
/// 3. 四个 provider 真的从设置里取值（主页网格与轮播都靠它们）。
library;

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/theme/tokens.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

ProviderContainer _containerWith(AppSettings settings) {
  final ProviderContainer c = ProviderContainer(
    overrides: [
      keyValueStoreProvider.overrideWithValue(
        InMemoryKeyValueStore(<String, Object?>{
          SettingsController.storageKey: settings.toJson(),
        }),
      ),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('枚举', () {
    test('DsCoverSize：code 往返 + 非法值回落中档', () {
      for (final DsCoverSize v in DsCoverSize.values) {
        expect(DsCoverSize.fromCode(v.code), v);
      }
      for (final String? bad in <String?>['', 'x', '乱码', null, 'M']) {
        expect(DsCoverSize.fromCode(bad), DsCoverSize.m);
      }
      expect(DsCoverSize.s.maxWidth, 172);
      expect(DsCoverSize.m.maxWidth, 208);
      expect(DsCoverSize.l.maxWidth, 250);
    });

    test('DsCarouselShape / DsCarouselSize：code 往返 + 非法值回落默认', () {
      expect(DsCarouselShape.fromCode('portrait'), DsCarouselShape.portrait);
      expect(DsCarouselShape.fromCode('landscape'), DsCarouselShape.landscape);
      for (final String? bad in <String?>['', 'x', '乱码', null]) {
        expect(DsCarouselShape.fromCode(bad), DsCarouselShape.landscape);
      }
      expect(DsCarouselSize.fromCode('s').k, 0.85);
      expect(DsCarouselSize.fromCode('m').k, 1.2, reason: '中 = 1.2（第三十二轮的上移一档）');
      expect(DsCarouselSize.fromCode('l').k, 1.5, reason: '大 = 本轮新增的最大档');
      for (final String? bad in <String?>['', 'x', '乱码', null]) {
        expect(DsCarouselSize.fromCode(bad), DsCarouselSize.m);
      }
    });
  });

  group('AppSettings', () {
    test('默认值：themeId 白橙、三个新键 = 中/横版/中', () {
      const AppSettings d = AppSettings();
      expect(d.themeId, 'w_orange');
      expect(d.homeCoverSize, 'm');
      expect(d.carouselShape, 'landscape');
      expect(d.carouselSize, 'm');
    });

    test('JSON 往返：三个新字段原样带回', () {
      const AppSettings s = AppSettings(
        themeId: 'b_neon',
        homeCoverSize: 'l',
        carouselShape: 'portrait',
        carouselSize: 's',
      );
      final AppSettings back = AppSettings.fromJson(s.toJson());
      expect(back.themeId, 'b_neon');
      expect(back.homeCoverSize, 'l');
      expect(back.carouselShape, 'portrait');
      expect(back.carouselSize, 's');
    });

    test('旧 JSON 迁移：缺三个新键 → 默认；themeId=light → 白黑；simpleMode 被忽略且不再写出', () {
      final AppSettings old = AppSettings.fromJson(<Object?, Object?>{
        'themeId': 'light',
        'simpleMode': true,
        'downloadDir': r'D:\anime',
      });
      expect(old.themeId, 'light'); // 原样保留，交给 DsAppearance.fromCode 迁移
      expect(DsAppearance.fromCode(old.themeId), DsAppearance.wInk);
      expect(old.homeCoverSize, 'm');
      expect(old.carouselShape, 'landscape');
      expect(old.carouselSize, 'm');
      expect(old.downloadDir, r'D:\anime', reason: '不能丢其它设置');
      expect(old.toJson().containsKey('simpleMode'), isFalse, reason: '字段已删除，不再写出');
    });

    test('脏数据容错：三个新键类型不对也能回落默认（不崩）', () {
      final AppSettings dirty = AppSettings.fromJson(<Object?, Object?>{
        'homeCoverSize': 42,
        'carouselShape': <String>['portrait'],
        'carouselSize': null,
      });
      expect(dirty.homeCoverSize, 'm');
      expect(dirty.carouselShape, 'landscape');
      expect(dirty.carouselSize, 'm');
    });

    test('isDarkTheme：四套黑色系为真，白色系与旧值 light 为假', () {
      for (final String code in <String>['b_neon', 'b_electric', 'b_mono', 'b_red']) {
        expect(AppSettings(themeId: code).isDarkTheme, isTrue, reason: code);
      }
      for (final String code in <String>['w_orange', 'w_purple', 'w_mint', 'w_ink', 'light', '乱码']) {
        expect(AppSettings(themeId: code).isDarkTheme, isFalse, reason: code);
      }
    });
  });

  group('provider 接线', () {
    test('四个 provider 都从设置里取值', () {
      final ProviderContainer c = _containerWith(
        const AppSettings(
          themeId: 'b_neon',
          homeCoverSize: 'l',
          carouselShape: 'portrait',
          carouselSize: 's',
        ),
      );
      expect(c.read(themeAppearanceProvider), DsAppearance.bNeon);
      expect(c.read(themeTokensProvider), DsTokens.blackNeon);
      expect(c.read(homeCoverSizeProvider), DsCoverSize.l);
      expect(c.read(carouselShapeProvider), DsCarouselShape.portrait);
      expect(c.read(carouselSizeProvider), DsCarouselSize.s);
    });

    test('乱码 themeId：外观回落白黑，token 跟着回落', () {
      final ProviderContainer c = _containerWith(
        const AppSettings(themeId: '乱码'),
      );
      expect(c.read(themeAppearanceProvider), DsAppearance.wInk);
      expect(c.read(themeTokensProvider), DsTokens.whiteInk);
    });
  });
}
