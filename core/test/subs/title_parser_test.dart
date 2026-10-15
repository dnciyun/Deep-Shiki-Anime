/// 标题解析单测（spec §4.4，必须单测）。
///
/// 用例混合：spec 列举的形态 + 真实 fixture 里的标题（nyaa/mikan/dmhy/acgrip）。
library;

import 'package:dsanima_core/subs/subs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('episodeHints（归一化 01 / S01E02）', () {
    test('spec §4.4 列举的全部形态', () {
      expect(TitleParser.extractEpisodeHints('Title - 01'), <String>['01']);
      expect(TitleParser.extractEpisodeHints('Title S01E02'),
          <String>['S01E02']);
      expect(TitleParser.extractEpisodeHints('某番 第3话'), <String>['03']);
      expect(TitleParser.extractEpisodeHints('某番 第 12 集'), <String>['12']);
      expect(TitleParser.extractEpisodeHints('Title - 03v2'), <String>['03']);
      expect(TitleParser.extractEpisodeHints('Title [03]'), <String>['03']);
      expect(TitleParser.extractEpisodeHints('Title EP03'), <String>['03']);
    });

    test('更多变体', () {
      expect(TitleParser.extractEpisodeHints('Title S1E2'), <String>['S01E02']);
      expect(TitleParser.extractEpisodeHints('Title Ep.07'), <String>['07']);
      expect(TitleParser.extractEpisodeHints('Title E05'), <String>['05']);
      expect(TitleParser.extractEpisodeHints('Title (09)'), <String>['09']);
      expect(TitleParser.extractEpisodeHints('Title 【11】'), <String>['11']);
      expect(TitleParser.extractEpisodeHints('Title - 第2話'), <String>['02']);
    });

    test('区间形态给出首末两个提示', () {
      expect(TitleParser.extractEpisodeHints('Title S02E08-E11'),
          <String>['S02E08', 'S02E11']);
      expect(TitleParser.extractEpisodeHints('Title S01E02~03'),
          <String>['S01E02', 'S01E03']);
    });

    test('不误判分辨率/版本号/编号', () {
      expect(TitleParser.extractEpisodeHints('U-17 世界杯 F-272'),
          isEmpty);
      expect(TitleParser.extractEpisodeHints('Nix-Raws 1080p x265 10Bit'),
          isEmpty);
      expect(TitleParser.extractEpisodeHints('[Multi-Audio] 2.0'),
          isEmpty);
      expect(
        TitleParser.extractEpisodeHints(
            '[JMAX] [2026.07.13／10.09]「ガールズバンドクライ First Riff」'
            'F-272 - Diorama／A Tragic Mirage [FLAC]'),
        isEmpty,
      );
    });

    test('真实 fixture 标题逐条验证', () {
      expect(
        TitleParser.extractEpisodeHints(
            '[ASW] FX Senshi Kurumi-chan - 02 [1080p HEVC x265 10Bit][AAC]'),
        <String>['02'],
      );
      expect(
        TitleParser.extractEpisodeHints(
            '[Nix-Raws] 新网球王子 U-17 世界杯 决赛成员选拔赛 / '
            'The Prince of Tennis II S03E01 [CR WEB-DL 1080p AVC AAC][简繁内封]'),
        <String>['S03E01'],
      );
      expect(
        TitleParser.extractEpisodeHints(
            '[黒ネズミたち] 麵包小偷 / Pan Dorobou - 01 (ABEMA 1920x1080 AVC AAC MKV)'),
        <String>['01'],
      );
      expect(
        TitleParser.extractEpisodeHints(
            '[Erai-raws] Sousou no Frieren 2nd Season - 10 '
            '[1080p CR WEB-DL AVC AAC][MultiSub][5A357DEE]'),
        <String>['10'],
      );
    });
  });

  group('resolution（720 / 1080 / 2160）', () {
    test('spec 列举的四种写法', () {
      expect(TitleParser.extractResolution('[1080p]'), 1080);
      expect(TitleParser.extractResolution('[2160p]'), 2160);
      expect(TitleParser.extractResolution('[4K HDR]'), 2160);
      expect(TitleParser.extractResolution('[720p]'), 720);
    });

    test('分辨率写法（宽x高）与大小写', () {
      expect(TitleParser.extractResolution('1920x1080 AVC'), 1080);
      expect(TitleParser.extractResolution('3840x2160 HEVC'), 2160);
      expect(TitleParser.extractResolution('1280x720'), 720);
      expect(TitleParser.extractResolution('1080P'), 1080);
      expect(TitleParser.extractResolution('4k'), 2160);
    });

    test('同时出现多个取最高档', () {
      expect(TitleParser.extractResolution('1080p 与 2160p 双版本'), 2160);
    });

    test('识别不出 → null', () {
      expect(TitleParser.extractResolution('WEB-DL AVC AAC'), isNull);
      expect(TitleParser.extractResolution('480p'), isNull);
    });
  });

  group('group（前导 [组名]）', () {
    test('常见字幕组', () {
      expect(TitleParser.extractGroup('[Nix-Raws] 标题'), 'Nix-Raws');
      expect(TitleParser.extractGroup('[ASW] FX Senshi Kurumi-chan - 02'),
          'ASW');
      expect(TitleParser.extractGroup('【字幕组】标题'), '字幕组');
      expect(TitleParser.extractGroup('[DRiFTKiNG] You and I'), 'DRiFTKiNG');
      expect(TitleParser.extractGroup('[7³ACG] 葬送的芙莉莲'), '7³ACG');
      expect(TitleParser.extractGroup('[黒ネズミたち] 麵包小偷'), '黒ネズミたち');
    });

    test('跳过纯技术标记', () {
      expect(TitleParser.extractGroup('[1080p] Title'), isNull);
      expect(TitleParser.extractGroup('[WEB-DL] Title'), isNull);
      expect(TitleParser.extractGroup('[x265] Title'), isNull);
      expect(TitleParser.extractGroup('没有方括号'), isNull);
    });

    test('技术标记后面才是组名时能跳过它', () {
      expect(TitleParser.extractGroup('[1080p][Nix-Raws] 标题'), 'Nix-Raws');
    });
  });

  group('subtitleLang / subtitleType', () {
    test('spec 词表逐项', () {
      expect(TitleParser.parse('[简] 标题').subtitleLang, '简');
      expect(TitleParser.parse('[繁] 标题').subtitleLang, '繁');
      expect(TitleParser.parse('[简繁] 标题').subtitleLang, '简繁');
      expect(TitleParser.parse('[CHS] 标题').subtitleLang, 'CHS');
      expect(TitleParser.parse('[CHT] 标题').subtitleLang, 'CHT');
      expect(TitleParser.parse('[GB] 标题').subtitleLang, 'GB');
      expect(TitleParser.parse('[BIG5] 标题').subtitleLang, 'BIG5');
      expect(TitleParser.parse('[简繁内封] 标题').subtitleLang, '简繁');
      expect(TitleParser.parse('[简繁内封] 标题').subtitleType, '内封');
      expect(TitleParser.parse('[内嵌字幕] 标题').subtitleType, '内嵌');
      expect(TitleParser.parse('外挂简中字幕').subtitleType, '外挂');
    });

    test('语言与封装方式分别落在两个字段，原文命中全部保留', () {
      final parsed = TitleParser.parse(
          '[Nix-Raws] 标题 [CR WEB-DL 1080p][简繁内封]');
      expect(parsed.subtitleLang, '简繁');
      expect(parsed.subtitleType, '内封');
      expect(parsed.subtitleLangMatches, containsAll(<String>['简繁', '简', '繁']));
    });

    test('简繁同时出现（非连写）也算简繁', () {
      expect(TitleParser.parse('简体&繁体').subtitleLang, '简繁');
      expect(TitleParser.parse('[CHS&CHT&EN] 标题').subtitleLang, '简繁');
    });

    test('识别不出 → null（不猜）', () {
      final parsed = TitleParser.parse(
          '[Erai-raws] Sousou no Frieren - 10 [1080p CR WEB-DL AVC AAC][MultiSub]');
      expect(parsed.subtitleLang, isNull);
      expect(parsed.subtitleType, isNull);
    });
  });

  group('isBatch', () {
    test('spec 列举的形态', () {
      expect(TitleParser.detectBatch('某番 合集'), isTrue);
      expect(TitleParser.detectBatch('某番 全集'), isTrue);
      expect(TitleParser.detectBatch('Title Batch'), isTrue);
      expect(TitleParser.detectBatch('[01-12] 标题'), isTrue);
      expect(TitleParser.detectBatch('[Vol.1] 标题'), isTrue);
    });

    test('季集区间也算多集打包', () {
      expect(TitleParser.detectBatch('Title S02E08-E11'), isTrue);
      expect(TitleParser.detectBatch('Title 01~12'), isTrue);
    });

    test('单集/编号/日期不误判', () {
      expect(TitleParser.detectBatch('Title - 01'), isFalse);
      expect(TitleParser.detectBatch('U-17 世界杯 F-272'), isFalse);
      expect(TitleParser.detectBatch('[2026.07.13／10.09] 标题'), isFalse);
      expect(TitleParser.detectBatch('1080p x265 10Bit'), isFalse);
    });
  });

  group('TitleParser.parse 综合 + toExtra', () {
    test('真实 nyaa 标题：组/集/分辨率/合集一次给全', () {
      final parsed = TitleParser.parse(
        '[DRiFTKiNG] You and I Are Polar Opposites - S02E08-E11 '
        '(CR WEB-DL 1080p H.264 AAC 2.0) [Multi-Audio] | Seihantai na Kimi to Boku',
        sourceId: 'nyaa',
      );
      expect(parsed.group, 'DRiFTKiNG');
      expect(parsed.episodeHints, <String>['S02E08', 'S02E11']);
      expect(parsed.resolution, 1080);
      expect(parsed.isBatch, isTrue);
      expect(parsed.hasEpisode, isTrue);
      final extra = parsed.toExtra();
      expect(extra['episodeHints'], <String>['S02E08', 'S02E11']);
      expect(extra['resolution'], 1080);
      expect(extra['group'], 'DRiFTKiNG');
      expect(extra['isBatch'], isTrue);
    });

    test('真实 mikan 标题：[简繁内封] + S03E01', () {
      final parsed = TitleParser.parse(
          '[Nix-Raws] 新网球王子 U-17 世界杯 决赛成员选拔赛 / '
          'The Prince of Tennis II S03E01 [CR WEB-DL 1080p AVC AAC][简繁内封]');
      expect(parsed.group, 'Nix-Raws');
      expect(parsed.episodeHints, <String>['S03E01']);
      expect(parsed.resolution, 1080);
      expect(parsed.subtitleLang, '简繁');
      expect(parsed.subtitleType, '内封');
      expect(parsed.isBatch, isFalse);
    });

    test('空标题 / 空白标题 → 全空结果，不抛错', () {
      for (final title in <String>['', '   ']) {
        final parsed = TitleParser.parse(title);
        expect(parsed.episodeHints, isEmpty);
        expect(parsed.resolution, isNull);
        expect(parsed.group, isNull);
        expect(parsed.subtitleLang, isNull);
        expect(parsed.isBatch, isFalse);
        expect(parsed.toExtra()['isBatch'], isFalse);
      }
    });

    test('sourceId 参数不影响通用结果（保留给源特有规则）', () {
      final a = TitleParser.parse('[组] 某番 - 01 [1080p]');
      final b = TitleParser.parse('[组] 某番 - 01 [1080p]', sourceId: 'nyaa');
      expect(a.episodeHints, b.episodeHints);
      expect(a.resolution, b.resolution);
      expect(a.group, b.group);
    });
  });
}
