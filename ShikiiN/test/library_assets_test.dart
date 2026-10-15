/// 库包 asset 路径回归（真机缺陷：播放画面正中一个红色错误框）。
///
/// 背景：ShikiiN 作为**库**被宿主（`app/`）内嵌时，本包 pubspec 里声明的 asset
/// 只会以 **`packages/shikiin/...`** 的形式进宿主 bundle；无前缀的
/// `Image.asset('assets/icon.png')` 在宿主里**永远找不到**，于是
/// `open_surface`（播放页的「未载入」品牌面）会在画面正中渲染一个红色
/// error widget —— 正好盖住播放区域，用户看到的是「播放器坏了」。
///
/// 这个坑与 Anime4K 的 `assets/shaders/anime4k/...` 是同一类：**库代码里引用自己
/// 的 asset 必须带包前缀**（除非本包就是 app 根）。单测里不会暴露，因为 ShikiiN
/// 自己的测试环境恰好是「本包即 app」。
///
/// 这里用两条互补的断言：
/// 1. 源码不得再出现无前缀的 `assets/icon.png`（静态检查，最直接）；
/// 2. 包前缀路径在当前 bundle 里**真能解码**（`flutter_test` 的 asset bundle
///    含 `packages/shikiin/...`，且 image 加载异常会让测试失败）。
library;

import 'dart:io';
import 'dart:typed_data' show ByteData;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

const String kPackagedIconKey = 'packages/shikiin/assets/icon.png';

void main() {
  group('ShikiiN 自己的 asset 必须用包前缀路径', () {
    test('lib/ 下不得再用无前缀 assets/icon.png', () {
      final dir = Directory('lib');
      expect(dir.existsSync(), isTrue, reason: '测试工作目录应是 ShikiiN/');

      final offenders = <String>[];
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final text = entity.readAsStringSync();
        // 只抓「无前缀」的用法：`'assets/icon.png'`
        if (text.contains("'assets/icon.png'") ||
            text.contains('"assets/icon.png"')) {
          offenders.add(entity.path);
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: '内嵌进宿主时无前缀路径找不到（只有本包即 app 时才成立）；'
            '必须用 $kPackagedIconKey',
      );
    });

    test('包前缀路径在当前 bundle 里能真正取到字节', () async {
      final ByteData data = await rootBundle.load(kPackagedIconKey);
      expect(data.lengthInBytes, greaterThan(1000),
          reason: 'icon.png 是真 PNG（773 KB 级），取到几百字节说明是占位/错误内容');

      // PNG magic：非 PNG 说明被打包流程换掉了（例如误存成 HTML 错误页）。
      final bytes = data.buffer.asUint8List();
      expect(bytes.sublist(0, 8),
          <int>[137, 80, 78, 71, 13, 10, 26, 10],
          reason: '必须是真 PNG');
    });

    testWidgets('解码该 asset 不产生任何异常（缺失会在这里炸）',
        (WidgetTester tester) async {
      // 注意：图片解码是**真实异步 I/O**，`flutter_test` 默认的假异步时钟会让
      // `pumpAndSettle` 在等待 codec 时无限自旋（踩过：10 分钟不返回）。
      // 真解码必须放进 `tester.runAsync`。
      final ui.Image decoded = (await tester.runAsync(() async {
        final ByteData data = await rootBundle.load(kPackagedIconKey);
        final ui.Codec codec =
            await ui.instantiateImageCodec(data.buffer.asUint8List());
        final ui.FrameInfo frame = await codec.getNextFrame();
        return frame.image;
      }))!;

      expect(decoded.width, greaterThan(0));
      expect(decoded.height, greaterThan(0));
      addTearDown(decoded.dispose);

      // 挂进 widget 树渲染一次：解码失败/路径错都会让 takeException 非空
      //（真机上就是那个盖住播放画面的红色 error widget）。
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: Image.asset(
            kPackagedIconKey,
            height: 22,
            errorBuilder: (BuildContext ctx, Object e, StackTrace? st) =>
                const Text('ICON_MISSING'),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull,
          reason: '加载 icon 不得抛异常（真机上表现为红色 error widget）');
      expect(find.text('ICON_MISSING'), findsNothing,
          reason: 'errorBuilder 被触发说明 asset 没取到');
    });
  });
}
