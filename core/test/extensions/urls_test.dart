/// 扩展地址规整（`core/lib/extensions/urls.dart`）：GitHub 网页地址 → 能下的地址。
///
/// 用户 2026-10-18 的原话是「加入官方插件库，可以直接下载我加进去的插件，**识别
/// github 上面的**」。所以这里钉的是"用户粘贴什么都能认出真实下载地址"，以及
/// "认不出来时不要瞎猜"。
library;

import 'package:dsanima_core/dsanima_core.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> _catalog(String url) => extensionCatalogUrlCandidates(Uri.parse(url))
    .map((Uri u) => u.toString())
    .toList();

List<String> _download(String url) =>
    extensionDownloadUrlCandidates(Uri.parse(url)).map((Uri u) => u.toString()).toList();

void main() {
  group('目录地址：GitHub 网页 → raw 候选', () {
    test('仓库根：main/master × 根目录/extensions 四个候选，main 在前', () {
      expect(_catalog('https://github.com/ciciyouxihao-source/dsanima-extensions'), <String>[
        'https://raw.githubusercontent.com/ciciyouxihao-source/dsanima-extensions/main/catalog.json',
        'https://raw.githubusercontent.com/ciciyouxihao-source/dsanima-extensions/main/extensions/catalog.json',
        'https://raw.githubusercontent.com/ciciyouxihao-source/dsanima-extensions/master/catalog.json',
        'https://raw.githubusercontent.com/ciciyouxihao-source/dsanima-extensions/master/extensions/catalog.json',
      ]);
    });

    test('仓库根带尾斜杠 / 大小写域名都认', () {
      expect(
        _catalog('https://www.github.com/o/r/')[0],
        'https://raw.githubusercontent.com/o/r/main/catalog.json',
      );
      expect(
        _catalog('https://GITHUB.com/o/r')[0],
        'https://raw.githubusercontent.com/o/r/main/catalog.json',
      );
    });

    test('blob 地址 → 同名 raw（作者可能把 catalog 放在任意路径/文件名）', () {
      expect(
        _catalog('https://github.com/o/r/blob/dev/site/list.json'),
        <String>['https://raw.githubusercontent.com/o/r/dev/site/list.json'],
      );
    });

    test('tree 地址（贴的是目录）→ 目录下的 catalog.json 再兜底', () {
      final List<String> got = _catalog('https://github.com/o/r/tree/dev/extensions');
      expect(got.first,
          'https://raw.githubusercontent.com/o/r/dev/extensions/catalog.json');
      expect(got, contains('https://raw.githubusercontent.com/o/r/dev/catalog.json'));
      // 也认 master（老仓库）
      expect(got, contains('https://raw.githubusercontent.com/o/r/master/extensions/catalog.json'));
    });

    test('raw 地址原样通过（去掉 #fragment）', () {
      expect(
        _catalog('https://raw.githubusercontent.com/o/r/main/catalog.json#x'),
        <String>['https://raw.githubusercontent.com/o/r/main/catalog.json'],
      );
    });

    test('非 GitHub 地址（自建目录）原样通过', () {
      expect(_catalog('https://example.com/ext/catalog.json'),
          <String>['https://example.com/ext/catalog.json']);
    });

    test('认不出来的 GitHub 页面（用户主页 / releases）退回原地址，不瞎猜', () {
      expect(_catalog('https://github.com/someone'), <String>['https://github.com/someone']);
      expect(
        _catalog('https://github.com/o/r/releases/tag/v1'),
        <String>['https://github.com/o/r/releases/tag/v1'],
      );
    });
  });

  group('下载地址：GitHub 网页 → raw', () {
    test('blob → raw（直接下 zip 不能拿 HTML 页面）', () {
      expect(
        _download('https://github.com/o/r/blob/main/packs/x-1.0.0.zip'),
        <String>['https://raw.githubusercontent.com/o/r/main/packs/x-1.0.0.zip'],
      );
    });

    test('releases 直链与普通地址原样通过', () {
      const String rel = 'https://github.com/o/r/releases/download/v1/x.zip';
      expect(_download(rel), <String>[rel]);
      const String plain = 'https://example.com/x.zip';
      expect(_download(plain), <String>[plain]);
    });
  });
}
