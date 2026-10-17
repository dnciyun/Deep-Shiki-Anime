/// 种子块的「字幕语言过滤」（第四十八轮·补九）的判定表。
///
/// 用户原话：
/// > 「加入按钮，点一次只显示简体，再点一次只显示繁体，再点一次恢复」
///
/// 标题全部是**真抓的**（mikan 搜索页，`build/round48c/uw_titles_833.txt` 与
/// `sg_titles.txt`）—— 这一层跟版本判定一样：换个写法就容易判错，真标题钉进用例最省事
/// （833 条里简体 263 / 繁体 282 / 简繁 177 / 没标 111）。
library;

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/seed_language.dart';
import 'package:flutter_test/flutter_test.dart';

SourceItemView _item(String title) => SourceItemView(
  id: 'mikan:$title',
  sourceId: 'mikan',
  title: title,
  magnet: 'magnet:?xt=urn:btih:${title.hashCode.toRadixString(16)}',
);

void main() {
  group('seedTitleMarksSimplified / Traditional：真标题', () {
    test('简体：简体内嵌 / 简中 / GB / CHS / 简日', () {
      for (final String title in <String>[
        '[桜都字幕组] 无职转生 第三季 ～到了异世界就拿出真本事～ / '
            'Mushoku Tensei III： Isekai Ittara Honki Dasu [14][1080P][简体内嵌]',
        '[KTXP][无职转生][11][1080P][GB][MP4][简中]',
        '[LoliHouse] 无职转生 3期 - 05 [1080p HEVC][CHS][简日内嵌]',
      ]) {
        expect(seedTitleMarksSimplified(title), isTrue, reason: title);
        expect(seedTitleMarksTraditional(title), isFalse, reason: title);
      }
    });

    test('繁体：繁体内嵌 / 繁中 / BIG5 / CHT / 繁日', () {
      for (final String title in <String>[
        '[桜都字幕组] 无职转生 第三季 ～到了异世界就拿出真本事～ / '
            'Mushoku Tensei III： Isekai Ittara Honki Dasu [14][1080P][繁体内嵌]',
        '[KTXP][无职转生][11][1080P][BIG5][MP4][繁中]',
        '[绿茶字幕组] 无职转生 第三季 ～到了异世界就拿出真本事～ / '
            'Mushoku Tensei S3 [14][WebRip][1080p][繁日内嵌]',
      ]) {
        expect(seedTitleMarksTraditional(title), isTrue, reason: title);
        expect(seedTitleMarksSimplified(title), isFalse, reason: title);
      }
    });

    test('两边都标（简繁 / GB_BIG5_JP / CHS_CHT）⇒ 两种都算', () {
      for (final String title in <String>[
        '[桜都字幕组] 无职转生 第三季 ～到了异世界就拿出真本事～ / '
            'Mushoku Tensei III： Isekai Ittara Honki Dasu [14][1080P][简繁内封]',
        '[KissSub][Steins;Gate][命运石之门][12][GB_BIG5_JP][BDrip][1080P][HEVC] 静滞极限的教理',
        '[NC-Raws] 无职转生～到了异世界就拿出真本事～ / '
            'Mushoku Tensei - 11 [WEB-DL][1080p][AVC AAC][CHS_CHT_SRT][MKV]',
      ]) {
        expect(seedTitleMarksSimplified(title), isTrue, reason: title);
        expect(seedTitleMarksTraditional(title), isTrue, reason: title);
      }
    });

    test('没标的（生肉 / BDMV / 只写"双语"）⇒ 两种都不算', () {
      for (final String title in <String>[
        '[VCB-Studio] 命运石之门 0 / Steins;Gate 0 / シュタインズ・ゲート ゼロ '
            '10-bit 1080p HEVC BDRip [Reseed Fin]',
        '【双语】[4月新番][命运石之门0/Steins Gate 0][05][720P]',
        '[BDMV] Steins;Gate + Steins;Gate Movie: Fuka Ryouiki no Déjà vu '
            '[BD-BOX][JP] 命运石之门',
      ]) {
        expect(seedTitleMarksSimplified(title), isFalse, reason: title);
        expect(seedTitleMarksTraditional(title), isFalse, reason: title);
      }
    });

    test('单独一个「简」/「繁」也算（真标题里只写一个字的）', () {
      const String solo = '【F宅】命运石之门：聪明睿智的认知计算 01-04 简 BD版 1080P MP4 合集';
      expect(seedTitleMarksSimplified(solo), isTrue);
      expect(seedTitleMarksTraditional(solo), isFalse);
      expect(seedTitleMarksTraditional('某番 - 01 繁 BD版 1080P'), isTrue);
      expect(seedTitleMarksSimplified('[简][繁] 某番 - 01'), isTrue);
      expect(seedTitleMarksTraditional('[简][繁] 某番 - 01'), isTrue);
    });

    test('不是语言标记的「简 / 繁 / GB」不算（名字 / 尺寸 / 编码）', () {
      const List<String> titles = <String>[
        '繁花 - 01 [1080p]',
        '简略版 某番 - 01 [1080p]',
        '[1080GB] 某番 - 01',
        '[GBK] 某番 - 01',
        '[1080p][HEVC-10bit][AAC] 某番 - 01',
      ];
      for (final String title in titles) {
        expect(seedTitleMarksSimplified(title), isFalse, reason: title);
        expect(seedTitleMarksTraditional(title), isFalse, reason: title);
      }
    });
  });

  group('过滤与循环', () {
    test('nextSeedLanguage：全部 → 简体 → 繁体 → 全部', () {
      expect(nextSeedLanguage(SeedLanguage.all), SeedLanguage.simplified);
      expect(
        nextSeedLanguage(SeedLanguage.simplified),
        SeedLanguage.traditional,
      );
      expect(nextSeedLanguage(SeedLanguage.traditional), SeedLanguage.all);
    });

    test('seedLanguageLabel：界面按钮上写的那三个字', () {
      expect(seedLanguageLabel(SeedLanguage.all), '全部');
      expect(seedLanguageLabel(SeedLanguage.simplified), '简体');
      expect(seedLanguageLabel(SeedLanguage.traditional), '繁体');
    });

    test('filterSeedItemsByLanguage：只留标了那一种的（两边都标的两种都留，顺序不变）', () {
      final List<SourceItemView> pool = <SourceItemView>[
        _item('某番 - 01 [1080p][简体内嵌]'),
        _item('某番 - 02 [1080p][繁体内嵌]'),
        _item('某番 - 03 [1080p][简繁内封]'),
        _item('某番 - 04 [1080p]'),
      ];
      expect(        filterSeedItemsByLanguage(pool, SeedLanguage.simplified)
            .map((SourceItemView i) => i.title),
        <String>['某番 - 01 [1080p][简体内嵌]', '某番 - 03 [1080p][简繁内封]'],
      );
      expect(
        filterSeedItemsByLanguage(pool, SeedLanguage.traditional)
            .map((SourceItemView i) => i.title),
        <String>['某番 - 02 [1080p][繁体内嵌]', '某番 - 03 [1080p][简繁内封]'],
      );
      expect(filterSeedItemsByLanguage(pool, SeedLanguage.all), hasLength(4));
      // 「全部」返回的是副本：外面改它不能动到调用方那份。
      final List<SourceItemView> all = filterSeedItemsByLanguage(
        pool,
        SeedLanguage.all,
      );
      all.clear();
      expect(pool, hasLength(4));
    });
  });
}
