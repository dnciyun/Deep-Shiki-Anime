/// 动漫库**条目详情页**（第三十三轮起的落点；第三十四轮填内容、第三十五轮重排版面）。
///
/// 用户第三十四轮原话：「动漫库点的详细页，太空了优化下」⇒ 这里钉的**不是**"页面上有字"，
/// 而是**那些以前没解析、没画出来的东西真的出现了**：评分分布（`rating.count` 10 档）、
/// 收藏统计（`collection`）、资料表（`infobox`），以及"没有这些字段的条目不许画空条、不许崩"。
///
/// 用户第三十五轮原话：「详细页优化下布局」⇒ 另加一组**版面**断言：宽窗是
/// 「左栏（海报 + 事实 + 动作 + 收藏 + 标签）+ 右栏（标题 + 评分分布 + 资料 + 简介）」两栏、
/// 两栏高度相当（"某块下面空一大截"就是这么出现的）、窄窗单栏竖排、整页限宽居中。
/// 逐块像素数字在 `test/library_detail_layout_probe.dart`（探针，不进默认全量）。
///
/// 全部用假端口（不联网），断言落在**看得见的东西**上（key / 文案 / 位置）。
library;

import 'package:dsanima/domain/bangumi.dart';
import 'package:dsanima/domain/bangumi_library.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/state/library_provider.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/theme/tokens.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/ui/library_detail_page.dart';
import 'package:dsanima/ui/widgets/cover.dart';
import 'package:dsanima/ui/widgets/follow_button.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 详情端点实测回来的那种条目（`tool/round34_subject_probe.py` 的 #400602 形状）：
/// 有 10 档票数、有收藏统计、有几十行资料。
BangumiSubject _fullSubject() => BangumiSubject(
      id: 400602,
      name: 'Sousou no Frieren',
      nameCn: '葬送的芙莉莲',
      date: '2023-09-29',
      eps: 28,
      score: 8.5,
      rank: 43,
      ratingTotal: 36596,
      coverUrl: 'https://lain.bgm.tv/r/100/pic/cover/l/x/400602.jpg',
      tags: const <String>['治愈', '奇幻', '公路片'],
      summary: '勇者一行打败魔王之后的旅程。',
      platform: 'TV',
      type: 2,
      ratingCounts: const <int, int>{
        1: 129,
        2: 37,
        3: 53,
        4: 112,
        5: 356,
        6: 1101,
        7: 3727,
        8: 10609,
        9: 12961,
        10: 7511,
      },
      collection: const BangumiCollection(
        wish: 7061,
        collect: 54970,
        doing: 11847,
        onHold: 2030,
        dropped: 766,
      ),
      infobox: const <BangumiInfoboxItem>[
        BangumiInfoboxItem(key: '中文名', values: <String>['葬送的芙莉莲']),
        BangumiInfoboxItem(key: '别名', values: <String>['Frieren', 'Sousou no Frieren']),
        BangumiInfoboxItem(key: '话数', values: <String>['28']),
        BangumiInfoboxItem(key: '放送开始', values: <String>['2023年9月29日']),
        BangumiInfoboxItem(key: '放送星期', values: <String>['星期五']),
        BangumiInfoboxItem(key: '官方网站', values: <String>['https://frieren-anime.jp/']),
        BangumiInfoboxItem(key: '播放电视台', values: <String>['日本テレビ系']),
        BangumiInfoboxItem(key: '其他电视台', values: <String>['BS日テレ / AT-X']),
        BangumiInfoboxItem(key: '播放结束', values: <String>['2024年3月22日']),
        BangumiInfoboxItem(key: '原作', values: <String>['山田鐘人']),
        BangumiInfoboxItem(key: '导演', values: <String>['斎藤圭一郎']),
        BangumiInfoboxItem(key: '音乐', values: <String>['Evan Call']),
        BangumiInfoboxItem(key: '动画制作', values: <String>['MADHOUSE']),
      ],
    );

