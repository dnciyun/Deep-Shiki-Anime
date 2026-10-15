/// 番名清洗单测（2026-10-12 第十四轮）。
///
/// 样本全是**用户真实遇到过的命名**（他给的原话例子 + 真机引擎里那几条 torrent 名），
/// 不是编的；每条断言都要能回答"为什么这条命名要清洗成这样"。
library;

import 'package:dsanima/domain/title_clean.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('用户原话：VCB 那种「一等集一个种子、标题就是文件名」', () {
    // 用户原话里的名字（原文照抄）。
    const String vcb = '[hyakuhuyu&VCB-Studio] Re Zero kara Hajimeru Isekai Seikatsu '
        '3rd Season [51][Ma10p_1080p][x265_flac_aac].CHS.mp4';
    // 用户原话里的期望结果（原文照抄）。
    const String want = 'Re Zero kara Hajimeru Isekai Seikatsu 3rd Season';

    test('清洗后正好是用户要的那句（括号、扩展名、.CHS 全没了）', () {
      expect(cleanAnimeNameFromFileName(vcb), want);
    });

    test('animeSearchName 与它一致（这条命名里集号本来就在括号里）', () {
      expect(animeSearchName(vcb), want);
    });

    test('同一部番的 51 / 52 集归到同一个键', () {
      const String ep52 =
          '[hyakuhuyu&VCB-Studio] Re Zero kara Hajimeru Isekai Seikatsu 3rd Season '
          '[52][Ma10p_1080p][x265_flac_aac].CHS.mp4';
      expect(animeGroupKey(vcb), animeGroupKey(ep52));
      expect(animeGroupKey(vcb), isNotEmpty);
    });
  });

  group('真机引擎里那几条 torrent 名（第十四轮做「已完成」页时的真实数据）', () {
    test('NEST：集号没被括号包住（`- 03`）也要切掉，否则 bangumi 搜不到', () {
      const String nest = '[NEST] 飙马野郎 JOJO的奇妙冒险 / スティール・ボール・ラン '
          'ジョジョの奇妙な冒険 - 03 [NF WEB-DL 1080p AVC AAC][JPSC].mkv';
      // 清洗（不切集号）时 `- 03` 还在：这是"去括号"这一步的忠实结果。
      expect(cleanAnimeNameFromFileName(nest),
          '飙马野郎 JOJO的奇妙冒险 / スティール・ボール・ラン ジョジョの奇妙な冒険 - 03');
      // 「只搜名字」要连 `- 03` 一起切掉。
      expect(animeSearchName(nest),
          '飙马野郎 JOJO的奇妙冒险 / スティール・ボール・ラン ジョジョの奇妙な冒険');
      // 03 与 04 同一张卡。
      const String next = '[NEST] 飙马野郎 JOJO的奇妙冒险 / スティール・ボール・ラン '
          'ジョジョの奇妙な冒険 - 04 [NF WEB-DL 1080p AVC AAC][JPSC].mkv';
      expect(animeGroupKey(nest), animeGroupKey(next));
    });

    test('Anti-DEI：`- 02` 后面还挂着一串方括号', () {
      expect(
        animeSearchName('[Anti-DEI] Yukionna - 02 [WebRip 1080P HEVC-10bit AAC]'
            '[CHS&JPN][Uncensored].mp4'),
        'Yukionna',
      );
    });

    test('中文番名：`【10月】` 与 `【完全无修版】` 是两种括号，都要去掉', () {
      expect(
        animeSearchName('【10月】与暗黑召唤师秘密恋爱中 02【完全无修版】.mp4'),
        '与暗黑召唤师秘密恋爱中',
      );
    });
  });

  // ── 第十七轮：番名**自己也在方括号里**的中文命名 ──
  //
  // 用户真机原话：「然后默认搜索的【今晚月色真美】[女友的朋友 / 彼女の友达 /
  // Kanojo no Tomodachi][02][WebRip][1080P][AVC-8bit][AAC][简日内嵌][无修正]，
  // 什么都搜不到」。
  //
  // 老规则把成对括号**一律删掉** → 一个字都不剩 → `animeSearchName` 返回 null →
  // 「已完成」页的卡片拿**整条原始文件名**当 bangumi 关键字（`completed.dart` 的
  // `raw:<原名>` 兜底），自然什么都搜不到。`【】` 是字幕组，`[]` 里才是番名。
  group('番名自己也在方括号里（第十七轮真机命名）', () {
    // 用户给的那条，一字不改。
    const String real = '【今晚月色真美】[女友的朋友 / 彼女の友达 / Kanojo no Tomodachi]'
        '[02][WebRip][1080P][AVC-8bit][AAC][简日内嵌][无修正]';

    test('清洗结果 = 方括号里那段番名（不是整条原名，也不是字幕组名）', () {
      expect(
        cleanAnimeNameFromFileName('$real.mkv'),
        '女友的朋友 / 彼女の友达 / Kanojo no Tomodachi',
      );
      expect(
        animeSearchName('$real.mkv'),
        '女友的朋友 / 彼女の友达 / Kanojo no Tomodachi',
        reason: '集号（[02]）本来就在括号里，不用再切',
      );
      // 实测：拿这句去 bangumi 搜，第一条就是 `彼女の友達 / 女友的朋友`（id 647220）。
    });

    test('同一部番的 02 / 03 集归到同一张卡', () {
      const String ep3 = '【今晚月色真美】[女友的朋友 / 彼女の友达 / Kanojo no Tomodachi]'
          '[03][WebRip][1080P][AVC-8bit][AAC][简日内嵌][无修正].mkv';
      expect(animeGroupKey('$real.mkv'), animeGroupKey(ep3));
      expect(animeGroupKey('$real.mkv'), isNotEmpty);
      expect(animeGroupKey('$real.mkv'), isNot(animeGroupKey('【今晚月色真美】[别的番][02].mkv')),
          reason: '不同番不能被并成一张卡');
    });

    test('兜底只在"一个字都没剩"时走：正常命名结果不变', () {
      // 番名在括号外 ⇒ 还是外面那段（不因为括号里有更长的东西而改主意）。
      expect(
        cleanAnimeNameFromFileName('【字幕组】葬送的芙莉莲 [02][1080p][AVC-8bit AAC].mkv'),
        '葬送的芙莉莲',
      );
      // 拉丁名整段在括号里、且是多词的：也认（`Re Zero … 3rd Season`）。
      expect(
        animeSearchName('[SubsPlease][Re Zero kara Hajimeru Isekai Seikatsu 3rd Season]'
            '[51][Ma10p_1080p][x265_flac_aac].mkv'),
        'Re Zero kara Hajimeru Isekai Seikatsu 3rd Season',
      );
    });

    test('括号里全是组名/技术标记 → 还是 null（不许挑一个组名去搜）', () {
      expect(cleanAnimeNameFromFileName('[VCB-Studio][x265][1080p].mp4'), isNull,
          reason: '`VCB-Studio` 是组名、`x265`/`1080p` 是技术标记');
      expect(cleanAnimeNameFromFileName('[Skymoon-Raws][WebRip 1080P HEVC-10bit AAC].mkv'),
          isNull,
          reason: '整段都是技术标记 + 单段拉丁组名');
      expect(cleanAnimeNameFromFileName('[字幕组][无修正][1080p][02].mkv'), isNull,
          reason: '只剩「字幕组/无修正」这类词时宁可搜不出来，也不拿它去搜');
      expect(cleanAnimeNameFromFileName('[Group] 01 [1080p].mp4'), isNull);
    });
  });

  group('清洗的边界（宁可少切，不可切错）', () {
    test('`Re Zero 2.0` 不是扩展名 → 清洗原样留着（白名单而不是"最后一个点"）', () {
      expect(cleanAnimeNameFromFileName('Re Zero 2.0'), 'Re Zero 2.0');
    });

    test('裸的**单个**数字是季不是集：`K-ON! 2` 不能被切掉（否则搜到第一季）', () {
      expect(animeSearchName('K-ON! 2'), 'K-ON! 2');
      expect(animeSearchName('Re:Zero kara Hajimeru Isekai Seikatsu 3'),
          'Re:Zero kara Hajimeru Isekai Seikatsu 3');
      // 两位数字才是集号。
      expect(animeSearchName('K-ON! 02'), 'K-ON!');
    });

    test('没有扩展名的名字原样（只是折叠空白）', () {
      expect(cleanAnimeNameFromFileName('  葬送的芙莉莲  '), '葬送的芙莉莲');
    });

    test('多层括号（嵌套）也能去干净', () {
      // 括号里的内容按规则一律去掉（`((1952))` 里的 `1952` 也留不下），
      // 这里验的是"嵌套也能全去掉、不留半截括号"。
      expect(cleanAnimeNameFromFileName('[Group] Show ((1952)) [1080p].mkv'), 'Show');
      expect(cleanAnimeNameFromFileName('[Group [sub]] Show [1080p].mkv'), 'Show');
    });

    test('尾部语言标记连来两个：`.CHS.CHT`', () {
      expect(cleanAnimeNameFromFileName('Show [1080p].CHS.CHT.ass'), 'Show');
    });

    test('带目录的完整路径只留文件名（Windows 反斜杠）', () {
      expect(
        animeSearchName(r'C:\Users\someone\Downloads\Anime\[Group] Show - 01 [1080p].mkv'),
        'Show',
      );
    });

    test('名字中间带斜杠（`JOJO / スティール`）不能被当成路径砍掉', () {
      // `NEST` 那条就是这种形状：斜杠两边有空格 ⇒ 不是路径。
      expect(
        animeSearchName('[NEST] JoJo / Steel Ball Run - 03 [1080p].mkv'),
        'JoJo / Steel Ball Run',
      );
    });

    test('只有括号/只有数字 → null（不拿垃圾去搜）', () {
      expect(cleanAnimeNameFromFileName('[VCB-Studio][x265][1080p].mp4'), isNull);
      expect(animeSearchName('[Group] 01 [1080p].mp4'), isNull,
          reason: '只剩 `01`：不是番名');
      expect(animeSearchName('SP'), isNull);
    });

    test('null / 空串 / 纯空白 → null', () {
      expect(cleanAnimeNameFromFileName(null), isNull);
      expect(cleanAnimeNameFromFileName('   '), isNull);
      expect(animeSearchName(null), isNull);
      expect(animeGroupKey(null), isEmpty);
    });

    test('两字番名是**真名字**，不能被长度判据挡掉（`冰菓`）', () {
      expect(animeSearchName('[Group] 冰菓 - 05 [1080p].mkv'), '冰菓');
    });

    test('字幕文件（`.ass`）也走同一条路', () {
      expect(cleanAnimeNameFromFileName('[Group] Show - 05 [CHS].ass'), 'Show - 05');
      expect(animeSearchName('[Group] Show - 05 [CHS].ass'), 'Show');
    });
  });
}
