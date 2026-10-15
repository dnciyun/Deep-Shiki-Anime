/// GitHub Release 解析 / 挑包 / 判定 / 错误文案（第三十九轮）。
///
/// 这里的每条规则都对应一个用户看得见的结果，所以逐条钉住：
/// "已是最新""发现新版本但没包""更新源填错了""额度用完了"。
library;

import 'dart:convert';

import 'package:dsanima_core/update/update.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真机拿到的响应体形态（github.com/repos/{owner}/{repo}/releases/latest）。
Map<String, Object?> _payload({String tag = 'v1.0.1'}) => <String, Object?>{
  'tag_name': tag,
  'name': 'DSAnima 1.0.1',
  'body': '## 修复\n- 点下一集有反馈了',
  'published_at': '2026-10-15T13:00:00Z',
  'html_url': 'https://github.com/abc/DSAnima/releases/tag/$tag',
  'draft': false,
  'prerelease': false,
  'assets': <Object?>[
    <String, Object?>{
      'name': 'DSAnima-20261015-win-x64.zip',
      'browser_download_url':
          'https://github.com/abc/DSAnima/releases/download/$tag/DSAnima-20261015-win-x64.zip',
      'size': 41311187,
      'content_type': 'application/zip',
    },
    <String, Object?>{
      'name': 'DSAnima-20261015-win-x64.zip.sha256',
      'browser_download_url': 'https://github.com/abc/DSAnima/releases/download/$tag/sha.txt',
      'size': 80,
    },
  ],
};

