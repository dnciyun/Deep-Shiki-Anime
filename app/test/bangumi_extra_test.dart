/// 详情页的**补充内容**（第三十七轮）：角色 + 关联条目的解析。
///
/// 用户原话：「现在下面又留空太多了，可以参考bangumi那样的布局」——bangumi 条目页
/// 之所以长而不空，是因为信息块下面还有通栏盒子（角色 / 制作人员 / 关联条目）。
/// 这里钉的是**实测回来的两个端点**的形状（`tool/round37_subject_probe.py`，
/// 原始证据 `build/round37/subject-endpoints.txt`）：
///
/// * `GET /v0/subjects/{id}/characters` → **裸数组**，键 `id / name / relation / type /
///   images / summary / actors`；`name` 是**日文原名**（这个端点不给 `name_cn`），
///   中文那一行是声优（`actors[0].name`）；
/// * `GET /v0/subjects/{id}/subjects` → **裸数组**，键 `id / images / name / name_cn /
///   relation / type`；`relation` 实测有「续集 / 衍生 / 联动 / 原声集 / 片头曲 / 片尾曲 /
///   广播剧 / 书籍 / 单行本 / 游戏 / 三次元 / 番外篇 / 角色出演 / 其他」；
/// * 两条都可能回 `[]`（实测 #462993 就是）——那时详情页不画那一块。
library;

import 'dart:convert';

import 'package:dsanima/domain/bangumi.dart';
import 'package:flutter_test/flutter_test.dart';

/// 实测响应里第一条的形状（#400602 的「フリーレン」，只截了要看的字段）。
const String _charactersJson = '''
[
  {
    "images": {
      "small": "https://lain.bgm.tv/r/100/pic/crt/l/b5/b6/86246_crt_L0Zmt.jpg",
      "grid": "https://lain.bgm.tv/pic/crt/g/b5/b6/86246_crt_L0Zmt.jpg",
      "large": "https://lain.bgm.tv/pic/crt/l/b5/b6/86246_crt_L0Zmt.jpg",
      "medium": "https://lain.bgm.tv/r/400/pic/crt/l/b5/b6/86246_crt_L0Zmt.jpg"
    },
    "name": "フリーレン",
    "relation": "主角",
    "type": 1,
    "id": 86246,
    "actors": [
      {
        "images": {"large": "https://lain.bgm.tv/pic/crt/l/7a/a7/7575_prsn_8TJlL.jpg"},
        "name": "種﨑敦美",
        "type": 2,
        "id": 7575
      }
    ]
  },
  {
    "images": {"large": "https://lain.bgm.tv/pic/crt/l/38/6d/86247_crt_K4gRr.jpg"},
    "name": "フェルン",
    "relation": "主角",
    "type": 1,
    "id": 86247,
    "actors": [{"name": "市ノ瀬加那", "type": 2, "id": 6196}]
  },
  {
    "images": {"large": "https://lain.bgm.tv/pic/crt/l/63/0a/88208_crt_mm77H.jpg?r=1692974287"},
    "name": "ヒンメル",
    "relation": "配角",
    "type": 1,
    "id": 88208,
    "actors": []
  }
]
''';

const String _relatedJson = '''
[
  {
    "images": {"grid": "https://lain.bgm.tv/r/100/pic/cover/l/22/90/459398_7N2k1.jpg",
               "large": "https://lain.bgm.tv/pic/cover/l/22/90/459398_7N2k1.jpg"},
    "name": "葬送のフリーレン 第2期",
    "name_cn": "葬送的芙莉莲 第二季",
    "relation": "续集",
    "type": 2,
    "id": 459398
  },
  {
    "images": {"grid": "https://lain.bgm.tv/r/100/pic/cover/l/9f/b4/660333_21tpZ.jpg",
               "large": "https://lain.bgm.tv/pic/cover/l/9f/b4/660333_21tpZ.jpg"},
    "name": "「葬送のフリーレン」オリジナルサウンドトラック",
    "name_cn": "",
    "relation": "原声集",
    "type": 3,
    "id": 660333
  },
  {
    "images": {"small": "", "grid": "", "large": "", "medium": ""},
    "name": "「葬送のフリーレン」BD&DVD Vol.1 初回特典",
    "name_cn": "",
    "relation": "广播剧",
    "type": 3,
    "id": 622768
  }
]
''';

