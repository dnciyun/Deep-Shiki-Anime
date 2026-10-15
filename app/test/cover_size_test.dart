/// 「bangumi 的封面很糊」+ 「封面加载不出来」两个回归钉（第二十 / 二十一轮）。
///
/// 第二十轮：代码一直拿 `images.grid`（100px / 老接口 48px）当封面，放到 208pt 的海报卡上
/// 放大好几倍。修法 = 封面控件按**自己实际的显示宽度 × 屏幕缩放**去图床上抬档。
/// 第二十一轮：抬档不能无脑插 `/r/<宽>/` —— 只有 `/pic/cover/l/…`（原图）那一份能被缩放，
/// `/r/400/pic/cover/g/…` 真机是 **HTTP 400**，于是「已完成」页的封面全挂了。
///
/// 这个文件只测"控件到底请求了哪个 URL、失败后有没有兜底"：**不联网**
/// （假缓存端口把 URL 记下来；顺带给一个真的 1×1 PNG 让 Image 有东西可显示）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima/domain/bangumi.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/state/infra.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/ui/widgets/cover.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 1×1 透明 PNG（真能解码：用来确认兜底拿到的文件真的被拿去显示了）。
const String kOnePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

/// 记下请求过的 URL，并一律返回同一个真实文件（不触发兜底那次重试）。
class _RecordingCoverCache implements CoverCachePort {
  _RecordingCoverCache(this.file, {this.syncFile, this.syncUrls});

  final File file;

  /// 给 `cachedNow` 用的"内存索引里那张"（第三十七轮）。默认 null = 与以前一样走异步路。
  final File? syncFile;

  /// 只有**包含**这些片段的 URL 算"索引里有"（null = 任何 URL 都算有）—— 用来钉
  /// "换成另一部番时不许拿上一张顶着"。
  ///
  /// ⚠️ 比的是**取档之后**的 URL（`DsCover` 会先按显示尺寸把 `/r/100/` 抬成 `/r/200|400/`），
  /// 所以这里用"文件名里的那串 id"当判据，不要拿原始 URL 整串比。
  final Set<String>? syncUrls;
  final List<String> requested = <String>[];

  /// `cachedNow` 被问过哪些 URL（用来钉"没有 URL 时连索引都不问"）。
  final List<String> syncAsked = <String>[];

  @override
  Future<File?> fileFor(String url, {String? referer}) async {
    requested.add(url);
    return file;
  }

  @override
  File? cachedNow(String url) {
    syncAsked.add(url);
    final File? ready = syncFile;
    if (ready == null) return null;
    final Set<String>? only = syncUrls;
    if (only != null && !only.any((String part) => url.contains(part))) return null;
    return ready;
  }
}

/// 模拟「抬档后的 URL 下不到」：带 `/r/` 的一律失败，原始 URL 才给文件。
class _UpgradeFailsCache implements CoverCachePort {
  _UpgradeFailsCache(this.file);

  final File file;
  final List<String> requested = <String>[];

  @override
  Future<File?> fileFor(String url, {String? referer}) async {
    requested.add(url);
    return url.contains('/r/') ? null : file;
  }

  @override
  File? cachedNow(String url) => null;
}

const String _grid =
    'https://lain.bgm.tv/r/100/pic/cover/l/8a/b2/312427_D2ZNm.jpg';

const String _mikan =
    'https://mikanani.me/images/Bangumi/202610/abc.jpg?format=webp';

/// 老式 URL（旧搜索接口 `/search/subject/{q}`，也就是「已完成」页封面走的那条路）。
const String _oldGrid = 'http://lain.bgm.tv/pic/cover/g/af/7e/656083_B22Yt.jpg';

/// mikan 首页真实的 `data-src`（2026-10-15 抓，带 `height` 会被图床裁成正方形）。
const String kRealMikanSquareCover =
    'https://mikanani.me/images/Bangumi/202603/712cede8.jpg'
    '?width=400&height=400&format=webp';

