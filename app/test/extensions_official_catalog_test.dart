/// 官方插件库地址（`kOfficialExtensionsCatalogUrl`）的接线检查。
///
/// 用户 2026-10-18：「加入官方插件库，可以直接下载我加进去的插件」，当晚给了仓库
/// <https://github.com/dnciyun/DSAnima-plungin>。这一份测试钉的是**常量与换算**，
/// 不联网：
///
/// * 地址不能是空的（扩展页「官方插件库」按钮出厂就该能点）；
/// * 填的是**仓库网页地址**，`core.extensionCatalogUrlCandidates` 必须能把它展开成
///   `raw.githubusercontent.com/…/catalog.json` 的候选（main/master × 根/extensions/），
///   这样作者把 catalog.json 放在子目录、或默认分支叫 master 时也拉得到；
/// * `plungin` 这个拼写是仓库名的一部分，**不许被"顺手改正"**成 plugin
///   （改一个字母就是另一个不存在的仓库，而且是运行期才会暴露的 404）。
library;

import 'package:dsanima/domain/extensions.dart';
import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('官方插件库地址', () {
    test('出厂就有（不用用户先粘一次地址）', () {
      expect(kOfficialExtensionsCatalogUrl.trim(), isNotEmpty);
      final Uri url = Uri.parse(kOfficialExtensionsCatalogUrl);
      expect(url.scheme, 'https');
      expect(url.host, 'github.com');
      expect(url.pathSegments, <String>['dnciyun', 'DSAnima-plungin']);
    });

    test('仓库网页地址 → catalog.json 的 raw 候选（main 优先，共 4 个）', () {
      final List<Uri> candidates =
          core.extensionCatalogUrlCandidates(Uri.parse(kOfficialExtensionsCatalogUrl));

      expect(
        candidates.first.toString(),
        'https://raw.githubusercontent.com/dnciyun/DSAnima-plungin/main/catalog.json',
        reason: '最常见的那一种排最前：默认分支 main、catalog.json 在仓库根',
      );
      final List<String> tried = candidates.map((Uri u) => u.toString()).toList();
      expect(tried, contains(
          'https://raw.githubusercontent.com/dnciyun/DSAnima-plungin/master/catalog.json'));
      expect(tried, contains(
          'https://raw.githubusercontent.com/dnciyun/DSAnima-plungin/main/extensions/catalog.json'));
      expect(tried.toSet().length, candidates.length, reason: '候选之间不许重复（白试一轮）');
    });
  });
}
