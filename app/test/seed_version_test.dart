/// 种子块的「版本判定」：真实标题的判定表（第四十八轮·补六）。
///
/// 表里的标题**全部是真抓的**（mikan 搜索页，2026-10-16 本机，原始记录在
/// `build/round48c/uw_mikan_versions.txt` 与 `uw_versions.txt`）——
/// 这一层最容易"看着像对、换个写法就错"，所以把真标题钉成用例：
/// 以后再遇到怪名字，往这张表里加一行就行，不用靠谁记住特例。
library;

import 'package:dsanima/domain/seed_version.dart';
import 'package:dsanima/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';
// ─────────────────────────────────────────────────────────────────────────────
// 真数据：无职转生（Bangumi 实测 6 个动画条目）
// ─────────────────────────────────────────────────────────────────────────────

/// S1 = 277554，TV，2021-01-10，11 话。
final SeedSubjectSignature _s1 = seedSignatureOf(
  platform: 'TV',
  names: <String>[
    '无职转生～到了异世界就拿出真本事～',
    '無職転生 ～異世界行ったら本気だす～',
  ],
  date: '2021-01-10',
  eps: 11,
);

/// S1 后半 = 325585，TV，2021-10-03，12 话（名字里只有「第2クール」、**没有** Ⅱ）。
final SeedSubjectSignature _s1Part2 = seedSignatureOf(
  platform: 'TV',
  names: <String>[
    '无职转生～到了异世界就拿出真本事～ 第2部分',
    '無職転生 ～異世界行ったら本気だす～ 第2クール',
  ],
  date: '2021-10-03',
  eps: 12,
);

/// S2 = 373247，TV，2023-07-02，13 话。
final SeedSubjectSignature _s2 = seedSignatureOf(
  platform: 'TV',
  names: <String>[
    '无职转生 第二季 ～到了异世界就拿出真本事～',
    '無職転生Ⅱ ～異世界行ったら本気だす～',
  ],
  date: '2023-07-02',
  eps: 13,
);

/// S2 后半 = 444557，TV，2024-04-07，12 话 —— 用户举的那一条。
final SeedSubjectSignature _s2Part2 = seedSignatureOf(
  platform: 'TV',
  names: <String>[
    '无职转生 第二季 ～到了异世界就拿出真本事～ 第2部分',
    '無職転生Ⅱ ～異世界行ったら本気だす～ 第2クール',
  ],
  date: '2024-04-07',
  eps: 12,
);

/// 命运石之门 = 10380，TV，2011-04-06，25 话。
///
/// 补八用户原话：「为什么会有第五季，命运石之门没有第五季」—— 这一页的真标题（mikan 841 条，
/// 原始记录在 `build/round48c/sg_titles.txt`）里有 6 条带 `[V2]`（发布者的修正版标签），
/// 旧规则把 V 当罗马数字 ⇒ 一整页「第五季」。
final SeedSubjectSignature _steinsGate = seedSignatureOf(
  platform: 'TV',
  names: <String>['命运石之门', 'STEINS;GATE'],
  date: '2011-04-06',
  eps: 25,
);

/// 带 `[V2]` 的那 6 条真标题（mikan 搜索「命运石之门」，2011 年那批）。
const List<String> _v2Titles = <String>[
  '【命运石之门Steins;Gate】【23】【TSDM字幕组】【GB简体】【480P】【PC&PSP兼容MP4】【V2】【修正ED】',
  '【命运石之门Steins;Gate】【23】【TSDM字幕组】【BIG5繁体】【480P】【PC&PSP兼容MP4】【V2】【修正ED】',
  '【命运石之门Steins;Gate】【09】【TSDM字幕组】【MKV720P】（简体字幕出问题，附上V2版网盘下载）',
  '[KTKJ][Steins;Gate_命运石之门][06][BIG5][576RMVB&720MKV&Tips][V2]',
  '【动漫花园】[4月新番][Steins；Gate][命运石之门][05][V2][TV正式版][848X480][CHT][RMVB]',
  '[KTKJ][Steins;Gate_命运石之门][02V2][BIG5][576RMVB&720MKV&Tips]',
];