void main() {
  group('角色（GET /v0/subjects/{id}/characters）', () {
    test('解析出名字 / 关系 / 头像 / 声优（实测三条逐项对得上）', () {
      final List<BangumiCharacter> list = parseBangumiCharacters(_charactersJson);
      expect(list, hasLength(3));

      final BangumiCharacter first = list.first;
      expect(first.id, 86246);
      expect(first.name, 'フリーレン', reason: '这个端点给的是日文原名');
      expect(first.relation, '主角', reason: 'API 已经按主次排序：主角在前');
      expect(first.actorName, '種﨑敦美', reason: '中文那一行用声优名（bangumi 网页也是这样）');
      expect(first.avatarUrl, 'https://lain.bgm.tv/pic/crt/l/b5/b6/86246_crt_L0Zmt.jpg');
      expect(first.label, 'フリーレン');

      expect(list[2].actorName, isNull, reason: '没有声优就是 null（那一行不画）');
      expect(list[2].avatarUrl, endsWith('?r=1692974287'),
          reason: '带时间戳的头像 URL 原样留着（抬档时不能把查询串吃掉）');
    });

    test('头像按显示尺寸抬档（与封面同一套四档，只改 l 那一份）', () {
      const String raw = 'https://lain.bgm.tv/pic/crt/l/b5/b6/86246_crt_L0Zmt.jpg';
      expect(bangumiCharacterAt(raw, 50), startsWith('https://lain.bgm.tv/r/100/pic/crt/l/'));
      expect(bangumiCharacterAt(raw, 112), contains('/r/200/pic/crt/l/'));
      expect(bangumiCharacterAt(raw, 300), contains('/r/400/pic/crt/l/'));
      expect(bangumiCharacterAt(raw, 900), contains('/r/800/pic/crt/l/'));
      // `grid` 那一份（48px 的小图）也要归一化到 `l` 再抬档，否则图床 400。
      expect(
        bangumiCharacterAt('https://lain.bgm.tv/pic/crt/g/b5/b6/86246_crt_L0Zmt.jpg', 400),
        'https://lain.bgm.tv/r/400/pic/crt/l/b5/b6/86246_crt_L0Zmt.jpg',
      );
      // 不是 Bangumi 的头像（mikan 等）一律原样返回，绝不改别人的 URL。
      const String mikan = 'https://mikanani.me/images/Bangumi/202610/abc.jpg';
      expect(bangumiCharacterAt(mikan, 400), mikan);
      // `bangumiImageAt` 是控件用的那个唯一入口：封面与头像各跑一遍。
      expect(
        bangumiImageAt('https://lain.bgm.tv/pic/cover/l/8a/b2/312427_D2ZNm.jpg', 400),
        'https://lain.bgm.tv/r/400/pic/cover/l/8a/b2/312427_D2ZNm.jpg',
      );
    });

    test('空数组（实测 #462993 就是 0 条）⇒ 空表，不抛', () {
      expect(parseBangumiCharacters('[]'), isEmpty);
      expect(parseBangumiCharacters('{"data": []}'), isEmpty);
    });

    test('换类型 / 脏数据不许把整页炸掉：不是对象的行跳过，缺字段的给 null', () {
      const String messy = '[1, null, {"id": "x"}, {"id": 7, "name": "  ", "actors": 5},'
          ' {"id": 8, "name": "A", "actors": [{"name": "CV"}], "images": "oops"}]';
      final List<BangumiCharacter> list = parseBangumiCharacters(messy);
      expect(list.map((BangumiCharacter c) => c.id), <int>[0, 7, 8]);
      expect(list[1].name, isNull, reason: '只有空白字符 = 没有名字');
      expect(list[1].label, '角色 #7', reason: '没名字也要有个能显示的东西');
      expect(list[2].actorName, 'CV');
      expect(list[2].avatarUrl, isNull, reason: 'images 换类型 ⇒ 没有头像（走占位），不炸');
    });

    test('不是 JSON ⇒ BangumiException（不静默返回空表）', () {
      expect(
        () => parseBangumiCharacters('<html>403</html>'),
        throwsA(isA<BangumiException>()),
      );
    });
  });

  group('关联条目（GET /v0/subjects/{id}/subjects）', () {
    test('解析出条目 + 关系标签（续集 / 原声集 / 广播剧）', () {
      final List<BangumiRelated> list = parseBangumiRelated(_relatedJson);
      expect(list, hasLength(3));
      expect(list[0].relation, '续集');
      expect(list[0].subject.id, 459398);
      expect(list[0].subject.displayTitle, '葬送的芙莉莲 第二季');
      expect(list[1].relation, '原声集');
      expect(list[1].subject.displayTitle, '「葬送のフリーレン」オリジナルサウンドトラック',
          reason: 'name_cn 是空串 ⇒ 回落到原名');
      expect(list[2].subject.coverUrl, isNull, reason: '没有封面的关联条目走占位');
      // 关联条目照样能按显示尺寸取档（复用 BangumiSubject 的那套）。
      expect(list[0].subject.coverUrlAt(200), contains('/r/200/pic/cover/l/'));
    });

    test('空数组 ⇒ 空表；不是 JSON ⇒ 抛（与角色同一套规矩）', () {
      expect(parseBangumiRelated('[]'), isEmpty);
      expect(() => parseBangumiRelated('nope'), throwsA(isA<BangumiException>()));
    });
  });

  group('缓存往返（BangumiSubjectExtra.toJson/fromJson）', () {
    test('角色与关联条目存下来再读回来，字段不丢', () {
      final BangumiSubjectExtra extra = BangumiSubjectExtra(
        characters: parseBangumiCharacters(_charactersJson),
        related: parseBangumiRelated(_relatedJson),
      );
      final BangumiSubjectExtra back = BangumiSubjectExtra.fromJson(
        jsonDecode(jsonEncode(extra.toJson())) as Map<String, Object?>,
      );
      expect(back.characters.map((BangumiCharacter c) => c.label),
          extra.characters.map((BangumiCharacter c) => c.label));
      expect(back.characters.last.actorName, isNull);
      expect(back.characters.first.avatarUrl, extra.characters.first.avatarUrl);
      expect(back.related.map((BangumiRelated r) => r.relation),
          extra.related.map((BangumiRelated r) => r.relation));
      expect(back.related.first.subject.displayTitle, '葬送的芙莉莲 第二季');
      expect(back.related.first.subject.coverUrl, extra.related.first.subject.coverUrl);
    });

    test('盘上是空的 / 缺键 ⇒ 空表（老缓存里没有这两个键，不许炸）', () {
      final BangumiSubjectExtra back =
          BangumiSubjectExtra.fromJson(const <String, Object?>{'cachedAt': '2026-10-16T00:00:00'});
      expect(back.isEmpty, isTrue);
      expect(BangumiSubjectExtra.empty.isEmpty, isTrue);
    });
  });
}
