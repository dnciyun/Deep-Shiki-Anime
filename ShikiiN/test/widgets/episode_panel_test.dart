/// 播放列表右侧栏的行内排版（用户 2026-10-12 第十三轮）。
///
/// 用户原话：
/// > 「修改下播放列表逻辑，…放在中间，优先展示集数」
/// > 「全名 `[hyakuhuyu&VCB-Studio] Re Zero kara Hajimeru Isekai Seikatsu 3rd Season
/// > [51][Ma10p_1080p][x265_flac_aac].CHS.mp4`，会导致集数看不见，改成，
/// > 超出多少字数后变成...然后显示集数」
///
/// 这一批用例钉的就是两件事：
/// 1. **标题按字数截断**（超 32 字 → `…`），长文件名不许整行铺满；
/// 2. **集号永远看得见**（占行中间固定宽度那一槽，不被标题挤掉）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/controllers/playlist_controller.dart';
import 'package:shikiin/models/media_item.dart';
import 'package:shikiin/models/theme_tokens.dart';
import 'package:shikiin/widgets/episode_panel.dart';

/// 用户给的那个真实文件名（120+ 字符）。
const String _vcbName =
    '[hyakuhuyu&VCB-Studio] Re Zero kara Hajimeru Isekai Seikatsu 3rd Season '
    '[51][Ma10p_1080p][x265_flac_aac].CHS.mp4';

EpisodeGroup _group(List<(String, int?)> rows, {int current = 0}) => EpisodeGroup(
  items: <MediaItem>[
    for (final (String title, int? ep) in rows)
      MediaItem(path: 'item-$ep', title: title, episode: ep),
  ],
  currentIndex: current,
);

Future<void> _pump(WidgetTester tester, EpisodeGroup group, {void Function(MediaItem)? onSelect}) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            // 默认侧栏宽度：300（见 _kDefaultPanelWidth）——排版断言按这个宽度算。
            width: 300,
            height: 400,
            child: EpisodePanel(
              tokens: ThemeTokens.fallback,
              group: group,
              onSelect: onSelect ?? (_) {},
              onClose: () {},
            ),
          ),
        ),
      ),
    );

void main() {
  group('标题截断（shortenEpisodeTitle）', () {
    test('不超过上限时原样返回（只去首尾空白）', () {
      expect(shortenEpisodeTitle('  [VCB-Studio] Show - 01  '), '[VCB-Studio] Show - 01');
      expect(shortenEpisodeTitle(''), '');
    });

    test('刚好等于上限也不截', () {
      final String exactly = 'a' * kEpisodeTitleMaxChars;
      expect(shortenEpisodeTitle(exactly), exactly);
      expect(shortenEpisodeTitle(exactly), isNot(contains('…')));
    });

    test('超过上限 → 截到上限 + `…`', () {
      final String short = shortenEpisodeTitle(_vcbName);
      expect(short.runes.length, kEpisodeTitleMaxChars + 1, reason: '32 个字 + 一个省略号');
      expect(short, endsWith('…'));
      expect(short, startsWith('[hyakuhuyu&VCB-Studio] Re Zero'));
      expect(short, isNot(contains('1080p')), reason: '分辨率尾标在截断之外');
    });

    test('按码点截（增补平面汉字/emoji 不会被劈成半个）', () {
      final String s = '𠮷' * 40; // U+20BB7：一个码点两个 UTF-16 码元
      final String short = shortenEpisodeTitle(s, max: 5);
      expect(short.runes.length, 6);
      expect(short, '𠮷' * 5 + '…');
      expect(short.codeUnits.every((int u) => u != 0xFFFD), isTrue);
    });

    test('max <= 0 视为"不截"', () {
      expect(shortenEpisodeTitle(_vcbName, max: 0), _vcbName);
      expect(shortenEpisodeTitle(_vcbName, max: -1), _vcbName);
    });
  });

  group('行内排版', () {
    testWidgets('长标题被截断，集号仍然看得见（用户报的那个名字）', (tester) async {
      await _pump(
        tester,
        _group(<(String, int?)>[
          (_vcbName, 51),
          (_vcbName.replaceFirst('[51]', '[52]'), 52),
        ]),
      );

      // 标题是**截断后**的那一串（32 字 + …），不是原样的 120 字。
      final String shortened = shortenEpisodeTitle(_vcbName);
      // ⚠️ 两行的截断结果**本来就一样**：VCB 的集号在 78 字之后，32 字截断够不着它。
      // 这正是"集号必须单独占一槽"的理由 —— 光看标题分不出第几集（用户报的就是这个），
      // 而下面的断言证明集号那一槽把 51 / 52 都露出来了。
      expect(
        shortenEpisodeTitle(_vcbName),
        shortenEpisodeTitle(_vcbName.replaceFirst('[51]', '[52]')),
        reason: '集号在截断范围之外 ⇒ 标题列区分不出集号',
      );
      expect(find.text(shortened), findsNWidgets(2));
      expect(find.text(_vcbName), findsNothing, reason: '整串长标题不许原样上屏');

      // 集号就在行里（而且没有被标题挤掉）。
      expect(find.text('51'), findsOneWidget);
      expect(find.text('52'), findsOneWidget);
    });

    testWidgets('集号落在行的中间那一槽（左右两半等分）', (tester) async {
      await _pump(tester, _group(<(String, int?)>[(_vcbName, 51), ('短标题', 52)]));

      final Rect row = tester.getRect(find.byType(EpisodePanel));
      final Offset chip = tester.getCenter(find.text('51'));
      // 行内容区的中线（左右各 10 内边距）。
      final double middle = row.center.dx;
      expect(
        (chip.dx - middle).abs(),
        lessThan(24),
        reason: '集号应当落在行中间（左右两个 Expanded 1:1），实测偏移 ${(chip.dx - middle).abs()}',
      );
    });

    testWidgets('两行的集号在同一个 x 上（标题长短不影响集号位置）', (tester) async {
      await _pump(
        tester,
        _group(<(String, int?)>[
          (_vcbName, 51),
          ('[Group] Show - 52', 52),
        ]),
      );
      final double x51 = tester.getCenter(find.text('51')).dx;
      final double x52 = tester.getCenter(find.text('52')).dx;
      expect((x51 - x52).abs(), lessThan(0.5), reason: '集号列必须对齐，否则扫不下来');
    });

    testWidgets('短标题不截断、原样显示', (tester) async {
      await _pump(tester, _group(<(String, int?)>[(('[Group] Show - 03'), 3)]));
      expect(find.text('[Group] Show - 03'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('宿主没给集号 → 用下标兜底；给了就用真实集号', (tester) async {
      await _pump(
        tester,
        _group(<(String, int?)>[
          ('第一行没有集号', null), // 下标 0 → 显示 1
          ('第二行有集号', 77),
        ]),
      );
      expect(find.text('1'), findsOneWidget);
      expect(find.text('77'), findsOneWidget);
    });

    testWidgets('点非当前行 → 把那一项交回宿主；点当前行不触发', (tester) async {
      final List<MediaItem> picked = <MediaItem>[];
      await _pump(
        tester,
        _group(<(String, int?)>[
          ('[Group] Show - 01', 1),
          ('[Group] Show - 02', 2),
        ]),
        onSelect: picked.add,
      );

      await tester.tap(find.text('[Group] Show - 02'));
      expect(picked.single.episode, 2);

      await tester.tap(find.text('[Group] Show - 01')); // 当前行（currentIndex = 0）
      expect(picked, hasLength(1), reason: '当前集自己点自己不该再起播一次');
    });
  });
}