/// 只有搜索端点那些字段的条目（没有分布/收藏/资料）—— 详情还没回来时页面看到的就是它。
BangumiSubject _bareSubject() => BangumiSubject(
      id: 999,
      name: 'Bare',
      nameCn: '只有标题',
      date: '2024-01-06',
      score: 7.2,
      coverUrl: 'https://lain.bgm.tv/r/100/pic/cover/l/x/999.jpg',
      platform: 'TV',
      type: 2,
    );

class _FakePort implements BangumiLibraryPort {
  _FakePort(this.subject);

  BangumiSubject subject;
  int detailCalls = 0;
  bool fail = false;

  @override
  bool get isAvailable => true;

  @override
  Future<BangumiLibraryPage> search(
    BangumiLibraryQuery query, {
    int offset = 0,
    int limit = kLibraryDefaultPageSize,
  }) async =>
      BangumiLibraryPage(
        items: <BangumiSubject>[subject],
        total: 1,
        startOffset: offset,
        nextOffset: offset + 1,
        hasMore: false,
      );

  @override
  Future<BangumiSubject> detail(int id) async {
    detailCalls++;
    if (fail) throw const PortUnavailableException('详情没接通（测试替身）');
    return subject;
  }

  /// 角色 / 关联条目（第三十七轮）。默认给 20 位 + 2 条 —— 20 > 折叠阈值（16），
  /// 于是"展开全部"那条路也在用例覆盖里；[extrasFail] 用来钉"这块拉不到时主内容照旧"。
  bool extrasFail = false;

  /// 条目**真的没有**角色与关联条目（实测孤独摇滚 #462993 两条端点都回 `[]`）。
  bool extrasEmpty = false;
  int extrasCalls = 0;

  @override
  Future<BangumiSubjectExtra> extras(int id) async {
    extrasCalls++;
    if (extrasFail) throw const PortUnavailableException('角色没拉到（测试替身）');
    if (extrasEmpty) return BangumiSubjectExtra.empty;
    return BangumiSubjectExtra(
      characters: <BangumiCharacter>[
        for (int i = 0; i < 20; i++)
          BangumiCharacter(
            id: 86000 + i,
            name: '角色 $i',
            relation: i < 6 ? '主角' : '配角',
            avatarUrl: 'https://lain.bgm.tv/pic/crt/l/x/${86000 + i}.jpg',
            actorName: '声优 $i',
          ),
      ],
      related: const <BangumiRelated>[
        BangumiRelated(
          relation: '续集',
          subject: BangumiSubject(
            id: 900001,
            name: '葬送のフリーレン 第2期',
            nameCn: '葬送的芙莉莲 第二季',
            coverUrl: 'https://lain.bgm.tv/r/100/pic/cover/l/x/900001.jpg',
            type: 2,
          ),
        ),
        BangumiRelated(
          relation: '原声集',
          subject: BangumiSubject(
            id: 900002,
            name: 'オリジナルサウンドトラック',
            coverUrl: 'https://lain.bgm.tv/r/100/pic/cover/l/x/900002.jpg',
            type: 3,
          ),
        ),
      ],
    );
  }
}

Future<_FakePort> _pump(
  WidgetTester tester, {
  required BangumiSubject listSubject,
  BangumiSubject? detailSubject,
  Size size = const Size(1400, 900),
  bool extrasFail = false,
  bool extrasEmpty = false,
}) async {
  final _FakePort port = _FakePort(detailSubject ?? listSubject)
    ..extrasFail = extrasFail
    ..extrasEmpty = extrasEmpty;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
        bangumiLibraryProvider.overrideWithValue(port),
      ],
      child: MaterialApp(
        // 用**真实主题**（`buildDsanimaTheme`）：字号阶梯 / 行高 / 控件尺寸都按规范走，
        // 版面断言才不会拿默认 Material 的尺寸去量（第三十五轮）。
        theme: buildDsanimaTheme(),
        home: LibraryDetailPage(subject: listSubject),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return port;
}

