/// mikan 封面取档（第三十一轮）：**用户 2026-10-15「今日更新的封面图还是显示不全」**的回归钉。
///
/// 根因不是布局：mikan 首页给的 `data-src` 带 `?width=400&height=400&format=webp`，
/// 图床**带 `height` 就按正方形裁剪** —— 真机实测同一张封面
/// 原图 `1429×2000` → 带 height 拿到 `400×400`（上下各裁约 30%）、
/// 只带 width 拿到 `400×560`（完整海报）。所以界面把槽开成多高的竖版框都没用。
///
/// 这个文件只测纯函数（不联网）；「控件到底请求了哪个 URL」在 `cover_size_test.dart`。
library;

import 'package:dsanima/domain/mikan_cover.dart';
import 'package:flutter_test/flutter_test.dart';

/// 站点首页真实的 `data-src`（2026-10-15 从 mikanani.me 抓的原文）。
const String kRealSquare =
    'https://mikanani.me/images/Bangumi/202603/712cede8.jpg'
    '?width=400&height=400&format=webp';

void main() {
  group('mikanCoverAt：删掉会裁图的 height，并按显示宽度取档', () {
    test('真机原样 URL（width=400&height=400&format=webp）→ 去掉 height', () {
      expect(
        mikanCoverAt(kRealSquare, 0),
        'https://mikanani.me/images/Bangumi/202603/712cede8.jpg'
        '?width=400&format=webp',
      );
    });

    test('任何情况下都不再带 height（这是"不再被裁"的唯一关键）', () {
      for (final int px in <int>[0, 50, 100, 260, 400, 800, 4000]) {
        final String? url = mikanCoverAt(kRealSquare, px);
        expect(url, isNotNull);
        expect(url, isNot(contains('height=')), reason: '$px 设备像素也不许带 height');
      }
    });

    test('档位：40pt 缩略图 → 200；208pt 海报卡（×1.25 = 260）→ 400；大卡 → 800', () {
      String? at(int px) => mikanCoverAt(kRealSquare, px);
      expect(at(50), contains('width=200'));
      expect(at(200), contains('width=200'));
      expect(at(260), contains('width=400'), reason: '208pt × 1.25');
      expect(at(400), contains('width=400'));
      expect(at(500), contains('width=800'));
      expect(at(4000), contains('width=800'), reason: '超过最大档取最大档');
    });

    test('devicePixels <= 0（布局还没算出来）：只删 height，不猜档位', () {
      expect(mikanCoverAt(kRealSquare, 0), contains('width=400'));
    });

    test('别的参数一个都不丢（format / 未知参数 / 参数顺序）', () {
      final String url =
          'https://mikanani.me/images/Bangumi/202610/abc.jpg?height=400&format=webp&v=2&width=400';
      final String out = mikanCoverAt(url, 260)!;
      expect(out, contains('format=webp'));
      expect(out, contains('v=2'));
      expect(out, contains('width=400'));
      expect(out, isNot(contains('height')));
    });

    test('只有 height、没有 width 时补一个 width（否则图床还是按原图给）', () {
      final String out =
          mikanCoverAt('https://mikanani.me/images/Bangumi/x/a.jpg?height=400', 260)!;
      expect(out, contains('width=400'));
      expect(out, isNot(contains('height')));
    });

    test('不是 mikan 封面：一个字都不动（Bangumi / 别的站点 / 没有尺寸参数）', () {
      const String bangumi =
          'https://lain.bgm.tv/r/100/pic/cover/l/8a/b2/312427_D2ZNm.jpg';
      expect(mikanCoverAt(bangumi, 400), bangumi);
      // 没有 width/height 参数的 mikan 图：不动（不猜站点支不支持缩放参数）。
      const String plain = 'https://mikanani.me/images/Bangumi/202610/abc.jpg?format=webp';
      expect(mikanCoverAt(plain, 400), plain);
      const String other = 'https://example.com/cover.jpg?width=400&height=400';
      expect(mikanCoverAt(other, 400), other, reason: '不是 mikan 的图床就不碰');
    });

    test('空串 / 全空白 → null（调用方照旧走「无封面」占位；null 进 null 出）', () {
      expect(mikanCoverAt(null, 400), isNull);
      expect(mikanCoverAt('', 400), isNull);
      expect(mikanCoverAt('   ', 400), isNull);
    });

    test('snapMikanCoverWidth 的边界', () {
      expect(snapMikanCoverWidth(0), 0, reason: '0 = 不改档');
      expect(snapMikanCoverWidth(-5), 0);
      expect(snapMikanCoverWidth(1), 200);
      expect(snapMikanCoverWidth(200), 200);
      expect(snapMikanCoverWidth(201), 400);
      expect(snapMikanCoverWidth(800), 800);
      expect(snapMikanCoverWidth(801), 800);
    });
  });

  group('isLegacySquareMikanCoverUrl：盘上那批方图该被清掉', () {
    test('带 height 的 mikan 封面 = 旧方形封面（这一版之后再也没人请求）', () {
      expect(isLegacySquareMikanCoverUrl(kRealSquare), isTrue);
    });

    test('去掉 height 之后的新形状不是"旧的"（否则会把自己刚下的删掉）', () {
      expect(
        isLegacySquareMikanCoverUrl(mikanCoverAt(kRealSquare, 260)!),
        isFalse,
      );
    });

    test('Bangumi 封面 / 别的站点 / 坏 URL 一律不算', () {
      expect(
        isLegacySquareMikanCoverUrl(
            'https://lain.bgm.tv/r/100/pic/cover/l/8a/b2/312427_D2ZNm.jpg'),
        isFalse,
      );
      expect(isLegacySquareMikanCoverUrl('https://example.com/a.jpg?height=400'), isFalse);
      expect(isLegacySquareMikanCoverUrl('not a url'), isFalse);
      expect(isLegacySquareMikanCoverUrl(''), isFalse);
    });
  });
}
