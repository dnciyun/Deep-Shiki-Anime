/// 「下载这个种子？」确认框的 widget 测试。
///
/// 用户 2026-10-20 的定稿：拖入种子后**先看清内容再决定下不下、下哪些**。
/// 这个框是"下错东西"的最后一道闸，所以逐条钉：
/// * 默认只勾视频与字幕（nfo/图片不默认下）；
/// * 勾掉的文件不进返回值（= 引擎 `onlyFiles` 的语义）；
/// * 全选返回 `null`（"全下"用引擎默认，不传一份没意义的全量清单）；
/// * 一个都不勾时「开始下载」是禁用的；
/// * 「取消」返回 null（= 什么都不做）。
library;

import 'package:dsanima/domain/torrent_file.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/ui/torrent_confirm_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

TorrentPreview _preview({int videoCount = 1, int extraFiles = 0}) {
  final List<TorrentFileEntryView> files = <TorrentFileEntryView>[
    for (int i = 0; i < videoCount; i++)
      TorrentFileEntryView(
        index: i,
        path: 'Show/Show - ${(i + 1).toString().padLeft(2, '0')}.mkv',
        sizeBytes: 1000,
        kind: TorrentEntryKind.video,
      ),
    TorrentFileEntryView(
      index: videoCount,
      path: 'Show/Show - 01.ass',
      sizeBytes: 10,
      kind: TorrentEntryKind.subtitle,
    ),
    for (int i = 0; i < extraFiles; i++)
      TorrentFileEntryView(
        index: videoCount + 1 + i,
        path: 'Show/extra-$i.nfo',
        sizeBytes: 1,
        kind: TorrentEntryKind.other,
      ),
  ];
  return TorrentPreview(
    name: 'Show',
    files: files,
    trackers: const <String>['udp://tracker.example:80/announce'],
    infoHashHex: 'a' * 40,
  );
}

void _sizeUp(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('默认只勾视频与字幕；点「开始下载」只下这两类（序号清单）', (WidgetTester tester) async {
    _sizeUp(tester);
    final TorrentPreview preview = _preview(videoCount: 1, extraFiles: 2);
    TorrentConfirmChoice? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDsanimaTheme(),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showTorrentConfirmDialog(context, preview: preview);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(dsTorrentConfirmKey), findsOneWidget);
    expect(find.text('Show'), findsOneWidget);
    expect(find.text('4 个文件'), findsOneWidget);
    // nfo 默认不勾（收起时前 3 条里就有它：第 3 条 = 序号 2）。
    final Checkbox nfo = tester.widget<Checkbox>(
      find.descendant(of: find.byKey(dsTorrentFileKey(2)), matching: find.byType(Checkbox)),
    );
    expect(nfo.value, isFalse, reason: 'nfo 默认不下载');
    final Checkbox video = tester.widget<Checkbox>(
      find.descendant(of: find.byKey(dsTorrentFileKey(0)), matching: find.byType(Checkbox)),
    );
    expect(video.value, isTrue);

    // 默认勾选 = 2/4（视频 + 字幕）→ 返回的是这两个序号（不是 null）。
    await tester.tap(find.byKey(dsTorrentStartKey));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.onlyFiles, <int>[0, 1]);
  });

  testWidgets('全选 → 返回 onlyFiles: null（= 全下，交给引擎默认）', (WidgetTester tester) async {
    _sizeUp(tester);
    final TorrentPreview preview = _preview(videoCount: 2, extraFiles: 2);
    TorrentConfirmChoice? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDsanimaTheme(),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showTorrentConfirmDialog(context, preview: preview);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(dsTorrentSelectAllKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(dsTorrentStartKey));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.onlyFiles, isNull, reason: '全下应该用 null（引擎默认），不是一份全量清单');
  });

  testWidgets('一个都不勾：「开始下载」禁用；取消返回 null', (WidgetTester tester) async {
    _sizeUp(tester);
    final TorrentPreview preview = _preview(videoCount: 1);
    TorrentConfirmChoice? result = (onlyFiles: const <int>[99]);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDsanimaTheme(),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showTorrentConfirmDialog(context, preview: preview);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 点掉视频与字幕。
    await tester.tap(find.byKey(dsTorrentFileKey(0)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(dsTorrentFileKey(1)));
    await tester.pumpAndSettle();

    final FilledButton start = tester.widget<FilledButton>(find.byKey(dsTorrentStartKey));
    expect(start.onPressed, isNull, reason: '什么都没选就不该能点「开始下载」');

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull, reason: '取消 = 什么都不做');
  });

  testWidgets('文件多时默认收起，点「展开全部」看得到剩下的', (WidgetTester tester) async {
    _sizeUp(tester);
    final TorrentPreview preview = _preview(videoCount: 6);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDsanimaTheme(),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showTorrentConfirmDialog(context, preview: preview),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(dsTorrentFileKey(0)), findsOneWidget);
    expect(find.byKey(dsTorrentFileKey(5)), findsNothing, reason: '收起时只露前 3 条');
    expect(find.text('展开全部 7 个文件'), findsOneWidget);

    await tester.tap(find.byKey(dsTorrentExpandKey));
    await tester.pumpAndSettle();
    expect(find.byKey(dsTorrentFileKey(5)), findsOneWidget);
    expect(find.text('收起'), findsOneWidget);
  });
}