void main() {
  testWidgets('详情页把评分分布 / 收藏统计 / 资料表都画出来（不再是一大片空白）', (WidgetTester tester) async {
    // 窗口给高一点：`ListView(children:)` 也是**懒建**的，屏幕外的卡片根本不在树里，
    // 而这一条要断言的正是"整页都有东西"（所以让整页都在视野内）。
    await _pump(
      tester,
      listSubject: _bareSubject(),
      detailSubject: _fullSubject(),
      size: const Size(1400, 1500),
    );

    // ① 评分分布：10 档都在，票数与均分、排名都在抬头里。
    for (int score = 1; score <= 10; score++) {
      expect(find.byKey(Key('rating-bar-$score')), findsOneWidget, reason: '$score 分那一档不见了');
    }
    expect(find.textContaining('共 36596 人评分'), findsOneWidget);
    expect(find.textContaining('均分 8.5'), findsOneWidget);
    expect(find.textContaining('排名 #43'), findsWidgets);
    expect(find.text('12961'), findsOneWidget, reason: '9 分档的真实票数');

    // ② 收藏统计：五项都在，值是真的。
    for (final String label in <String>['想看', '在看', '看过', '搁置', '抛弃']) {
      expect(find.byKey(Key('collection-$label')), findsOneWidget);
    }
    expect(find.text('54970'), findsOneWidget, reason: '看过');
    expect(find.textContaining('共 76674 人'), findsOneWidget, reason: '五项之和');

    // ③ 资料表：前 12 行直接画，第 13 行折叠着，点一下才出来。
    expect(find.byKey(const Key('infobox-话数')), findsOneWidget);
    expect(find.text('28'), findsWidgets);
    expect(find.byKey(const Key('infobox-动画制作')), findsNothing, reason: '第 13 行默认折叠');
    final Finder toggle = find.byKey(const Key('library-detail-infobox-toggle'));
    expect(toggle, findsOneWidget);
    expect(find.textContaining('还有 1 行'), findsOneWidget);
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('infobox-动画制作')), findsOneWidget, reason: '展开后第 13 行出现');
    expect(find.text('MADHOUSE'), findsOneWidget);

    // ④ 两个动作照旧（第三十三轮的能力一个都没丢）。
    expect(find.byKey(const Key('library-detail-search-seeds')), findsOneWidget);
    expect(find.byType(FollowButton), findsOneWidget);

    // ⑤ 标签与简介在页面靠下：`ListView` 是懒建的，滚过去才在树里 ——
    //    这一滚顺带证明"整页真的有内容可滚"。
    //    （必须点名 `scrollable`：资料表里那些 `SelectableText` 自己也是可滚的，
    //    不点名会撞上 "Too many elements"。）
    final Finder page = find
        .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(find.byKey(const Key('library-tag-治愈')), 300,
        scrollable: page);
    expect(find.byKey(const Key('library-tag-治愈')), findsOneWidget);
    expect(find.text('Frieren / Sousou no Frieren'), findsOneWidget,
        reason: '资料表里的多值项（别名）用「 / 」接起来');
    await tester.scrollUntilVisible(find.text('勇者一行打败魔王之后的旅程。'), 300,
        scrollable: page);
    expect(find.text('勇者一行打败魔王之后的旅程。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有分布/收藏/资料的条目：不画空条，也不崩（搜索端点来的就是这种）', (WidgetTester tester) async {
    await _pump(tester, listSubject: _bareSubject());

    expect(find.byKey(const Key('rating-bar-10')), findsNothing, reason: '没有票数就不画 10 条空槽');
    expect(find.textContaining('还没有人评分'), findsNothing, reason: '它有 7.2 分');
    expect(find.textContaining('暂时只有总分'), findsOneWidget);
    expect(find.byKey(const Key('collection-看过')), findsOneWidget, reason: '这一块保留，但写"还没有人收藏"');
    expect(find.textContaining('还没有人收藏'), findsOneWidget);
    expect(find.byKey(const Key('infobox-话数')), findsNothing);
    expect(find.byType(FollowButton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('版面：宽窗「左栏 + 右栏」两栏高度相当，窄窗单栏竖排 —— 两种都不 overflow', (WidgetTester tester) async {
    await _pump(
      tester,
      listSubject: _bareSubject(),
      detailSubject: _fullSubject(),
      size: const Size(1400, 1000),
    );

    // ① 两栏都在，且左栏在右栏左边、互不重叠。
    final Finder rail = find.byKey(dsDetailRailKey);
    final Finder main = find.byKey(dsDetailMainKey);
    expect(rail, findsOneWidget, reason: '宽窗必须有左栏');
    expect(main, findsOneWidget, reason: '宽窗必须有右栏');
    final Rect railRect = tester.getRect(rail);
    final Rect mainRect = tester.getRect(main);
    expect(railRect.right, lessThanOrEqualTo(mainRect.left), reason: '左栏在右栏左边');

    // ② 各块落在该在的那一栏里（不是"整块通栏"，也不是错位）。
    Finder inRail(Finder f) => find.descendant(of: rail, matching: f);
    Finder inMain(Finder f) => find.descendant(of: main, matching: f);
    expect(inRail(find.byKey(const Key('library-detail-score'))), findsOneWidget, reason: '分数胶囊在左栏');
    expect(inRail(find.byKey(const Key('library-detail-search-seeds'))), findsOneWidget, reason: '动作在左栏');
    expect(inRail(find.byKey(const Key('collection-想看'))), findsOneWidget, reason: '收藏统计在左栏');
    expect(inRail(find.byKey(const Key('library-tag-治愈'))), findsOneWidget, reason: '标签在左栏');
    expect(inMain(find.byKey(const Key('rating-bar-10'))), findsOneWidget, reason: '评分分布在右栏');
    expect(inMain(find.byKey(const Key('infobox-话数'))), findsOneWidget, reason: '资料在右栏');
    // 标题块在右栏顶部（`葬送的芙莉莲` 在资料表的"中文名"那一行也有，所以按**原名**认标题块）。
    expect(inMain(find.text('Sousou no Frieren')), findsOneWidget, reason: '标题块在右栏（AppBar 那份不算）');
    expect(inMain(find.text('评分分布')), findsOneWidget, reason: '评分分布抬头也在右栏');

    // ③ 「某块下面空一大截」是上一版的病灶：并排时行高由高的那块决定，矮的那块下面全是空白。
    //    现在两块在不同栏里，判据换成**两栏高度相当**（探针里 1280 下是 882 / 914）。
    expect(
      (railRect.height - mainRect.height).abs(),
      lessThan(railRect.height * 0.5),
      reason: '左右两栏高度差超过一半 ⇒ 又是一边到头一边空着',
    );

    // ④ 收藏统计不再被拉成"通栏的 1/3"，它就在 300 宽的栏里。
    final Rect collect = tester.getRect(find.byKey(const Key('collection-想看')));
    expect(collect.left, greaterThanOrEqualTo(railRect.left));
    expect(collect.right, lessThanOrEqualTo(railRect.right));

    // ⑤ 资料表一行就是一行的高度：值那一列不再是 `SelectableText`（它按 maxLines: 2 占两行，
    //    实测 47px/行；现在 26px/行）。这一条与字体宽度无关，所以用固定阈值。
    expect(
      tester.getRect(find.byKey(const Key('infobox-话数'))).height,
      lessThan(34),
      reason: '一行资料不该占两行的高度',
    );
    expect(tester.takeException(), isNull);

    // ⑥ 窄窗（600）：退回单栏竖排，两块竖着排，仍然不许溢出。
    //    高度给足 1600：竖排之后两张卡都要在视野里，才量得到相对位置（ListView 是懒建的）。
    await _pump(
      tester,
      listSubject: _bareSubject(),
      detailSubject: _fullSubject(),
      size: const Size(600, 1600),
    );
    expect(find.byKey(dsDetailRailKey), findsNothing, reason: '窄窗没有左右两栏');
    final Rect narrowRating = tester.getRect(find.byKey(const Key('rating-bar-10')));
    final Rect narrowCollect = tester.getRect(find.byKey(const Key('collection-想看')));
    expect(narrowCollect.top, greaterThan(narrowRating.bottom), reason: '窄窗里两块竖排');
    expect(narrowCollect.left, closeTo(narrowRating.left, 30), reason: '窄窗两块都通栏，左边缘对齐');
    expect(tester.takeException(), isNull);
  });

  testWidgets('版面：窗口越宽栏越多（两栏 → 三栏），内容**贴边不留白**（第三十六轮）', (WidgetTester tester) async {
    // ① 1280（默认窗口）：两栏，内容左缘就是内边距（第三十五轮那个"整页限宽居中"会在左边留 74px）。
    await _pump(
      tester,
      listSubject: _bareSubject(),
      detailSubject: _fullSubject(),
      size: const Size(1280, 800),
    );
    final Rect rail = tester.getRect(find.byKey(dsDetailRailKey));
    expect(rail.left, kDetailPadding, reason: '内容左缘 = 内边距（与 AppBar 的返回箭头对齐）');
    expect(find.byKey(dsDetailSideKey), findsNothing, reason: '1280 只要两栏');
    final Rect main = tester.getRect(find.byKey(dsDetailMainKey));
    expect(rail.right, lessThanOrEqualTo(main.left));
    expect(main.right, closeTo(1280 - kDetailPadding, 0.5), reason: '右缘也贴到内边距（右边不留白）');

    // ② 1920（≥ 1560）：加第三栏，于是每一栏都不至于宽得没法读。
    await _pump(
      tester,
      listSubject: _bareSubject(),
      detailSubject: _fullSubject(),
      size: const Size(1920, 1200),
    );
    final Rect wideRail = tester.getRect(find.byKey(dsDetailRailKey));
    final Rect wideMain = tester.getRect(find.byKey(dsDetailMainKey));
    final Rect side = tester.getRect(find.byKey(dsDetailSideKey));
    expect(wideRail.left, kDetailPadding, reason: '再宽也**不居中留白**，左缘仍是内边距');
    expect(wideRail.right, lessThanOrEqualTo(wideMain.left));
    expect(wideMain.right, lessThanOrEqualTo(side.left));
    expect(side.right, closeTo(1920 - kDetailPadding, 0.5), reason: '右缘贴到内边距');
    expect(wideMain.width, lessThan(900), reason: '1920 下不许一栏横跨 1700px（那还是会"空"）');
    expect(side.width, lessThan(900));
    expect(side.height, greaterThan(200), reason: '第三栏里是真内容（资料 / 标签），不是空壳');
    // 资料与标签搬到了第三栏，标题 / 评分分布 / 简介留在中栏。
    expect(
      find.descendant(
        of: find.byKey(dsDetailSideKey),
        matching: find.byKey(const Key('infobox-话数')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(dsDetailSideKey),
        matching: find.byKey(const Key('library-tag-治愈')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(dsDetailMainKey),
        matching: find.byKey(const Key('rating-bar-10')),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('细节：封面**只有一层**框（"封面框有色边"是两层描边夹出来的）', (WidgetTester tester) async {
    await _pump(
      tester,
      listSubject: _bareSubject(),
      detailSubject: _fullSubject(),
      size: const Size(1280, 800),
    );

    // `DsCover` 自己就带一层「sunken 面 + 1px line 描边」（cover.dart），所以外面**不许再套一层**。
    bool isFramed(Widget w) =>
        w is DecoratedBox &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration?)?.border != null;
    expect(
      find.ancestor(
        of: find.byType(DsCover),
        matching: find.byWidgetPredicate(isFramed),
      ),
      findsNothing,
      reason: '海报外面多套一层 inset ⇒ 两道颜色边 + 1px 空隙 = 用户说的"有色边"',
    );
    // 海报槽就是整栏宽（旧版会被 Padding(1) 缩掉 2px，正好把那圈边让出来）。
    final Rect cover = tester.getRect(find.byType(DsCover));
    expect(cover.width, kDetailRailWidth, reason: '海报占满左栏宽度，不再被内缩 2px');
    expect(
      cover.width / cover.height,
      closeTo(kPosterAspect, 0.01),
      reason: '海报仍是固定比例槽',
    );
    // 事实**一行一条**（第三十六轮）：既不是参差的折行，也没有"行尾挂一个孤零零的 ·"。
    expect(find.text('排名 #43'), findsOneWidget);
    expect(find.text('放送 2023-09-29'), findsOneWidget);
    expect(find.text('28 话 · TV'), findsOneWidget, reason: '话数与形态合成一行');
    expect(find.text('36596 人评分'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情拉不到：照实说"没拉到"，并把列表里已有的信息留着（不白屏）', (WidgetTester tester) async {
    final _FakePort port = _FakePort(_bareSubject());
    port.fail = true;
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
          bangumiLibraryProvider.overrideWithValue(port),
        ],
        child: MaterialApp(
          theme: buildDsanimaTheme(),
          home: LibraryDetailPage(subject: _bareSubject()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('详情没拉到'), findsOneWidget);
    expect(find.text('只有标题'), findsWidgets, reason: '标题照旧在（列表里就有）');
    expect(port.detailCalls, 1, reason: '详情只问一次');
    expect(tester.takeException(), isNull);
  });

  testWidgets('重建不会把详情 future 重建成"还没到"（资料表展开时页面不许闪一下）', (WidgetTester tester) async {
    final _FakePort port = await _pump(
      tester,
      listSubject: _bareSubject(),
      detailSubject: _fullSubject(),
    );
    expect(port.detailCalls, 1);

    // 展开资料表 = 子组件 setState；父级不该因此再问一次详情、更不该回到"还没到"。
    final Finder toggle = find.byKey(const Key('library-detail-infobox-toggle'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(port.detailCalls, 1, reason: '详情 future 只建一次（写在 build 里就会重建成新 future）');
    expect(find.byKey(const Key('infobox-动画制作')), findsOneWidget);
  });

  // ── 第三十七轮（用户：「现在下面又留空太多了，可以参考bangumi那样的布局」）──────────
  //
  // 这一轮的病根是**整页比窗口矮**：三栏版面在 2048 逻辑宽下只有 525/559/707 高，
  // 而可视高度约 1050 —— 滚到底之后下面是一大片纯背景。bangumi 条目页不长这样：
  // 它的信息块下面是**通栏**盒子（简介 / 角色 / 制作人员 / 关联条目）。
  // 所以这里补两个真数据的通栏盒子（`/v0/subjects/{id}/characters` 与 `/subjects`），
  // 并把这个"底部不再空一截"用几何钉住（不靠肉眼看）。

  testWidgets('版面：带下面接两个**通栏**盒子，滚到底时最后一个盒子贴着窗口底边（底部不再空一截）',
      (WidgetTester tester) async {
    const Size size = Size(2048, 1152); // 2560 屏 @125% 最大化：用户那台机器
    await _pump(
      tester,
      listSubject: _bareSubject(),
      detailSubject: _fullSubject(),
      size: size,
    );

    final Finder page = find
        .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
        .first;
    final Finder characters = find.byKey(dsDetailCharactersKey);
    final Finder related = find.byKey(dsDetailRelatedKey);

    // ① 两个盒子都在，而且**左右都贴到内边距**（不是窄窄一条挂在某一栏里）。
    await tester.scrollUntilVisible(characters, 400, scrollable: page);
    final Rect chars = tester.getRect(characters);
    expect(chars.left, kDetailPadding);
    expect(chars.right, closeTo(size.width - kDetailPadding, 0.5));
    await tester.scrollUntilVisible(related, 400, scrollable: page);
    final Rect rel = tester.getRect(related);
    expect(rel.left, kDetailPadding);
    expect(rel.right, closeTo(size.width - kDetailPadding, 0.5));

    // ② 一路滚到底（`jumpTo` 几轮：`ListView` 的孩子是懒建的，第一轮的 maxScrollExtent
    //    只是估算；把每个孩子都建出来之后它才是准的）。
    final ScrollableState scroll = tester.state<ScrollableState>(page);
    for (int i = 0; i < 5; i++) {
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
    }
    expect(scroll.position.maxScrollExtent, greaterThan(0),
        reason: '整页必须比窗口高 —— 这就是"下面留空"的解药');
    // 到底之后最后一个盒子的下沿 ≈ 窗口下沿（只差 ListView 的 32 底部内边距）。
    // 用户抱怨的那 440px 空白正是这里量出来的。
    expect(
      tester.getRect(related).bottom,
      greaterThan(size.height - 40),
      reason: '滚到底时内容贴到窗口底边；差了半个屏幕就是"下面又留空太多"',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('角色：先 16 位铺满一行，点「展开全部」才画剩下的', (WidgetTester tester) async {
    await _pump(
      tester,
      listSubject: _bareSubject(),
      detailSubject: _fullSubject(),
      size: const Size(2048, 1400),
    );
    final Finder page = find
        .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(find.byKey(dsDetailCharactersKey), 400, scrollable: page);

    expect(find.byKey(const Key('character-86000')), findsOneWidget, reason: '第 1 位');
    expect(find.byKey(const Key('character-86015')), findsOneWidget, reason: '第 16 位（默认显示到这儿）');
    expect(find.byKey(const Key('character-86016')), findsNothing, reason: '第 17 位默认折叠');
    expect(find.textContaining('还有 4 位'), findsOneWidget);
    // 名字与声优都在（日文原名 + 中文声优，与 bangumi 网页那一行一致）。
    expect(find.text('角色 0'), findsOneWidget);
    expect(find.text('声优 0'), findsOneWidget);

    final Finder toggle = find.byKey(const Key('library-detail-characters-toggle'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('character-86019')), findsOneWidget, reason: '展开后第 20 位出现');
    expect(find.text('收起'), findsOneWidget);
  });

  testWidgets('关联条目：续集 / 原声集都画出来，名字中文优先', (WidgetTester tester) async {
    await _pump(
      tester,
      listSubject: _bareSubject(),
      detailSubject: _fullSubject(),
      size: const Size(2048, 1400),
    );
    final Finder page = find
        .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(find.byKey(dsDetailRelatedKey), 400, scrollable: page);

    expect(find.byKey(const Key('related-900001')), findsOneWidget);
    expect(find.text('葬送的芙莉莲 第二季'), findsOneWidget, reason: '有中文名就用中文名');
    expect(find.text('续集'), findsOneWidget);
    expect(find.text('オリジナルサウンドトラック'), findsOneWidget, reason: '没中文名就显示原名');
    expect(find.text('原声集'), findsOneWidget);
    expect(find.textContaining('共 2 项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('角色 / 关联条目拉不到 ⇒ 主内容照旧，不变成错误页（它们是装饰）', (WidgetTester tester) async {
    final _FakePort port = await _pump(
      tester,
      listSubject: _bareSubject(),
      detailSubject: _fullSubject(),
      size: const Size(1400, 900),
      extrasFail: true,
    );

    expect(port.extrasCalls, 1);
    expect(find.byKey(dsDetailCharactersKey), findsNothing);
    expect(find.byKey(dsDetailRelatedKey), findsNothing);
    expect(find.textContaining('详情没拉到'), findsNothing, reason: '主内容好好的，不该弹警告');
    expect(find.textContaining('共 36596 人评分'), findsOneWidget, reason: '评分分布照旧');
    expect(tester.takeException(), isNull);
  });

  testWidgets('条目真的没有角色与关联（实测孤独摇滚两条端点都回 []）⇒ 不画空盒子', (WidgetTester tester) async {
    await _pump(
      tester,
      listSubject: _bareSubject(),
      detailSubject: _fullSubject(),
      size: const Size(1400, 1500),
      extrasEmpty: true,
    );

    expect(find.byKey(dsDetailCharactersKey), findsNothing);
    expect(find.byKey(dsDetailRelatedKey), findsNothing);
    expect(find.text('角色'), findsNothing, reason: '连抬头都不该出现');
    expect(find.text('关联条目'), findsNothing);
    expect(find.textContaining('共 36596 人评分'), findsOneWidget, reason: '主内容不受影响');
  });
}
