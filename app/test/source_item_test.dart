/// 「这一条到底能不能下」的判据（2026-10-15 第三十轮回归测试）。
///
/// 用户报障原话：「集数里点第 4-6 集没反应，也没进队列下载，但是点后面其他几集都正常的。」
/// 根因不是"那几集坏了"，而是 [SourceItemView.hasTorrentSource] 原来**漏看 infoHash**：
/// mikan 番剧页/搜索页的行是 `infoHash: infoHashFromMagnet(magnet) ?? hash`
/// （`core/lib/sources/mikan.dart:818`），磁力没抽到、单集链接 hash 在的行就成了
/// 「有 infoHash、没 magnet」——core 侧 `isDownloadable`/`bestMagnet` 认这种条目
///（能拼出 `magnet:?xt=urn:btih:<hash>`，引擎下得动），界面却把它当"没源"：
/// 下载按钮禁用（点了毫无反馈）、整行只剩「无种子链接」、批量勾选也禁用。
library;

import 'package:dsanima/domain/batch_download.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/theme/tokens.dart';
import 'package:dsanima/ui/widgets/search_sections.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

SourceItemView _item({
  String id = 'mikan:abc',
  String? magnet,
  String? torrentUrl,
  String? infoHash,
  String? detailUrl,
}) =>
    SourceItemView(
      id: id,
      sourceId: 'mikan',
      title: '某番 第 04 话',
      detailUrl: detailUrl == null ? null : Uri.parse(detailUrl),
      magnet: magnet,
      torrentUrl: torrentUrl,
      infoHash: infoHash,
    );

void main() {
  group('hasTorrentSource：三种源都算数（与 core 的 isDownloadable 对齐）', () {
    test('只有 infoHash（磁力没抽到的 mikan 行）→ 可下', () {
      final SourceItemView item = _item(infoHash: 'a' * 40);
      expect(item.hasTorrentSource, isTrue,
          reason: 'core 的 bestMagnet 会用 infoHash 拼磁力，界面不能当它没源');
      // 界面上所有"能不能下"的门都走同一个谓词，一处修好三处生效。
      expect(canBatchDownload(item), isTrue, reason: '批量勾选也要跟着能勾');
    });

    test('只有 magnet → 可下', () {
      expect(_item(magnet: 'magnet:?xt=urn:btih:${'b' * 40}').hasTorrentSource, isTrue);
    });

    test('只有 .torrent 直链 → 可下', () {
      expect(
        _item(torrentUrl: 'https://example.test/a.torrent').hasTorrentSource,
        isTrue,
      );
    });

    test('只有详情页链接 → 不算"自带源"，但**点得动**（enqueueDownload 会先补链）', () {
      final SourceItemView item =
          _item(detailUrl: 'https://mikanani.me/Home/Episode/${'c' * 40}');
      expect(item.hasTorrentSource, isFalse, reason: '状态列不能说它"现在就带源"');
      expect(item.canDownload, isTrue, reason: '下载/播放会先 ensurePlayable 取磁力');
      expect(canBatchDownload(item), isTrue, reason: '批量勾选也要跟单条一致');
    });

    test('三者都没有、也没有详情页 → 不算可下：不骗用户', () {
      final SourceItemView item = _item();
      expect(item.hasTorrentSource, isFalse);
      expect(item.canDownload, isFalse);
      expect(canBatchDownload(item), isFalse);
    });

    test('空串不算数（字段给了但是空的）', () {
      expect(_item(magnet: '', torrentUrl: '', infoHash: '').hasTorrentSource, isFalse);
    });
  });

  testWidgets('搜索结果表：只有 infoHash 的行也算「可播」，播放键是强调色', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
        ],
        child: MaterialApp(
          theme: buildDsanimaTheme(),
          home: Scaffold(
            body: SearchResultsTable(
              items: <SourceItemView>[
                _item(id: 'hash-only', infoHash: 'd' * 40),
                _item(
                  id: 'detail-only',
                  detailUrl: 'https://mikanani.me/Home/Episode/${'e' * 40}',
                ),
                _item(id: 'bare'),
              ],
              engineConnected: true,
              onPlay: (SourceItemView _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final DsTokens t = DsTokens.whiteInk;
    expect(find.text('可播'), findsOneWidget, reason: 'infoHash 那条可播');
    expect(find.text('需补链'), findsOneWidget, reason: '只有详情页的那条：点得动，但要先补链');
    expect(find.text('无磁力链'), findsOneWidget, reason: '真的什么都没有的那条仍然如实报无源');
    expect(tester.widget<Text>(find.text('无磁力链')).style!.color, t.warning);

    final List<Icon> plays = tester.widgetList<Icon>(find.byIcon(Icons.play_arrow)).toList();
    expect(plays.length, 3);
    expect(plays[0].color, t.accent,
        reason: 'infoHash-only 的行必须可点（这就是"点了没反应"的回归点）');
    expect(plays[1].color, t.accent, reason: '需补链的行同样可点');
    expect(plays[2].color, t.text3, reason: '没有源的条目：播放键仍然禁用');
  });
}
