/// 1.1.0 M1/T5「封面按显示尺寸解码」的回归钉。
///
/// 用户 2026-10-17 定的 1.1.0 方向：数据性能「D 全都要」，其中 C = 启动与内存
/// （`docs/specs/2026-10-17-dsanima-1.1.0-plan.md` 的 T5）。
///
/// 这一版之前 `cover.dart` 的 `_image` 是 `Image.file` **不带 `cacheWidth`**：
/// 盘上那张封面多大，就整张解进 ImageCache 多大。可盘上的图是按 URL 档下好的
/// （Bangumi `/r/100|200|400|800/`、mikan `?width=200|400|800`），而卡片只需要
/// 「逻辑宽 × devicePixelRatio」那么多 —— 一屏几十张，多出来的解码位图全是白占内存。
///
/// 这里钉四件事（数字优先，全部是真解码 / 真 ImageCache，不 mock）：
/// 1. 档位换算：120×dpr2=240 → 256 档；120×dpr1 → 128 档；700×dpr2=1400 → 封顶 768；
/// 2. 高 DPI 不退化：解码宽 ≥ 显示物理宽（ResizeImage.width 断言）；
/// 3. 小图不上采样：120×170 的图在 384 档下仍然只解成 120×170；
/// 4. 省内存有数字：铺 8 张封面，对比 `ImageCache.currentSizeBytes` 改前/改后。
///
/// 不联网：`CoverCachePort` 注入假实现，只把本地文件交出去。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsanima/domain/bangumi.dart' show bangumiCoverReferer;
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/state/infra.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/ui/widgets/cover.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 真封面 fixture：仓库里现有的 400×400 WebP（mikan 那种被图床裁成正方形的封面）与
/// 120×170 JPEG（缩略图，用来钉"小图不上采样"）。
const String _fixture400 = 'test/fixtures/cover_3887.webp';
const String _fixtureThumb = 'test/fixtures/cover_frieren_thumb.jpg';

/// 一次一张地把文件交出去（`cachedNow` 一律 null = 走异步路，与本轮之前一样）。
///
/// 每个 `DsCover` 拿到的文件不同 ⇒ ImageCache 里是 N 个不同的解码条目，
/// `currentSizeBytes` 才能代表"一屏 N 张封面"。
class _FileListCoverCache implements CoverCachePort {
  _FileListCoverCache(this.files);

  final List<File> files;
  int _next = 0;

  @override
  Future<File?> fileFor(String url, {String? referer}) async {
    if (files.isEmpty) return null;
    final File file = files[_next % files.length];
    _next++;
    return file;
  }

  @override
  File? cachedNow(String url) => null;
}