void main() {
  group('ReleaseInfo.tryParse', () {
    test('把 release 的关键字段读出来（assets 都解析）', () {
      final ReleaseInfo? info = ReleaseInfo.tryParse(_payload());
      expect(info, isNotNull);
      expect(info!.tag, 'v1.0.1');
      expect(info.version, const AppVersion(1, 0, 1));
      expect(info.title, 'DSAnima 1.0.1');
      expect(info.displayTitle, 'DSAnima 1.0.1');
      expect(info.notes, contains('点下一集有反馈'));
      expect(info.publishedAt, DateTime.utc(2026, 10, 15, 13));
      expect(info.htmlUrl, 'https://github.com/abc/DSAnima/releases/tag/v1.0.1');
      expect(info.assets, hasLength(2));
      expect(info.assets.first.sizeBytes, 41311187);
    });

    test('标题为空时回落到标签', () {
      final Map<String, Object?> raw = _payload()..['name'] = '   ';
      expect(ReleaseInfo.tryParse(raw)!.displayTitle, 'v1.0.1');
    });

    test('草稿不算一次发布；缺 tag_name / 不是对象 → null', () {
      expect(ReleaseInfo.tryParse(_payload()..['draft'] = true), isNull);
      expect(ReleaseInfo.tryParse(_payload()..remove('tag_name')), isNull);
      expect(ReleaseInfo.tryParse(_payload()..['tag_name'] = ''), isNull);
      expect(ReleaseInfo.tryParse('{"message":"Not Found"}'), isNull);
      expect(ReleaseInfo.tryParse(null), isNull);
      expect(ReleaseInfo.tryParse(<Object?>[]), isNull);
    });

    test('标签不是版本号时仍然解析成功，只是 version 为 null', () {
      final ReleaseInfo info = ReleaseInfo.tryParse(_payload(tag: 'latest'))!;
      expect(info.tag, 'latest');
      expect(info.version, isNull);
    });

    test('asset 字段不全就丢掉，不影响整条 release', () {
      final Map<String, Object?> raw = _payload();
      raw['assets'] = <Object?>[
        <String, Object?>{'name': 'x.zip'},
        'junk',
        <String, Object?>{'name': 'y.zip', 'browser_download_url': 'https://e/y.zip'},
      ];
      final ReleaseInfo info = ReleaseInfo.tryParse(raw)!;
      expect(info.assets.map((ReleaseAsset a) => a.name), <String>['y.zip']);
    });
  });

  group('pickWindowsAsset', () {
    ReleaseAsset asset(String name) =>
        ReleaseAsset(name: name, downloadUrl: 'https://e/$name', sizeBytes: 1);

    test('win-x64 的 zip 优先，sha256/7z/txt 一律不要', () {
      final ReleaseAsset? picked = pickWindowsAsset(<ReleaseAsset>[
        asset('DSAnima-20261015-win-x64.zip.sha256'),
        asset('DSAnima-20261015-src.tar.gz'),
        asset('DSAnima-20261015-win-x64.7z'),
        asset('dsanima.zip'),
        asset('DSAnima-20261015-win-x64.zip'),
      ]);
      expect(picked!.name, 'DSAnima-20261015-win-x64.zip');
    });

    test('没有 win-x64 时退而求其次（win / x64 / 光秃秃的 zip）', () {
      expect(
        pickWindowsAsset(<ReleaseAsset>[asset('app-x64.zip')])!.name,
        'app-x64.zip',
      );
      expect(pickWindowsAsset(<ReleaseAsset>[asset('bundle.zip')])!.name, 'bundle.zip');
    });

    test('同分时取先出现的那个（顺序即发布顺序）', () {
      final ReleaseAsset? picked = pickWindowsAsset(<ReleaseAsset>[
        asset('DSAnima-a-win-x64.zip'),
        asset('DSAnima-b-win-x64.zip'),
      ]);
      expect(picked!.name, 'DSAnima-a-win-x64.zip');
    });

    test('一个 zip 都没有 → null', () {
      expect(pickWindowsAsset(<ReleaseAsset>[asset('notes.txt'), asset('setup.exe')]), isNull);
      expect(pickWindowsAsset(const <ReleaseAsset>[]), isNull);
    });
  });

  group('decideUpdate', () {
    final ReleaseInfo release = ReleaseInfo.tryParse(_payload())!;

    test('远端更新 → 可更新，并带上挑好的包', () {
      final UpdateDecision decision =
          decideUpdate(current: const AppVersion(1, 0, 0, build: 1), latest: release);
      expect(decision, isA<UpdateAvailable>());
      final UpdateAvailable available = decision as UpdateAvailable;
      expect(available.asset.name, 'DSAnima-20261015-win-x64.zip');
      expect(available.release.version, const AppVersion(1, 0, 1));
    });

    test('相同 / 本地更新（自编译的测试版）→ 已是最新', () {
      for (final AppVersion current in <AppVersion>[
        const AppVersion(1, 0, 1),
        const AppVersion(1, 0, 1, build: 9),
        const AppVersion(2, 0, 0),
      ]) {
        final UpdateDecision decision = decideUpdate(current: current, latest: release);
        expect(decision, isA<UpdateUpToDate>(), reason: '$current 不该提示更新');
      }
    });

    test('有新版本但没有可用的 zip → 单独一档（不能说"已是最新"）', () {
      final Map<String, Object?> raw = _payload();
      raw['assets'] = <Object?>[
        <String, Object?>{'name': 'setup.exe', 'browser_download_url': 'https://e/setup.exe'},
      ];
      final UpdateDecision decision = decideUpdate(
        current: const AppVersion(1, 0, 0),
        latest: ReleaseInfo.tryParse(raw)!,
      );
      expect(decision, isA<UpdateNoAsset>());
      expect((decision as UpdateNoAsset).release.tag, 'v1.0.1');
    });

    test('标签看不懂 → 单独一档', () {
      final UpdateDecision decision = decideUpdate(
        current: const AppVersion(1, 0, 0),
        latest: ReleaseInfo.tryParse(_payload(tag: 'nightly'))!,
      );
      expect(decision, isA<UpdateUnparsableTag>());
      expect((decision as UpdateUnparsableTag).tag, 'nightly');
    });
  });

  group('normalizeRepoSlug：用户从哪儿抄都能认', () {
    test('用户 2026-10-15 问的就是"仓库建了在哪找 api" —— 地址栏那两段就是答案', () {
      const List<String> accepted = <String>[
        'abc/DSAnima',
        'abc/DSAnima/',
        '  abc/DSAnima  ',
        'https://github.com/abc/DSAnima',
        'https://github.com/abc/DSAnima/',
        'https://www.github.com/abc/DSAnima',
        'https://github.com/abc/DSAnima.git',
        'git@github.com:abc/DSAnima.git',
        'https://github.com/abc/DSAnima/releases',
        'https://github.com/abc/DSAnima/releases/latest',
        'https://api.github.com/repos/abc/DSAnima/releases/latest',
        'api.github.com/repos/abc/DSAnima/releases/latest',
        'https://github.com/abc/DSAnima?tab=readme-ov-file',
        'https://github.com/abc/DSAnima#readme',
      ];
      for (final String raw in accepted) {
        expect(normalizeRepoSlug(raw), 'abc/DSAnima', reason: raw);
      }
    });

    test('认不出来的一律 null（调用方要给"填哪两段"的提示）', () {
      for (final String raw in <String>[
        '',
        '   ',
        'DSAnima',
        'https://github.com/abc',
        'https://github.com/',
        'https://example.com/abc/DSAnima',
        'abc/DS Anima',
        'releases/DSAnima',
        'abc/releases',
      ]) {
        expect(normalizeRepoSlug(raw), isNull, reason: raw);
      }
      expect(normalizeRepoSlug(null), isNull);
    });

    test('仓库名里的点/下划线/短横线保留（GitHub 允许）', () {
      expect(normalizeRepoSlug('abc/DSAnima_v2.0'), 'abc/DSAnima_v2.0');
      expect(normalizeRepoSlug('https://github.com/a-b/DS-Anima'), 'a-b/DS-Anima');
    });

    test('不是 github 的主机一律拒绝（免得把别的网站粘进来）', () {
      // `a.b/owner` 长得像主机名 → 不是 github.com 就不认（GitHub 用户名本来也不含点）。
      expect(normalizeRepoSlug('https://example.com/abc/DSAnima'), isNull);
      expect(normalizeRepoSlug('https://gitlab.com/abc/DSAnima'), isNull);
    });

    test('接口地址与发布页地址', () {
      expect(releaseApiUrl('abc/DSAnima'), 'https://api.github.com/repos/abc/DSAnima/releases/latest');
      expect(releasePageUrl('abc/DSAnima'), 'https://github.com/abc/DSAnima/releases/latest');
    });
  });

  group('ReleaseAsset：apiUrl（第四十轮：带令牌下载走 API 资产地址）', () {
    test('解析 `url`；没有/空串就为 null（退回 browser_download_url）', () {
      final ReleaseAsset withApi = ReleaseAsset.tryParse(<String, Object?>{
        'name': 'DSAnima-1-win-x64.zip',
        'browser_download_url': 'https://github.com/abc/DSAnima/releases/download/v1/x.zip',
        'url': 'https://api.github.com/repos/abc/DSAnima/releases/assets/42',
        'size': 123,
      })!;
      expect(withApi.apiUrl, 'https://api.github.com/repos/abc/DSAnima/releases/assets/42');
      expect(withApi.downloadUrl, contains('github.com'));
      expect(withApi.sizeBytes, 123);

      final ReleaseAsset bare = ReleaseAsset.tryParse(<String, Object?>{
        'name': 'x.zip',
        'browser_download_url': 'https://example.invalid/x.zip',
      })!;
      expect(bare.apiUrl, isNull, reason: '手写 JSON 没有 url ⇒ 用浏览器地址当退路');
      expect(
        ReleaseAsset.tryParse(<String, Object?>{
          'name': 'x.zip',
          'browser_download_url': 'https://example.invalid/x.zip',
          'url': '',
        })!.apiUrl,
        isNull,
        reason: '空串不是地址',
      );
    });
  });

  group('describeReleaseHttpError：每个状态码都要有可行动说法', () {
    test('404（仓库不存在 / 还没发 Release）', () {
      final UpdateFailure f = describeReleaseHttpError(404, apiMessage: 'Not Found');
      expect(f.message, contains('找不到这个仓库'));
      expect(f.hint, contains('仓库名'));
      // 第四十轮：匿名 404 的兜底出口是"填个只读令牌"（私有仓库 / 账号对访客不可见）。
      expect(f.hint, contains('访问令牌'));
      expect(f.toString(), contains(f.message));
    });

    test('401（令牌无效）要和"仓库找不到"分开说，不然用户会去改仓库名', () {
      final UpdateFailure f = describeReleaseHttpError(401, apiMessage: 'Bad credentials');
      expect(f.message, contains('令牌'));
      expect(f.message, isNot(contains('找不到这个仓库')));
      expect(f.hint, contains('Contents: Read-only'));
      expect(f.hint, contains('清空'), reason: '要给出"退回匿名"这条退路');
    });

    test('404 + 带了令牌：说到"令牌可能没权限看这个仓库"', () {
      final UpdateFailure anon = describeReleaseHttpError(404, apiMessage: 'Not Found');
      final UpdateFailure withToken =
          describeReleaseHttpError(404, apiMessage: 'Not Found', authenticated: true);
      expect(withToken.message, contains('令牌没权限'));
      expect(withToken.hint, contains('Contents: Read-only'));
      // 没带令牌时的说法必须原样留着（对公开仓库仍然最准）。
      expect(anon.message, contains('找不到这个仓库'));
      expect(anon.message, isNot(contains('令牌没权限')));
    });

    test('403 额度用完：说清什么时候能再来（匿名 60 次/小时）', () {
      final UpdateFailure f = describeReleaseHttpError(
        403,
        apiMessage: 'API rate limit exceeded for 1.2.3.4.',
        rateLimitReset: DateTime.utc(2026, 10, 15, 14, 5),
      );
      expect(f.message, contains('额度用完'));
      expect(f.hint, contains('再试'));
      // 本地时区渲染：只要提到"时:分"就算说到位（不断言具体小时，避免跟时区绑死）。
      expect(f.hint, matches(RegExp(r'\d\d:\d\d')));
    });

    test('403 但没提额度 → 不当成限流', () {
      final UpdateFailure f = describeReleaseHttpError(403, apiMessage: 'Forbidden');
      expect(f.message, contains('403'));
      expect(f.message, isNot(contains('额度')));
    });

    test('5xx 说明不是本机的问题；其它码回落到通用说法', () {
      expect(describeReleaseHttpError(502).message, contains('GitHub 服务器出错'));
      expect(describeReleaseHttpError(502).hint, contains('过几分钟'));
      final UpdateFailure generic = describeReleaseHttpError(418, apiMessage: 'teapot');
      expect(generic.message, contains('HTTP 418'));
      expect(generic.hint, 'teapot');
      expect(describeReleaseHttpError(0).hint, contains('网络'));
    });
  });

  group('PendingUpdate：下次启动对账', () {
    test('JSON 往返', () {
      final PendingUpdate pending = PendingUpdate(
        tag: 'v1.0.1',
        target: const AppVersion(1, 0, 1),
        startedAt: DateTime.utc(2026, 10, 15, 12),
        packagePath: r'F:\x\update.zip',
      );
      final PendingUpdate? back =
          PendingUpdate.tryParse(jsonDecode(jsonEncode(pending.toJson())) as Map<Object?, Object?>);
      expect(back!.tag, 'v1.0.1');
      expect(back.target, const AppVersion(1, 0, 1));
      expect(back.startedAt, DateTime.utc(2026, 10, 15, 12));
      expect(back.packagePath, r'F:\x\update.zip');
    });

    test('坏数据 / 缺 target → null（当作没有待办，不崩）', () {
      expect(PendingUpdate.tryParse(null), isNull);
      expect(PendingUpdate.tryParse(<String, Object?>{'tag': 'v1.0.1'}), isNull);
      expect(PendingUpdate.tryParse(<String, Object?>{'target': 'x'}), isNull);
    });

    test('对账：版本到位 = 覆盖成功；还是老版本 = 没生效', () {
      final PendingUpdate pending = PendingUpdate(
        tag: 'v1.0.1',
        target: const AppVersion(1, 0, 1),
        startedAt: DateTime.utc(2026, 10, 15),
      );
      expect(
        compareAftermath(current: const AppVersion(1, 0, 1), pending: pending),
        UpdateAftermath.applied,
      );
      expect(
        compareAftermath(current: const AppVersion(1, 0, 2), pending: pending),
        UpdateAftermath.applied,
      );
      expect(
        compareAftermath(current: const AppVersion(1, 0, 0, build: 1), pending: pending),
        UpdateAftermath.notApplied,
      );
    });
  });
}