Widget _harness({
  required CoverCachePort cache,
  required double width,
  required double height,
  String? url,
  int? tierDevicePixels,
}) =>
    ProviderScope(
      overrides: [coverCacheProvider.overrideWithValue(cache)],
      child: MaterialApp(
        theme: buildDsanimaTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              height: height,
              child: DsCover(
                url: url,
                referer: bangumiCoverReferer,
                tierDevicePixels: tierDevicePixels,
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  late Directory tmp;
  late File png;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dsanima_cover_size_');
    png = File(p.join(tmp.path, 'one.png'))
      ..writeAsBytesSync(base64Decode(kOnePixelPngBase64));
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 装上控件（默认按用户那台机器的缩放 1.25），返回记录器。
  Future<_RecordingCoverCache> pumpCover(
    WidgetTester tester, {
    required double width,
    required double height,
    double dpr = 1.25,
    String? url = _grid,
  }) async {
    tester.view.devicePixelRatio = dpr;
    tester.view.physicalSize = const Size(1200, 1200);
    addTearDown(tester.view.reset);
    final _RecordingCoverCache cache = _RecordingCoverCache(png);
    await tester.pumpWidget(_harness(cache: cache, width: width, height: height, url: url));
    await tester.pumpAndSettle();
    return cache;
  }

  testWidgets('排期海报卡（208pt @1.25 = 260px）取 400 那一档，不再是 100px 的小图',
      (WidgetTester tester) async {
    final _RecordingCoverCache cache =
        await pumpCover(tester, width: 208, height: 208);

    expect(cache.requested, hasLength(1));
    expect(cache.requested.single, contains('/r/400/pic/cover/l/'),
        reason: '260 设备像素抬到 400 档（实测只有 100/200/400/800 可用）');
  });

  testWidgets('今日推荐卡（148pt × 1.25 = 185）取 200 那一档', (WidgetTester tester) async {
    final _RecordingCoverCache cache =
        await pumpCover(tester, width: 148, height: 197);
    expect(cache.requested.single, contains('/r/200/pic/cover/l/'));
  });

  testWidgets('40pt 的封面选择缩略图仍然只用 100 档（省流量、缓存也不白下）',
      (WidgetTester tester) async {
    final _RecordingCoverCache cache =
        await pumpCover(tester, width: 40, height: 56);
    expect(cache.requested.single, _grid, reason: '50 设备像素 → 100 档，URL 与原来一模一样');
  });

  testWidgets('屏幕缩放翻倍（2.0）时同一张卡会升一档 —— 糊不糊要跟着缩放走',
      (WidgetTester tester) async {
    final _RecordingCoverCache cache =
        await pumpCover(tester, width: 148, height: 197, dpr: 2.0);
    expect(cache.requested.single, contains('/r/400/pic/cover/l/'),
        reason: '148 × 2 = 296 → 400 档');
  });

  testWidgets('卡片变大时就地升档（不是只在初始化时算一次）', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.25;
    tester.view.physicalSize = const Size(1200, 1200);
    addTearDown(tester.view.reset);
    final _RecordingCoverCache cache = _RecordingCoverCache(png);

    await tester.pumpWidget(_harness(cache: cache, width: 40, height: 56, url: _grid));
    await tester.pumpAndSettle();
    expect(cache.requested.single, _grid);

    await tester.pumpWidget(_harness(cache: cache, width: 208, height: 208, url: _grid));
    await tester.pumpAndSettle();
    expect(cache.requested, hasLength(2));
    expect(cache.requested.last, contains('/r/400/pic/cover/l/'),
        reason: '同一张封面换个更大的位置，必须跟着换更大的图');
  });

  testWidgets('mikan 那种非 Bangumi 封面：URL 一个字都不改', (WidgetTester tester) async {
    final _RecordingCoverCache cache =
        await pumpCover(tester, width: 208, height: 208, url: _mikan);
    expect(cache.requested.single, _mikan);
  });

  // ⚠️ 第三十一轮（用户 2026-10-15：「今日更新的封面图还是显示不全」）：
  // 站点给的 `data-src` 带 `height=400`，图床会按正方形裁剪（原图 1429×2000 → 400×400）。
  // 控件必须把 height 去掉 —— 光把显示框改成竖版是没用的，图本身已经被裁了。
  testWidgets('mikan 排期封面：请求里不许再带 height（否则图床裁成正方形）',
      (WidgetTester tester) async {
    final _RecordingCoverCache cache = await pumpCover(tester,
        width: 208, height: 208, url: kRealMikanSquareCover);

    expect(cache.requested.single, isNot(contains('height=')),
        reason: '带 height 就是被裁成 400×400 的那张方图');
    expect(cache.requested.single,
        'https://mikanani.me/images/Bangumi/202603/712cede8.jpg?width=400&format=webp',
        reason: '208pt × 1.25 = 260 设备像素 → 400 档，其余参数照旧');
  });

  testWidgets('固定海报槽的新形状：去掉 height 之后同一天只下一次（不会来回抖动）',
      (WidgetTester tester) async {
    final _RecordingCoverCache cache = await pumpCover(tester,
        width: 208, height: 295, url: kRealMikanSquareCover);
    // 重新布局一次（同一个 URL）不该再发一次请求。
    await tester.pumpWidget(_harness(
      cache: cache,
      width: 208,
      height: 295,
      url: kRealMikanSquareCover,
    ));
    await tester.pumpAndSettle();
    expect(cache.requested, hasLength(1));
  });

  testWidgets('老式 URL（旧搜索接口 /pic/cover/g/）也要抬到 l 那一档', (WidgetTester tester) async {
    final _RecordingCoverCache cache =
        await pumpCover(tester, width: 208, height: 208, url: _oldGrid);
    expect(cache.requested.single,
        'http://lain.bgm.tv/r/400/pic/cover/l/af/7e/656083_B22Yt.jpg');
  });

  // ⚠️ 第二十一轮的兜底钉：抬档后的 URL 拿不到时，必须退回原始 URL ——
  // 「已完成」页的封面就是这么被上一版弄挂的（400 → null → 满屏「无封面」）。
  testWidgets('抬档后的 URL 下不到 → 退回原始 URL 并照旧显示（绝不再变「加载不出来」）',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.25;
    tester.view.physicalSize = const Size(1200, 1200);
    addTearDown(tester.view.reset);
    final _UpgradeFailsCache cache = _UpgradeFailsCache(png);

    await tester.pumpWidget(_harness(cache: cache, width: 208, height: 208, url: _oldGrid));
    await tester.pumpAndSettle();

    expect(cache.requested, hasLength(2));
    expect(cache.requested.first,
        'http://lain.bgm.tv/r/400/pic/cover/l/af/7e/656083_B22Yt.jpg');
    expect(cache.requested.last, _oldGrid, reason: '抬档失败 → 退回原始 URL');
    expect(find.byType(Image), findsOneWidget, reason: '兜底拿到的文件必须真的显示出来');
  });

  testWidgets('没有封面（null / 空串）→ 一次都不去请求', (WidgetTester tester) async {
    final _RecordingCoverCache cache =
        await pumpCover(tester, width: 208, height: 208, url: null);
    expect(cache.requested, isEmpty);
    expect(find.text('无封面'), findsOneWidget);
  });

  // ⚠️ 第三十三轮（用户：「轮播切换时会闪烁」）：轮播里同一张卡的宽度在 320ms 里
  // 从邻卡 264 连续长到主卡 552。若取档跟着"自己此刻多宽"走，中途会跳一档
  // （400 → 800）= 换 URL = 重新查缓存 + 重新解码，中间空一帧 —— 那一帧就是"闪"。
  // 所以 [DsCover.tierDevicePixels] 允许把取档钉在**这一段动画里唯一不变的尺寸**（主卡宽）上。
  testWidgets('钉住取档：给了 tierDevicePixels 就与自己的宽度无关（邻卡宽也取主卡那一档）',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 1200);
    addTearDown(tester.view.reset);
    final _RecordingCoverCache cache = _RecordingCoverCache(png);
    await tester.pumpWidget(_harness(
      cache: cache,
      width: 264, // 它此刻是邻卡那么宽
      height: 283,
      url: _grid,
      tierDevicePixels: 690, // …但取档按主卡宽（552 × 1.25）算
    ));
    await tester.pumpAndSettle();
    expect(cache.requested.single, contains('/r/800/pic/cover/l/'),
        reason: '没有这一条，邻卡会取 400 档，长大过半时又去取 800 档 = 闪一下');
  });

  testWidgets('钉住取档：宽度一路长大只取一次档（不钉就会取两次）', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 1200);
    addTearDown(tester.view.reset);
    // 轮播那 320ms 的真实宽度序列（横版·中：邻卡 264 → 主卡 552）。
    const List<double> widths = <double>[264, 300, 344, 408, 464, 520, 552];

    final _RecordingCoverCache pinned = _RecordingCoverCache(png);
    for (final double w in widths) {
      await tester.pumpWidget(_harness(
        cache: pinned,
        width: w,
        height: 283,
        url: _grid,
        tierDevicePixels: 690,
      ));
      await tester.pumpAndSettle();
    }
    expect(pinned.requested, hasLength(1), reason: '钉住 → 整段切换 URL 一个字节都不变');

    final _RecordingCoverCache loose = _RecordingCoverCache(png);
    for (final double w in widths) {
      await tester.pumpWidget(
        _harness(cache: loose, width: w, height: 283, url: _grid),
      );
      await tester.pumpAndSettle();
    }
    expect(loose.requested.map((String u) => u.contains('/r/400/') ? '400' : '800'),
        <String>['400', '800'],
        reason: '不钉就是这样：264/300/344 → 400 档，408 起 → 800 档，'
            '中途换一次档 = 换 URL = 重新解码，中间空一帧');
  });

  // ⚠️ 第三十七轮（用户 2026-10-16：「动漫库的封面图保存缓存，不然每次都要加载」）：
  //    封面**本来就在盘上**（缓存是落盘的），但每次显示都要过一次 `await`（磁盘探测 →
  //    下一帧才拿到 File），于是每张卡、每次进页面/滚动回来都会先空一帧灰底。
  //    [CoverCachePort.cachedNow] 是同步的内存索引：命中就**当帧**直接画。
  group('缓存同步命中（第三十七轮）：命中就第一帧直接画', () {
    testWidgets('索引里有这张图 ⇒ 第一帧就有 Image，而且一次 fileFor 都没发',
        (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.25;
      tester.view.physicalSize = const Size(1200, 1200);
      addTearDown(tester.view.reset);
      final _RecordingCoverCache cache =
          _RecordingCoverCache(png, syncFile: png);

      // ⚠️ **只 pump 一帧**，不 settle：要看的正是"第一帧有没有图"。
      await tester.pumpWidget(
          _harness(cache: cache, width: 208, height: 208, url: _grid));
      expect(find.byType(Image), findsOneWidget,
          reason: '缓存命中 ⇒ 当帧 `Image.file` 就在树上（以前要等一次 await 才有）');
      expect(find.text('无封面'), findsNothing);
      expect(cache.requested, isEmpty,
          reason: '同步命中不该再去走 `fileFor` 那条异步路（那正是"每次都要加载"的来源）');
    });

    testWidgets('索引里没有 ⇒ 与以前完全一样：第一帧还没有图，settle 之后才出图',
        (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.25;
      tester.view.physicalSize = const Size(1200, 1200);
      addTearDown(tester.view.reset);
      final _RecordingCoverCache cache = _RecordingCoverCache(png); // syncFile 为 null

      await tester.pumpWidget(
          _harness(cache: cache, width: 208, height: 208, url: _grid));
      expect(find.byType(Image), findsNothing, reason: '第一帧还在等异步那条路');
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(cache.requested, hasLength(1));
    });

    testWidgets('同步命中只认**当前这个 URL**：换成另一部番的那一帧不许拿上一张顶着',
        (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 1200);
      addTearDown(tester.view.reset);
      const String other = 'https://lain.bgm.tv/r/400/pic/cover/l/ff/ff/999999_zzzz.jpg';
      final _RecordingCoverCache cache = _RecordingCoverCache(
        png,
        syncFile: png,
        syncUrls: <String>{'312427'}, // 只有第一张（`_grid`）在索引里
      );

      await tester.pumpWidget(_harness(cache: cache, width: 208, height: 208, url: _grid));
      expect(find.byType(Image), findsOneWidget);

      // 换成另一部番：索引里没有它 ⇒ 走异步路，而且**不许**复用上一张顶着。
      await tester.pumpWidget(_harness(cache: cache, width: 208, height: 208, url: other));
      expect(find.byType(Image), findsNothing,
          reason: '换了一部番就必须重新占位，不能拿上一部的图冒充（第三十三轮的规矩）');
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget, reason: '异步路拿到新图之后照旧显示');
      expect(cache.syncAsked.any((String u) => u.contains('999999')), isTrue,
          reason: '新的这一张也问过同步索引（只是没命中）');
    });

    testWidgets('角色头像（/pic/crt/）同样抬档，也走同一条同步命中', (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.25;
      tester.view.physicalSize = const Size(1200, 1200);
      addTearDown(tester.view.reset);
      const String crt = 'https://lain.bgm.tv/pic/crt/l/b5/b6/86246_crt_L0Zmt.jpg';
      final _RecordingCoverCache cache = _RecordingCoverCache(png, syncFile: png);

      await tester.pumpWidget(_harness(cache: cache, width: 112, height: 112, url: crt));
      expect(find.byType(Image), findsOneWidget);
      expect(cache.requested, isEmpty, reason: '同步命中');
    });

    testWidgets('没有头像（null / 空串）⇒ 连同步那条路都不问', (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.25;
      tester.view.physicalSize = const Size(1200, 1200);
      addTearDown(tester.view.reset);
      final _RecordingCoverCache cache = _RecordingCoverCache(png, syncFile: png);

      await tester.pumpWidget(_harness(cache: cache, width: 112, height: 112, url: null));
      expect(find.byType(Image), findsNothing);
      // 空 URL 时 `_load` 连缓存都不问、future 立刻回 null ⇒ 占位文案要 settle 之后才在
      //（第一帧是 `FutureBuilder` 的等待态）。
      await tester.pumpAndSettle();
      expect(find.text('无封面'), findsOneWidget);
      expect(cache.requested, isEmpty);
      expect(cache.syncAsked, isEmpty, reason: '没有 URL 连同步索引都不该问');
    });
  });
}