Widget _coverHarness({
  required CoverCachePort cache,
  required double width,
  required double height,
  String? url = _gridUrl,
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

/// 铺 N 张 DsCover（同一个网格里，宽度都一样 —— 与首页网格/动漫库的真实排布一致）。
Widget _gridHarness({
  required CoverCachePort cache,
  required int count,
  required double cell,
}) =>
    ProviderScope(
      overrides: [coverCacheProvider.overrideWithValue(cache)],
      child: MaterialApp(
        theme: buildDsanimaTheme(),
        home: Scaffold(
          body: Wrap(
            children: <Widget>[
              for (int i = 0; i < count; i++)
                SizedBox(
                  width: cell,
                  height: cell,
                  child: DsCover(url: _gridUrlAt(i), referer: bangumiCoverReferer),
                ),
            ],
          ),
        ),
      ),
    );

/// 改前那套写法：`Image.file` 不带 `cacheWidth`（就是本轮的 `_image` 去掉新参数）。
Widget _oldImageGridHarness(List<File> files, {double cell = 208}) => MaterialApp(
      theme: buildDsanimaTheme(),
      home: Scaffold(
        body: Wrap(
          children: <Widget>[
            for (final File file in files)
              SizedBox(
                width: cell,
                height: cell,
                child: Image.file(
                  file,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  gaplessPlayback: true,
                ),
              ),
          ],
        ),
      ),
    );

const String _gridUrl =
    'https://lain.bgm.tv/r/100/pic/cover/l/8a/b2/312427_D2ZNm.jpg';

String _gridUrlAt(int i) =>
    'https://lain.bgm.tv/r/100/pic/cover/l/8a/b2/${312427 + i}_D2ZNm.jpg';

/// 等真实解码落地：`flutter test` 的假时钟里，文件 IO / 引擎解码要 `runAsync` 才跑得动。
///
/// 只等到 `done()` 为真，最多 ~5 秒（100 × 50ms）；等不到就直接红（宁可红，也别拿 0 当证据）。
Future<void> _waitFor(WidgetTester tester, bool Function() done, String what) async {
  for (int i = 0; i < 100; i++) {
    if (done()) return;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  fail('等不到$what（ImageCache.currentSizeBytes = ${imageCache.currentSizeBytes}）');
}

/// 把 `DsCover` 里那个 `Image` 的解码 provider 取出来（断言档位 / 上采样开关）。
ResizeImage _resizeProviderOf(WidgetTester tester) {
  final Image image = tester.widget<Image>(find.byType(Image));
  expect(image.image, isA<ResizeImage>(),
      reason: '带 cacheWidth 的 Image.file 内部一定是 ResizeImage');
  return image.image as ResizeImage;
}

/// 真解码一个 provider（不靠 widget 的 ImageStream，直接要 ImageInfo）——用来量
/// 「这个档位最终解出来是多少像素」。返回的图由 ImageCache 持有，测试结束不管它。
///
/// ⚠️ 不能把「addListener 然后 await」整段塞进 `runAsync`：引擎解码的回调要靠 pump
/// 推进，塞进 runAsync 里等就死锁了（实测这个用例 90s 都回不来）。正确姿势同 [_waitFor]：
/// 交替「让真实异步跑一会儿」+ pump，等监听器自己拿到图。
Future<ui.Image> _decode(WidgetTester tester, ImageProvider<Object> provider) async {
  final ImageStream stream = provider.resolve(ImageConfiguration.empty);
  final Completer<ImageInfo> completer = Completer<ImageInfo>();
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (ImageInfo info, bool synchronousCall) {
      if (!completer.isCompleted) completer.complete(info);
    },
    onError: (Object error, StackTrace? stack) {
      if (!completer.isCompleted) completer.completeError(error, stack);
    },
  );
  stream.addListener(listener);
  for (int i = 0; i < 100 && !completer.isCompleted; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
  expect(completer.isCompleted, isTrue, reason: '解码失败：5 秒内拿不到 ImageInfo');
  final ImageInfo info = await completer.future;
  stream.removeListener(listener);
  return info.image;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dsanima_cover_decode_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 把照片 fixture 复制成 N 个**不同路径**的文件（FileImage 的缓存 key 含路径）。
  List<File> copyFixture(String fixture, int count) => <File>[
        for (int i = 0; i < count; i++)
          File(p.join(tmp.path, 'cover_$i${p.extension(fixture)}'))
            ..writeAsBytesSync(File(fixture).readAsBytesSync()),
      ];

  group('档位换算：snapCoverDecodeWidth（逻辑宽 × dpr → 解码档）', () {
    test('锚点：120×2=240→256；120×1=120→128；208×1.25=260→320；700×2=1400→1408', () {
      expect(snapCoverDecodeWidth(120 * 2), 256, reason: '逻辑 120 @ dpr 2 = 240 设备像素');
      expect(snapCoverDecodeWidth(120 * 1), 128, reason: '逻辑 120 @ dpr 1 = 120 设备像素');
      // ⚠️ 这条是本机最常见的那张卡：128 台阶会抬到 384（只省 7.8%），64 台阶抬到 320。
      expect(snapCoverDecodeWidth((208 * 1.25).ceil()), 320, reason: '208pt @ 125% = 260');
      expect(snapCoverDecodeWidth(700 * 2), 1408, reason: '1400 → 64 的整数倍 = 1408（未到 1536 上限）');
    });

    test('台阶表：64 的整数倍、128 起步、1536 封顶（含边界）', () {
      const Map<int, int> table = <int, int>{
        0: 0, // 尺寸还没算出来 → 不缩放（旧行为）
        -1: 0,
        1: 128,
        50: 128,
        127: 128,
        128: 128,
        129: 192, // 只差 1 像素也要升档，否则 129 屏的物理宽就比图宽
        185: 192,
        215: 256,
        240: 256,
        256: 256,
        257: 320,
        260: 320, // 208pt × 1.25（本机缩放）—— 128 台阶时这里是 384，多 48% 像素
        312: 320,
        320: 320,
        321: 384,
        384: 384,
        385: 448,
        416: 448,
        512: 512,
        513: 576,
        690: 704, // 552pt 轮播主卡 × 1.25
        768: 768,
        769: 832,
        1104: 1152, // 552pt @ dpr 2：第一版封 768 时会比旧行为更糊，现在不封了
        1536: 1536,
        1537: 1536, // 超过上限 ⇒ 按上限
      };
      table.forEach((int devicePixels, int want) {
        expect(snapCoverDecodeWidth(devicePixels), want,
            reason: '$devicePixels 设备像素应落到 $want 档');
      });
    });

    test('档位表本身：128 起步、64 台阶、1536 封顶（改表就会改变内存/清晰度的取舍）', () {
      expect(coverDecodeWidths.first, 128);
      expect(coverDecodeWidths.last, 1536);
      expect(coverDecodeWidths.length, (1536 - 128) ~/ 64 + 1);
      for (final int width in coverDecodeWidths) {
        expect(width % 64, 0, reason: '$width 必须是 64 的整数倍');
        expect(snapCoverDecodeWidth(width), width, reason: '档位自己再取一次还是它');
      }
    });
  });

  group('widget：Image.file 真的按档位解码', () {
    testWidgets('208pt @1.25 = 260 设备像素 → cacheWidth 320，且 filterQuality/gapless 不变',
        (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.25;
      tester.view.physicalSize = const Size(1600, 1200);
      addTearDown(tester.view.reset);
      final _FileListCoverCache cache = _FileListCoverCache(
        <File>[File(_fixture400)],
      );

      await tester.pumpWidget(
          _coverHarness(cache: cache, width: 208, height: 208));
      await tester.pumpAndSettle();

      final ResizeImage provider = _resizeProviderOf(tester);
      expect(provider.width, 320, reason: '208 × 1.25 = 260 → 不小于 260 的最小 64 倍数 = 320');
      expect(provider.height, isNull, reason: '只按宽度定档，高度按原图比例跟着走');
      expect(provider.allowUpscaling, isFalse, reason: '小图不许上采样（ResizeImage 的默认语义）');

      final Image image = tester.widget<Image>(find.byType(Image));
      expect(image.gaplessPlayback, isTrue, reason: '第三十三轮的防闪烁行为不变');
      expect(image.filterQuality, FilterQuality.medium,
          reason: 'filterQuality 一个字节都不动（没传就是 medium）');
    });

    testWidgets('高 DPI 不退化：dpr 2 / 3 下解码宽 ≥ 显示物理宽', (WidgetTester tester) async {
      // (逻辑宽, dpr, 期望档位) —— 期望档位必须 ≥ 逻辑宽 × dpr。
      const List<(double, double, int)> cases = <(double, double, int)>[
        (148, 2.0, 320), // 296 → 320
        (208, 2.0, 448), // 416 → 448
        (128, 3.0, 384), // 384 → 384（正好压线）
        (552, 1.25, 704), // 690 → 704（轮播主卡 @125%）
        (552, 2.0, 1152), // 1104 → 1152（轮播主卡 @200%；第一版封 768 时这里会糊）
      ];
      for (final (double logical, double dpr, int want) in cases) {
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = const Size(2000, 1600);
        addTearDown(tester.view.reset);
        final _FileListCoverCache cache = _FileListCoverCache(<File>[File(_fixture400)]);
        await tester.pumpWidget(
            _coverHarness(cache: cache, width: logical, height: logical));
        await tester.pumpAndSettle();

        final int physical = (logical * dpr).ceil();
        final ResizeImage provider = _resizeProviderOf(tester);
        expect(provider.width, want,
            reason: '$logical pt @ dpr $dpr = $physical 设备像素 → $want 档');
        expect(provider.width! >= physical, isTrue,
            reason: '解码宽 ${provider.width} 必须 ≥ 显示物理宽 $physical，否则高 DPI 会变糊');
      }
    });

    testWidgets('小图不上采样：120×170 的缩略图在 320 档下仍然解成 120×170',
        (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.25;
      tester.view.physicalSize = const Size(1600, 1200);
      addTearDown(tester.view.reset);
      final _FileListCoverCache cache =
          _FileListCoverCache(<File>[File(_fixtureThumb)]);

      await tester.pumpWidget(
          _coverHarness(cache: cache, width: 208, height: 295));
      await tester.pumpAndSettle();

      final ResizeImage provider = _resizeProviderOf(tester);
      expect(provider.width, 320, reason: '208 × 1.25 = 260 → 320 档');
      final ui.Image decoded = await _decode(tester, provider);
      expect(decoded.width, 120,
          reason: '文件本来只有 120 宽：allowUpscaling=false ⇒ 不许拉成 320（会糊）');
      expect(decoded.height, 170);
    });

    testWidgets('卡片变大、URL 档不变时解码档也要跟着升（256 → 320）',
        (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.25;
      tester.view.physicalSize = const Size(1600, 1200);
      addTearDown(tester.view.reset);
      final _FileListCoverCache cache = _FileListCoverCache(<File>[File(_fixture400)]);

      // 172pt × 1.25 = 215 → 256 档；URL 是 400 档。
      await tester.pumpWidget(_coverHarness(cache: cache, width: 172, height: 172));
      await tester.pumpAndSettle();
      expect(_resizeProviderOf(tester).width, 256);

      // 208pt × 1.25 = 260 → 320 档；URL **还是** 400 档（400 覆盖 215..400）。
      await tester.pumpWidget(_coverHarness(cache: cache, width: 208, height: 208));
      await tester.pumpAndSettle();
      expect(_resizeProviderOf(tester).width, 320,
          reason: 'URL key 没变也要按新的显示宽度重新解码，否则大卡一直糊着');
    });

    testWidgets('钉住取档（轮播）：tierDevicePixels 同时钉住 URL 与解码宽度',
        (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1600, 1200);
      addTearDown(tester.view.reset);
      final _FileListCoverCache cache = _FileListCoverCache(<File>[File(_fixture400)]);

      await tester.pumpWidget(_coverHarness(
        cache: cache,
        width: 264, // 此刻是邻卡宽 → 单独算会是 320 档（264 → 320）
        height: 283,
        tierDevicePixels: 690, // 主卡宽 552 × 1.25 → 704 档
      ));
      await tester.pumpAndSettle();

      expect(_resizeProviderOf(tester).width, 704,
          reason: '整段切换动画里 URL 与解码宽度都不许跳档，否则还是会重新解码闪一下');
    });
  });

  group('省内存：铺 8 张封面，ImageCache.currentSizeBytes 改前 vs 改后', () {
    testWidgets('8 张 400×400 封面：208pt 卡（320 档）与 172pt 卡（256 档）两种排布',
        (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.25;
      tester.view.physicalSize = const Size(1600, 1600);
      addTearDown(tester.view.reset);

      final List<File> files = copyFixture(_fixture400, 8);

      // 清场：前面几个用例真解码过多张图，不清掉会把它们的字节算进"改前"。
      imageCache
        ..clear()
        ..clearLiveImages();

      // ── 改前：`Image.file` 不带 cacheWidth = 这版之前的样子，每张整张 400×400 解码。
      //    400 × 400 × 4 B = 640 000 B/张，8 张 = 5 120 000 B。
      await tester.pumpWidget(_oldImageGridHarness(files));
      await _waitFor(
        tester,
        () => imageCache.currentSizeBytes >= 8 * 400 * 400 * 4,
        '改前的 8 张解码',
      );
      final int before = imageCache.currentSizeBytes;
      expect(before, 8 * 400 * 400 * 4,
          reason: '改前 = 文件原尺寸整张解码（400×400×4 B/张）');

      // ── 改后（208pt 卡）：260 设备像素 → 320 档。320×320×4 = 409 600 B/张（省 36%）。
      imageCache
        ..clear()
        ..clearLiveImages();
      await tester.pumpWidget(
          _gridHarness(cache: _FileListCoverCache(files), count: 8, cell: 208));
      await _waitFor(
        tester,
        () => imageCache.currentSizeBytes >= 8 * 320 * 320 * 4,
        '改后的 8 张解码（320 档）',
      );
      final int after320 = imageCache.currentSizeBytes;
      expect(after320, 8 * 320 * 320 * 4,
          reason: '改后 = 320 档解码（320×320×4 B/张）');

      // ── 改后（172pt 卡，即设置里的「小」封面）：215 设备像素 → 256 档。
      imageCache
        ..clear()
        ..clearLiveImages();
      await tester.pumpWidget(
          _gridHarness(cache: _FileListCoverCache(files), count: 8, cell: 172));
      await _waitFor(
        tester,
        () => imageCache.currentSizeBytes >= 8 * 256 * 256 * 4,
        '改后的 8 张解码（256 档）',
      );
      final int after256 = imageCache.currentSizeBytes;
      expect(after256, 8 * 256 * 256 * 4,
          reason: '256 档解码（256×256×4 B/张）');

      // 数字留进日志（报告里要用真数）。
      // ignore: avoid_print
      print('8 张 400×400 封面：改前 $before B (${before / 1024} KiB) / '
          '改后 320 档 $after320 B (${after320 / 1024} KiB, '
          '${(100 * (before - after320) / before).toStringAsFixed(1)}%↓) / '
          '改后 256 档 $after256 B (${after256 / 1024} KiB, '
          '${(100 * (before - after256) / before).toStringAsFixed(1)}%↓)');

      // 断言方向：省内存必须真的发生（不是"看起来省了"）。
      expect(after320, lessThan(before));
      expect(after256, lessThan(after320));

      // 高 DPI 不退化（同一组数字）：解码宽 320 ≥ 显示物理宽 260；256 ≥ 215。
      expect(320 >= (208 * 1.25).ceil(), isTrue);
      expect(256 >= (172 * 1.25).ceil(), isTrue);
    });
  });
}
