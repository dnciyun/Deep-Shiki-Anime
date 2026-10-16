/// 字幕组筛选的**领域**测试（第四十五轮：用户「在搜索中加入字幕组筛选」）。
///
/// 这一层只钉不碰 UI、不碰网络的东西：
/// 1. **一份归一化**（改造前仓库里有三份互不复用的副本，见 `subtitle_groups.dart`
///    的库注释）——大小写 / 全角 / 空格 / 尾缀「字幕组·字幕社·Sub」都要归到一起；
/// 2. **协作署名拆开**（`喵萌奶茶屋&LoliHouse` 勾喵萌也要筛得出来）；
/// 3. **不是组的词**（搬运 / 合集 / 无修 / Baha）必须出局，不能变成筛选项；
/// 4. **候选构建**：计数按未筛的池子、未知组单列且永远在最后、预置 0 命中照列。
library;

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/subtitle_groups.dart';
import 'package:flutter_test/flutter_test.dart';

SourceItemView _item(String id, String? group) => SourceItemView(
  id: id,
  sourceId: 'mikan',
  title: '标题 $id',
  group: group,
);

void main() {
  group('normalizeGroupKey：唯一的那一份归一化', () {
    test('大小写 / 全角 / 空格 / 下划线 / 点 都归到同一个 key', () {
      for (final String raw in <String>[
        'Skymoon-Raws',
        'skymoon raws',
        '  Skymoon_Raws  ',
        'Skymoon.Raws',
        'Ｓｋｙｍｏｏｎ－Ｒａｗｓ', // 全角字母 + 全角连字符
      ]) {
        expect(normalizeGroupKey(raw), 'skymoon-raws', reason: raw);
      }
    });

    test('尾缀被剥掉：桜都字幕組 = 桜都字幕组 = 桜都；极影字幕社 = 极影', () {
      expect(normalizeGroupKey('桜都字幕组'), '桜都');
      expect(normalizeGroupKey('桜都字幕組'), '桜都');
      expect(normalizeGroupKey('桜都'), '桜都');
      expect(normalizeGroupKey('极影字幕社'), '极影');
      expect(normalizeGroupKey('SweetSub'), 'sweet');
      expect(normalizeGroupKey('离谱Sub'), '离谱');
      expect(normalizeGroupKey('SOSG字幕团'), 'sosg');
    });

    test('首尾括号只是包裹（方括号里是组名、不算名字的一部分）', () {
      expect(normalizeGroupKey('[Nix-Raws]'), 'nix-raws');
      expect(normalizeGroupKey('【悠哈璃羽字幕社】'), '悠哈璃羽');
      expect(normalizeGroupKey('「喵萌奶茶屋」'), '喵萌奶茶屋');
    });

    test('分隔符折成 `-` 而不是删掉：A-One 与 AOne 不是同一家', () {
      expect(normalizeGroupKey('A-One'), 'a-one');
      expect(normalizeGroupKey('AOne'), 'aone');
    });

    test('「不是组」的词一律 null（搬运 / 合集 / 无修 / Baha / 光秃秃的字幕组）', () {
      for (final String raw in <String>[
        '搬运',
        '合集',
        '无修',
        'Baha',
        '字幕组',
        'raws',
        'Sub',
      ]) {
        expect(normalizeGroupKey(raw), isNull, reason: raw);
      }
    });

    test('空 / 全空白 / 只有括号 → null', () {
      expect(normalizeGroupKey(null), isNull);
      expect(normalizeGroupKey('   '), isNull);
      expect(normalizeGroupKey('[]'), isNull);
    });
  });

  group('groupKeysOf：协作署名拆开', () {
    test('`&`、`+`、顿号、逗号都拆，且各自归一化', () {
      expect(groupKeysOf('喵萌奶茶屋&LoliHouse'), <String>['喵萌奶茶屋', 'lolihouse']);
      expect(groupKeysOf('极影字幕+轻之国度'), <String>['极影', '轻之国度']);
      expect(groupKeysOf('华盟字幕社&元古I.G部落'), <String>['华盟', '元古i-g部落']);
      expect(groupKeysOf('爱恋字幕社、猫恋汉化组'), <String>['爱恋', '猫恋']);
    });

    test('不在 `-` 与 `/` 上拆（NC-Raws / Up to 21°C 里的符号是名字的一部分）', () {
      expect(groupKeysOf('NC-Raws'), <String>['nc-raws']);
      expect(groupKeysOf('Up to 21°C'), <String>['up-to-21°c']);
    });

    test('整名都是「不是组」的词 → 空表（这一条会被算进「未知组」）', () {
      expect(groupKeysOf('搬运'), isEmpty);
      expect(groupKeysOf(null), isEmpty);
      expect(groupKeysOf('   '), isEmpty);
    });
  });

  group('itemMatchesSubtitleGroups', () {
    test('一个都没勾 = 全通过（筛选没开）', () {
      expect(itemMatchesSubtitleGroups(_item('1', '桜都字幕组'), const <String>{}), isTrue);
      expect(itemMatchesSubtitleGroups(_item('2', null), const <String>{}), isTrue);
    });

    test('多选是**并集**：勾两家，两家的条目都算命中', () {
      const Set<String> keys = <String>{'桜都', 'lolihouse'};
      expect(itemMatchesSubtitleGroups(_item('1', '桜都字幕组'), keys), isTrue);
      expect(itemMatchesSubtitleGroups(_item('2', 'LoliHouse'), keys), isTrue);
      expect(itemMatchesSubtitleGroups(_item('3', '喵萌奶茶屋'), keys), isFalse);
    });

    test('协作署名任一命中即可（勾喵萌也要筛出 喵萌奶茶屋&LoliHouse）', () {
      expect(
        itemMatchesSubtitleGroups(_item('1', '喵萌奶茶屋&LoliHouse'), <String>{'喵萌奶茶屋'}),
        isTrue,
      );
      expect(
        itemMatchesSubtitleGroups(_item('1', '喵萌奶茶屋&LoliHouse'), <String>{'lolihouse'}),
        isTrue,
      );
    });

    test('组名解析不出来的条目：只在勾了「未知组」时命中', () {
      final SourceItemView unknown = _item('1', null);
      expect(itemMatchesSubtitleGroups(unknown, <String>{'桜都'}), isFalse);
      expect(
        itemMatchesSubtitleGroups(unknown, <String>{kUnknownSubtitleGroupKey}),
        isTrue,
      );
      // 「搬运」这类被黑名单挡掉的方括号标签，也归进未知档（它不是任何一家）。
      final SourceItemView mover = _item('2', '搬运');
      expect(itemMatchesSubtitleGroups(mover, <String>{'桜都'}), isFalse);
      expect(
        itemMatchesSubtitleGroups(mover, <String>{kUnknownSubtitleGroupKey}),
        isTrue,
      );
    });
  });

  group('buildSubtitleGroupOptions', () {
    final List<SourceItemView> pool = <SourceItemView>[
      _item('1', '桜都字幕组'),
      _item('2', '桜都字幕組'), // 同一个组的另一种写法 → 合成一项
      _item('3', 'LoliHouse'),
      _item('4', '喵萌奶茶屋&LoliHouse'), // 协作署名 → 两家各算一条
      _item('5', null), // 未知组
      _item('6', '搬运'), // 不是组 → 也进未知组
    ];

    test('计数按条数（同组不同写法合并；协作署名两边都算）', () {
      final List<SubtitleGroupOption> options = buildSubtitleGroupOptions(pool: pool);
      SubtitleGroupOption of(String key) =>
          options.firstWhere((SubtitleGroupOption o) => o.key == key);
      expect(of('桜都').count, 2);
      expect(of('lolihouse').count, 2);
      expect(of('喵萌奶茶屋').count, 1);
      expect(of(kUnknownSubtitleGroupKey).count, 2);
    });

    test('未知组单列一项、永远在最后、不可当预置', () {
      final List<SubtitleGroupOption> options = buildSubtitleGroupOptions(pool: pool);
      expect(options.last.key, kUnknownSubtitleGroupKey);
      expect(options.last.isUnknown, isTrue);
      expect(options.last.preset, isFalse);
      expect(
        options.where((SubtitleGroupOption o) => o.isUnknown).length,
        1,
        reason: '未知组只能有一项',
      );
    });

    test('预置但这一批 0 命中的照列（显示 0 条）', () {
      final List<SubtitleGroupOption> options = buildSubtitleGroupOptions(pool: pool);
      final SubtitleGroupOption jiyin =
          options.firstWhere((SubtitleGroupOption o) => o.key == '极影');
      expect(jiyin.count, 0);
      expect(jiyin.preset, isTrue);
      expect(jiyin.selected, isFalse);
    });

    test('排序：已勾选最前 → 最近用过 → 命中多的 → 预置顺序', () {
      final List<SubtitleGroupOption> options = buildSubtitleGroupOptions(
        pool: pool,
        selected: <String>{'lolihouse'},
        recent: <String>['喵萌奶茶屋'],
      );
      expect(options[0].key, 'lolihouse', reason: '已勾选的排最前（方便取消）');
      expect(options[0].selected, isTrue);
      expect(options[1].key, '喵萌奶茶屋', reason: '最近用过的次之');
      expect(options[2].key, '桜都', reason: '再按命中条数（桜都 2 条）');
    });

    test('展示名：预置优先，其余取本批里最常见的原始写法', () {
      final List<SubtitleGroupOption> options = buildSubtitleGroupOptions(pool: pool);
      SubtitleGroupOption of(String key) =>
          options.firstWhere((SubtitleGroupOption o) => o.key == key);
      expect(of('桜都').label, '桜都字幕组', reason: '预置表里的写法（不是小写 key）');
      // 不在预置表里的组：拿池子里的原始写法（`喵萌奶茶屋&LoliHouse` 里的那一段）。
      expect(of('喵萌奶茶屋').label, '喵萌奶茶屋');
    });

    test('预置 33 家，key 无重复', () {
      expect(kPresetSubtitleGroups.length, 33);
      final Set<String> keys = <String>{};
      for (final String g in kPresetSubtitleGroups) {
        final String? key = normalizeGroupKey(g);
        expect(key, isNotNull, reason: '$g 应该是合法组名');
        expect(keys.add(key!), isTrue, reason: '$g 的 key（$key）和前面的重复了');
      }
    });
  });

  group('subtitleGroupLabel', () {
    test('预置优先；不在预置表里的到池子里取原始写法；未知组给「未知组」', () {
      expect(subtitleGroupLabel('桜都', const <SourceItemView>[]), '桜都字幕组');
      expect(
        subtitleGroupLabel('爪爪', <SourceItemView>[_item('1', '爪爪字幕组')]),
        '爪爪字幕组',
        reason: '不在预置表里的组：到池子里取原始写法（不是小写 key）',
      );
      expect(subtitleGroupLabel(kUnknownSubtitleGroupKey, const <SourceItemView>[]), '未知组');
      // 池子里也找不到（换了一轮搜索）→ 退回 key 本身，至少不是空字符串。
      expect(subtitleGroupLabel('某个冷门组', const <SourceItemView>[]), '某个冷门组');
    });
  });
}
