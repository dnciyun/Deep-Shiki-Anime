/// 「正在追」点开层的「种子」块主体（第四十九轮）：
/// 追番记录 → 一条**最小** Bangumi 条目（种子块只认这个类型）。
///
/// 用户原话：「优化下订阅，详细页订阅的也带有种子」—— 见 `domain/following_seed.dart` 头部。
/// 这里钉的是**纯函数**：id 规则（三种来源各一段、互不相撞、重启稳定）、
/// 名字/日期/话数的映射，以及"搜什么词"那级阶梯真的拿到番名。
library;

import 'package:dsanima/domain/bangumi.dart';
import 'package:dsanima/domain/following_seed.dart';
import 'package:dsanima/domain/following_store.dart';
import 'package:dsanima/domain/library_seed.dart';
import 'package:flutter_test/flutter_test.dart';

FollowingEntry _entry({
  String id = 'mikan:3887',
  String title = '葬送的芙莉莲',
  String? titleEn,
  String? mikanBangumiId = '3887',
  int? bgmId,
  String? airDate,
  int? totalEpisodes,
  String? coverUrl,
}) => FollowingEntry(
  id: id,
  title: title,
  titleEn: titleEn,
  mikanBangumiId: mikanBangumiId,
  bgmId: bgmId,
  airDate: airDate,
  totalEpisodes: totalEpisodes,
  coverUrl: coverUrl,
  addedAt: DateTime(2026, 10, 1),
);

void main() {
  group('主体：Bangumi 来的记录', () {
    test('直接用 bgmId（和动漫库详细页共用同一份种子状态与锚点）', () {
      final FollowingEntry entry = _entry(
        id: 'bgm:400602',
        title: '葬送的芙莉莲',
        titleEn: 'Sousou no Frieren',
        mikanBangumiId: null,
        bgmId: 400602,
        airDate: '2023-09-29',
        totalEpisodes: 28,
        coverUrl: 'https://lain.bgm.tv/pic/cover/l/x.jpg',
      );
      final BangumiSubject subject = seedSubjectFromFollowing(entry);

      expect(subject.id, 400602);
      expect(subject.nameCn, '葬送的芙莉莲');
      expect(subject.name, 'Sousou no Frieren');
      expect(subject.date, '2023-09-29');
      expect(subject.eps, 28);
      expect(subject.coverUrl, 'https://lain.bgm.tv/pic/cover/l/x.jpg');
      expect(subject.displayTitle, '葬送的芙莉莲');
    });

    test('英文名与番名一样时不再占一个搜索阶梯', () {
      final BangumiSubject subject = seedSubjectFromFollowing(
        _entry(
          id: 'bgm:1',
          title: 'SPY×FAMILY',
          titleEn: 'SPY×FAMILY',
          mikanBangumiId: null,
          bgmId: 1,
        ),
      );
      expect(subject.name, isNull, reason: '同一个名字给两次没有意义');
      expect(librarySeedQueries(subject), <String>['SPY×FAMILY']);
    });
  });

  group('主体：主页来的记录（只有 mikan 番剧 id）', () {
    test('造稳定负数 id：真实 Bangumi 条目 id 恒为正，永不撞', () {
      final FollowingEntry entry = _entry();
      final BangumiSubject subject = seedSubjectFromFollowing(entry);

      expect(subject.id, -3888, reason: '-(3887 + 1)');
      expect(subject.id, isNegative);
      expect(subject.nameCn, '葬送的芙莉莲');
      expect(subject.name, isNull, reason: '主页来的记录没有英文名');
      expect(subject.date, isNull, reason: '没有就说没有，不猜');
      expect(subject.eps, isNull);
      // 重启后还是同一个数 ⇒ 用户在这一页粘过的 mikan 番剧页还认得回来。
      expect(seedSubjectIdFromFollowing(_entry()), subject.id);
    });

    test('番名就是种子块那一级搜索阶梯的第一词', () {
      // 尾缀在**结尾**时 `dropSeasonSuffix` 才剥得掉（`librarySeedQueries` 的既定行为：
      // 各站搜整串常是 0 行，所以短名也要进阶梯）。
      final FollowingEntry entry = _entry(title: '无职转生 第二季');
      final List<String> queries = librarySeedQueries(
        seedSubjectFromFollowing(entry),
      );
      expect(queries.first, '无职转生 第二季');
      expect(
        queries,
        contains('无职转生'),
        reason: '去掉季/部尾缀的短名也在阶梯里（各站搜整串常是 0 行）',
      );
    });
  });

  group('主体：只有番名的记录', () {
    test('id 落到更低的负数段，且同一个追番 id 每次都算出同一个数', () {
      final FollowingEntry entry = _entry(
        id: 'title:葬送的芙莉莲',
        mikanBangumiId: null,
      );
      final int id = seedSubjectIdFromFollowing(entry);
      expect(id, lessThanOrEqualTo(-(1 << 30)));
      expect(seedSubjectIdFromFollowing(entry), id, reason: '纯函数，不随机');
    });

    test('不同番名不同 id；与 mikan 那一段不重叠', () {
      final int a = seedSubjectIdFromFollowing(
        _entry(id: 'title:A', title: 'A', mikanBangumiId: null),
      );
      final int b = seedSubjectIdFromFollowing(
        _entry(id: 'title:B', title: 'B', mikanBangumiId: null),
      );
      final int mikan = seedSubjectIdFromFollowing(_entry());

      expect(a, isNot(b));
      expect(a, isNot(mikan));
      expect(mikan, greaterThan(a), reason: 'mikan 段（-10^9..-1）在标题段之上');
    });

    test('番名为空时 nameCn 留 null（不编一个假的 Bangumi 名）', () {
      final BangumiSubject subject = seedSubjectFromFollowing(
        _entry(id: 'title:', title: '', mikanBangumiId: null),
      );
      expect(subject.nameCn, isNull);
      expect(subject.name, isNull);
    });
  });
}
