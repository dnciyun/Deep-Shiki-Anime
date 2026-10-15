/// 版本号对账（第三十九轮）：`app/pubspec.yaml` ↔ `kAppVersion`。
///
/// 为什么值得一个测试：检查更新的**唯一比较基准**就是这个常量。改 pubspec 忘了改它，
/// 后果是"发布了新版本但用户永远收不到提示"（或者反过来每次打开都提示更新），
/// 而且这两种现象从界面上完全看不出是同一个原因。
library;

import 'dart:io';

import 'package:dsanima/domain/app_version.dart';
import 'package:dsanima_core/update/update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('kAppVersion 与 pubspec 的 version 同步', () {
    final File pubspec = File('pubspec.yaml');
    expect(pubspec.existsSync(), isTrue, reason: 'flutter test 的工作目录应当是 app/');

    final RegExpMatch? match =
        RegExp(r'^version:\s*(\S+)\s*$', multiLine: true).firstMatch(pubspec.readAsStringSync());
    expect(match, isNotNull, reason: 'pubspec 里要有 `version: x.y.z+n`');

    final AppVersion? declared = AppVersion.tryParse(match!.group(1));
    expect(declared, isNotNull, reason: 'version 要写成 1.0.1+2 这种形态');
    expect(
      kAppVersion,
      declared,
      reason: 'pubspec 的 version 与 domain/app_version.dart 的 kAppVersion 必须一致'
          '（检查更新就是拿它跟 GitHub 标签比的）',
    );
  });

  test('发布标签形态稳定（tool/release_github.ps1 会打这个标签）', () {
    expect(kAppVersion.tag, matches(RegExp(r'^v\d+\.\d+\.\d+$')));
    expect(kAppVersion.label, startsWith('v'));
    expect(kAppVersion.build, greaterThan(0), reason: 'Windows 的版本资源要带构建号');
  });
}