/// 判定成一句话（本作 / 别的版本标签），断言读起来像表格。
String _judge(
  SeedSubjectSignature subject,
  String title, {
  DateTime? publishedAt,
}) => judgeSeedVersion(
  title: title,
  publishedAt: publishedAt ?? DateTime.utc(2024, 5, 1),
  subject: subject,
).label ?? '本作';

SourceItemView _item(String title, DateTime at) => SourceItemView(
  id: 'mikan:$title',
  sourceId: 'mikan',
  title: title,
  magnet: 'magnet:?xt=urn:btih:${title.hashCode.toRadixString(16)}',
  publishedAt: at,
);

void main() {
  group('signature：本条目的版本签名', () {
    test('S1：名字里没有季号，TV ⇒ 季 1', () {
      final SeedVersion v = _s1.version;
      expect(v.form, SeedForm.tv);
      expect(v.season, 1);
      expect(v.part, isNull);
    });

    test('S1 后半：只有「第2部分 / 第2クール」 ⇒ 部 2，季仍按 TV 算 1（不能当第二季）', () {
      final SeedVersion v = _s1Part2.version;
      expect(v.season, 1, reason: '「第2クール」是"部"不是"季"');
      expect(v.part, 2);
    });

    test('S2：「第二季」与日文名里的 Ⅱ 都解成季 2', () {
      final SeedVersion v = _s2.version;
      expect(v.season, 2);
      expect(v.part, isNull);
    });

    test('S2 后半：季 2 + 部 2', () {
      final SeedVersion v = _s2Part2.version;
      expect(v.season, 2);
      expect(v.part, 2);
    });

    test('剧场版条目：形态 = 剧场版，没有季号', () {
      final SeedSubjectSignature movie = seedSignatureOf(
        platform: '剧场版',
        names: <String>['葬送的芙莉莲 剧场版', '葬送のフリーレン 劇場版'],
      );
      expect(movie.version.form, SeedForm.movie);
      expect(movie.version.season, isNull);
    });

    test('platform 拿不到时：名字里也没有标记 ⇒ 全空（这一档不该乱判）', () {
      final SeedSubjectSignature empty = seedSignatureOf(
        names: <String>['葬送的芙莉莲'],
      );
      expect(empty.version.isEmpty, isTrue);
    });

    test('放送开始能解析（`YYYY-MM-DD`）', () {
      expect(_s2Part2.date, DateTime(2024, 4, 7));
      expect(_s2Part2.eps, 12);
    });
  });

  group('parse：标题里的版本标记（真标题）', () {
    test('「第二季」「Ⅱ」「S2」「Part 2」都能解，且互不矛盾', () {
      expect(parseSeedVersion('无职转生 第二季 ～到了异世界就拿出真本事～').season, 2);
      expect(parseSeedVersion('無職転生Ⅱ ～異世界行ったら本気だす～').season, 2);
      expect(parseSeedVersion('Mushoku Tensei S2 [01]').season, 2);
      expect(parseSeedVersion('Mushoku Tensei 2nd Season - 01').season, 2);
      expect(
        parseSeedVersion('Mushoku Tensei II: Isekai Ittara Honki Dasu Part 2 - 24')
            .part,
        2,
      );
    });

    test('「3期」「第3季」「第三季」「Ⅲ」「S03E14」都是季 3', () {
      for (final String title in <String>[
        '无职转生 3期 / Mushoku Tensei S3',
        '无职转生 第3季 / Mushoku Tensei 3rd Season',
        '无职转生 第三季 ～到了异世界就拿出真本事～',
        '無職転生Ⅲ ～異世界行ったら本気だす～',
        'Mushoku Tensei Isekai Ittara Honki Dasu S03E14',
      ]) {
        expect(parseSeedVersion(title).season, 3, reason: title);
      }
    });

    test('一条里中/日/英三种写法都有 ⇒ 还是同一个季（不判"多季合集"）', () {
      const String title =
          '【TSDM字幕组】[无职转生 第三季 ～到了异世界就拿出真本事～]'
          '[无职転生Ⅲ ～异世界行ったら本気だす～]'
          '[Mushoku Tensei III: Isekai Ittara Honki Dasu]';
      final SeedVersion v = parseSeedVersion(title);
      expect(v.season, 3);
      expect(v.seasonConflict, isFalse);
    });

    test('「第2部分」「第2クール」「后半」是"部"，不是"季"', () {
      final SeedVersion v = parseSeedVersion(
        '无职转生 第二季 ～到了异世界就拿出真本事～ 第2部分',
      );
      expect(v.season, 2);
      expect(v.part, 2);
    });

    test('形态：剧场版 / OVA / 番外', () {
      expect(parseSeedVersion('剧场版 葬送的芙莉莲').form, SeedForm.movie);
      expect(parseSeedVersion('葬送のフリーレン 劇場版').form, SeedForm.movie);
      expect(parseSeedVersion('[XX字幕组] 葬送的芙莉莲 OVA').form, SeedForm.ova);
      expect(parseSeedVersion('葬送的芙莉莲 番外篇').form, SeedForm.sp);
      expect(parseSeedVersion('葬送的芙莉莲 特别篇').form, SeedForm.sp);
    });

    test('「特典映像」不算形态（批量合集里常带这个词，别把它判成番外）', () {
      const String batch =
          '[Rev][DBD-Raws][无职转生～到了异世界就拿出真本事～ 第二季/'
          'Mushoku Tensei II: Isekai Ittara Honki Dasu][00-24TV全集+特典映像]'
          '[1080P][BDRip][HEVC-10bit][FLAC][MKV]';
      final SeedVersion v = parseSeedVersion(batch);
      expect(v.form, SeedForm.unknown);
      expect(v.season, 2);
    });

    test('互相矛盾的季号 ⇒ 多季合集', () {
      final SeedVersion v = parseSeedVersion('无职转生 第一季+第二季 合集');
      expect(v.seasonConflict, isTrue);
    });

    test('最终季 / Final Season', () {
      expect(parseSeedVersion('进击的巨人 最终季').finalSeason, isTrue);
      expect(parseSeedVersion('進撃の巨人 The Final Season').finalSeason, isTrue);
    });

    test('空标题不炸、也没有标记', () {
      expect(parseSeedVersion('').isEmpty, isTrue);
      expect(parseSeedVersion('  ').isEmpty, isTrue);
    });
  });

  // 补八：用户「为什么会有第五季，命运石之门没有第五季」。
  group('罗马数字 vs 发布标签（`[V2]` 不是第五季）', () {
    test('真标题：`[V2]` / `02V2` / `V2版` 都不解出季号', () {
      for (final String title in _v2Titles) {
        expect(parseSeedVersion(title).season, isNull, reason: title);
      }
    });

    test('这 6 条在命运石之门页上算本作（不再落进「第五季」）', () {
      for (final String title in _v2Titles) {
        expect(
          _judge(_steinsGate, title, publishedAt: DateTime.utc(2011, 6, 1)),
          '本作',
          reason: title,
        );
      }
    });

    test('真罗马数字照旧：`Mushoku Tensei II` = 季 2，全角 Ⅱ / Ⅲ 也认', () {
      expect(
        parseSeedVersion('Mushoku Tensei II: Isekai Ittara Honki Dasu - 01')
            .season,
        2,
      );
      expect(parseSeedVersion('無職転生Ⅱ ～異世界行ったら本気だす～ - 01').season, 2);
      expect(parseSeedVersion('無職転生Ⅲ ～異世界行ったら本気だす～ - 01').season, 3);
    });
  });

  group('judge：无职转生 第二季·后半 的页面（用户举的那条）', () {
    test('本作：真标题里的 S2 行（第二季 / Ⅱ / Part 2 / 合集）都算本作', () {
      expect(
        _judge(_s2Part2, '[ANi] 无职转生～到了异世界就拿出真本事 第二季 - 24 [1080P]'),
        '本作',
      );
      expect(
        _judge(
          _s2Part2,
          '[Up to 21°C] 无职转生～到了异世界就拿出真本事 第二季 / '
          'Mushoku Tensei II: Isekai Ittara Honki Dasu Part 2 - 24',
        ),
        '本作',
      );
      expect(
        _judge(_s2Part2, '[沸羊羊制作] 无职转生第二季 / Mushoku Tensei II - 23'),
        '本作',
      );
      // 同版本的批量合集也是本作（合集 / 全集不改变版本）。
      expect(
        _judge(
          _s2Part2,
          '[Rev][DBD-Raws][无职转生～到了异世界就拿出真本事～ 第二季/'
          'Mushoku Tensei II: Isekai Ittara Honki Dasu][00-24TV全集+特典映像]'
          '[1080P][BDRip][HEVC-10bit][FLAC][MKV]',
        ),
        '本作',
      );
    });

    test('别的版本：真标题里的 S3 行（第三季 / 3期 / Ⅲ / S03E14）都归「第三季」', () {
      for (final String title in <String>[
        '[绿茶字幕组] 无职转生 第三季 ～到了异世界就拿出真本事～ / Mushoku Tensei S3 [14]',
        '[LoliHouse] 无职转生 3期 / Mushoku Tensei S3 - 14 [WebRip 1080p HEVC-10bit AAC]',
        '[Skymoon-Raws] 无职转生，到了异世界就拿出真本事 第3季 / Mushoku Tensei 3rd Season - 14',
        '[Nix-Raws] 無職転生Ⅲ ～異世界行ったら本気だす～ / Mushoku Tensei Isekai Ittara Honki Dasu S03E14',
        '【TSDM字幕组】[无职转生 第三季 ～到了异世界就拿出真本事～][07][MP4][WebRip]'
            '[简日双语内嵌][无职転生Ⅲ ～异世界行ったら本気だす～]'
            '[Mushoku Tensei III: Isekai Ittara Honki Dasu]',
        '[LoliHouse] 无职转生 3期 / Mushoku Tensei S3 [01-14 合集]',
      ]) {
        expect(_judge(_s2Part2, title), '第三季', reason: title);
      }
    });

    test('没标季号的老行：靠时间窗判成「更早的版本」', () {
      expect(
        _judge(
          _s2Part2,
          '無職転生 ～異世界行ったら本気だす～ - 05 (ABEMA 1920x1080 AVC AAC MKV)',
          publishedAt: DateTime.utc(2021, 2, 8),
        ),
        '更早的版本',
      );
    });

    test('没标季号、时间就在本季窗口里 ⇒ 本作（比如本季的 BD 合集）', () {
      expect(
        _judge(
          _s2Part2,
          '無職転生 ～異世界行ったら本気だす～ - 05 (ABEMA 1920x1080 AVC AAC MKV)',
          publishedAt: DateTime.utc(2024, 6, 1),
        ),
        '本作',
      );
    });
  });

  group('judge：其它版本形态', () {
    test('S1 的页面上：S2 / S3 的行是别的版本，S1 自己的行是本作', () {
      expect(
        _judge(_s1, '[ANi] 无职转生～到了异世界就拿出真本事 第二季 - 24', publishedAt: DateTime.utc(2024, 1, 1)),
        '第二季',
      );
      expect(
        _judge(_s1, '[绿茶字幕组] 无职转生 第三季 ～到了异世界就拿出真本事～ / Mushoku Tensei S3 [14]', publishedAt: DateTime.utc(2026, 7, 20)),
        '第三季',
      );
      expect(
        _judge(_s1, '無職転生 ～異世界行ったら本気だす～ - 05', publishedAt: DateTime.utc(2021, 2, 8)),
        '本作',
      );
      // S1 后半的行没有季号、但离 S1 很近 ⇒ 本作（同一季的连续放送）。
      expect(
        _judge(_s1, '無職転生 ～異世界行ったら本気だす～ - 15', publishedAt: DateTime.utc(2021, 11, 1)),
        '本作',
      );
    });

    test('TV 页面上：剧场版 / OVA / 番外 都进别的版本', () {
      expect(_judge(_s1, '剧场版 无职转生 ～到了异世界就拿出真本事～'), '剧场版');
      expect(_judge(_s1, '[XX字幕组] 无职转生 OVA'), 'OVA');
      expect(_judge(_s1, '无职转生 番外篇'), '番外 / 特别篇');
      expect(_judge(_s1, '葬送的芙莉莲 总集篇'), '番外 / 特别篇');
    });

    test('剧场版页面上：带季号的 TV 行是「TV 版」，剧场版自己是本作', () {
      final SeedSubjectSignature movie = seedSignatureOf(
        platform: '剧场版',
        names: <String>['葬送的芙莉莲 剧场版'],
        date: '2024-09-20',
      );
      expect(_judge(movie, '剧场版 葬送的芙莉莲'), '本作');
      expect(
        _judge(movie, '葬送的芙莉莲 第二季 - 01', publishedAt: DateTime.utc(2024, 1, 10)),
        'TV 版',
      );
    });

    test('最终季：本作不是最终季时，别人的「最终季」进别的版本；反之亦然', () {
      expect(_judge(_s2Part2, '无职转生 最终季 - 01'), '最终季');
      final SeedSubjectSignature finalSeason = seedSignatureOf(
        platform: 'TV',
        names: <String>['葬送的芙莉莲 最终季'],
        date: '2026-01-10',
      );
      expect(_judge(finalSeason, '葬送的芙莉莲 最终季 - 01'), '本作');
      expect(
        _judge(finalSeason, '葬送的芙莉莲 第三季 - 01', publishedAt: DateTime.utc(2026, 2, 1)),
        '第三季',
      );
    });

    test('窗口外判不出来的一律算本作（判错方向宁可多给）', () {
      expect(_judge(_s2Part2, ''), '本作');
      expect(_judge(_s2Part2, '无职转生 第二季 ～到了异世界就拿出真本事～'), '本作');
    });
  });

  group('isSeedBatch：合集（整季一次发）', () {
    test('真标题：合集 / 全集 / 集号区间 / 无集号的整季 BDRip 都算', () {
      for (final String title in <String>[
        '[LoliHouse] 无职转生 3期 / Mushoku Tensei S3 [01-14 合集][WebRip 1080p]',
        '[Rev][DBD-Raws][无职转生～到了异世界就拿出真本事～ 第二季/Mushoku Tensei II]'
            '[00-24TV全集+特典映像][1080P][BDRip]',
        '[VCB-Studio] 无职转生 2期 ～到了异世界就拿出真本事～ [01-12][BDRip][1080p]',
        '无职转生 第二季 [1~12][简繁内封]',
        // 整季 BDRip：没有集号（单集的 BDRip 一定带集号）。
        '[VCB-Studio] 无职转生 2期～到了异世界就拿出真本事～ / '
            'Mushoku Tensei S2 ~Isekai Ittara Honki Dasu~ 10-bit 1080p AVC BDRip [S2 Fin]',
        '[H-Enc] 无职转生Ⅱ ～到了异世界就拿出真本事～ / '
            'Mushoku Tensei II Isekai Ittara Honki Dasu (BDRip 1080p HEVC FLAC)',
      ]) {
        expect(isSeedBatch(title), isTrue, reason: title);
      }
    });

    test('单集 / 技术标签不算（`[1080p]`、`[HEVC-10bit]`、带集号的 BDRip 不能误伤）', () {
      for (final String title in <String>[
        '无职转生 第二季 ～到了异世界就拿出真本事～ - 01 [1080p][HEVC-10bit]',
        '[ANi] 無職転生Ⅱ ～異世界行ったら本気だす～ - 13 [1080P][Baha][WEB-DL][AAC AVC][CHT][MP4]',
        '无职转生 第二季 第2部分 - 05 [Ma10p_1080p]',
        // 单集的 BDRip 带集号 ⇒ 不是合集。
        '[VCB-Studio] 无职转生 2期 - 05 [BDRip 1080p HEVC]',
        '[VCB-Studio] 无职转生 2期 [05][BDRip 1080p HEVC]',
        '无职转生 第二季 第5话 [BDRip][1080P]',
        '',
      ]) {
        expect(isSeedBatch(title), isFalse, reason: title);
      }
    });
  });

  group('split：整池分开', () {
    test('本作进 current、本作里的合集切进 batch、别的版本按标签分桶', () {
      final List<SourceItemView> pool = <SourceItemView>[
        _item('无职转生 第二季 ～到了异世界就拿出真本事～ - 01', DateTime.utc(2024, 4, 10)),
        _item('无职转生 第二季 ～到了异世界就拿出真本事～ - 02', DateTime.utc(2024, 4, 17)),
        _item(
          '无职转生 第二季 ～到了异世界就拿出真本事～ [01-12 合集][1080p]',
          DateTime.utc(2024, 6, 20),
        ),
        _item('無職転生Ⅲ ～異世界行ったら本気だす～ - 01', DateTime.utc(2026, 7, 10)),
        _item('無職転生 ～異世界行ったら本気だす～ - 05', DateTime.utc(2021, 2, 8)),
      ];
      final SeedVersionSplit split = splitSeedVersions(pool, _s2Part2);
      expect(split.current.map((SourceItemView i) => i.title), <String>[
        '无职转生 第二季 ～到了异世界就拿出真本事～ - 01',
        '无职转生 第二季 ～到了异世界就拿出真本事～ - 02',
      ]);
      expect(split.batch.map((SourceItemView i) => i.title), <String>[
        '无职转生 第二季 ～到了异世界就拿出真本事～ [01-12 合集][1080p]',
      ]);
      expect(split.others.map((SeedOtherBlock b) => b.label), <String>[
        '更早的版本',
        '第三季',
      ]);
      expect(split.otherCount, 2);
      // 时间窗那两桶不带年份（同一季会跨年头），年份放在 hint 里。
      expect(split.others.first.hint, '2021');
      expect(split.others.last.hint, isNull, reason: '第三季是标题里解出来的，不需要年份说明');
      // 桶里也按字幕组分好段（界面直接用）。
      expect(split.others.every((SeedOtherBlock b) => b.groups.isNotEmpty), isTrue);
    });

    test('兜底：本作只剩合集时不分（合集并回本作，不许出现空的第一页）', () {
      final List<SourceItemView> pool = <SourceItemView>[
        _item('无职转生 第二季 ～到了异世界就拿出真本事～ [01-12 合集]', DateTime.utc(2024, 6, 20)),
        _item('无职转生 第二季 ～到了异世界就拿出真本事～ [13-24 合集]', DateTime.utc(2024, 9, 20)),
      ];
      final SeedVersionSplit split = splitSeedVersions(pool, _s2Part2);
      expect(split.batch, isEmpty);
      expect(split.current, hasLength(2));
    });

    test('时间窗的年份跨年头时 hint 是个区间（`2021–2022`），桶还是同一个', () {
      final List<SourceItemView> pool = <SourceItemView>[
        _item('无职转生 第二季 - 01', DateTime.utc(2024, 4, 10)),
        _item('無職転生 ～異世界行ったら本気だす～ - 05', DateTime.utc(2021, 2, 8)),
        _item('無職転生 ～異世界行ったら本気だす～ - 05 BD', DateTime.utc(2022, 1, 9)),
      ];
      final SeedVersionSplit split = splitSeedVersions(pool, _s2Part2);
      expect(split.others, hasLength(1));
      expect(split.others.single.label, kEarlierVersionLabel);
      expect(split.others.single.hint, '2021–2022');
      expect(split.others.single.count, 2);
    });

    test('兜底：一条本作都不剩时**不分**（整池原样给，不许把页面弄空）', () {
      final List<SourceItemView> pool = <SourceItemView>[
        _item('无职转生 第三季 - 01', DateTime.utc(2026, 7, 10)),
        _item('无职转生 第三季 - 02', DateTime.utc(2026, 7, 17)),
      ];
      final SeedVersionSplit split = splitSeedVersions(pool, _s2Part2);
      expect(split.current, hasLength(2));
      expect(split.others, isEmpty);
    });

    test('条目没变：顺序、数量都对得上（不重排、不吞）', () {
      final List<SourceItemView> pool = <SourceItemView>[
        for (int i = 1; i <= 5; i++)
          _item('无职转生 第二季 - $i', DateTime.utc(2024, 4, 10).add(Duration(days: i))),
      ];
      final SeedVersionSplit split = splitSeedVersions(pool, _s2Part2);
      expect(split.current, hasLength(5));
      expect(split.others, isEmpty);
      for (int i = 0; i < split.current.length; i++) {
        expect(split.current[i].id, pool[i].id);
      }
    });
  });
}
