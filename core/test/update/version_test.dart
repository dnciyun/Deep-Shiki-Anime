/// 版本号解析与比较（第三十九轮：GitHub 检查更新的地基）。
///
/// 这一层错一次，用户的后果是"明明有新版本却说已是最新"或者反过来
/// "每次打开都提示更新" —— 两种都很难被用户自己诊断，所以边界都钉在这里。
library;

import 'package:dsanima_core/update/update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppVersion.tryParse', () {
    test('标准形态：带 v / 不带 v', () {
      expect(AppVersion.tryParse('v1.2.3'), const AppVersion(1, 2, 3));
      expect(AppVersion.tryParse('1.2.3'), const AppVersion(1, 2, 3));
      expect(AppVersion.tryParse('V2.0.0'), const AppVersion(2, 0, 0));
      expect(AppVersion.tryParse('  v1.2.3  '), const AppVersion(1, 2, 3));
    });

    test('少写段：1.2 → 1.2.0', () {
      expect(AppVersion.tryParse('1.2'), const AppVersion(1, 2, 0));
      expect(AppVersion.tryParse('v3'), const AppVersion(3, 0, 0));
    });

    test('+build：解析进 build，且不污染三段号', () {
      expect(AppVersion.tryParse('1.2.3+4'), const AppVersion(1, 2, 3, build: 4));
      expect(AppVersion.tryParse('v1.2.3+4.1'), const AppVersion(1, 2, 3, build: 4));
      expect(AppVersion.tryParse('1.2.3+build7'), const AppVersion(1, 2, 3));
    });

    test('预发布后缀只用于解析成功，不进数字', () {
      expect(AppVersion.tryParse('v1.0.0-rc.1'), const AppVersion(1, 0, 0));
      expect(AppVersion.tryParse('1.0.0-beta'), const AppVersion(1, 0, 0));
    });

    test('看不懂的标签返回 null（不抛）', () {
      expect(AppVersion.tryParse(null), isNull);
      expect(AppVersion.tryParse(''), isNull);
      expect(AppVersion.tryParse('   '), isNull);
      expect(AppVersion.tryParse('v'), isNull);
      expect(AppVersion.tryParse('latest'), isNull);
      expect(AppVersion.tryParse('1.2.3.4'), isNull);
      expect(AppVersion.tryParse('1..2'), isNull);
      expect(AppVersion.tryParse('1.-2.3'), isNull);
      expect(AppVersion.tryParse('v1.2.x'), isNull);
    });
  });

  group('比较', () {
    test('按 major → minor → patch → build 逐级比', () {
      expect(const AppVersion(1, 2, 3).compareTo(const AppVersion(1, 2, 4)), lessThan(0));
      expect(const AppVersion(1, 2, 3).compareTo(const AppVersion(1, 3, 0)), lessThan(0));
      expect(const AppVersion(2, 0, 0).compareTo(const AppVersion(1, 9, 9)), greaterThan(0));
      // 同一版本号下，重打了一次包（+build）也算更新。
      expect(const AppVersion(1, 0, 0, build: 1).compareTo(const AppVersion(1, 0, 0)), greaterThan(0));
      expect(const AppVersion(1, 0, 0).compareTo(const AppVersion(1, 0, 0)), 0);
    });

    test('算子来自 Comparable，== 与 hashCode 一致', () {
      expect(const AppVersion(1, 2, 3) > const AppVersion(1, 2, 2), isTrue);
      expect(const AppVersion(1, 2, 3) >= const AppVersion(1, 2, 3), isTrue);
      expect(const AppVersion(1, 2, 3) < const AppVersion(1, 2, 4), isTrue);
      expect(const AppVersion(1, 2, 3), const AppVersion(1, 2, 3));
      expect(const AppVersion(1, 2, 3).hashCode, const AppVersion(1, 2, 3).hashCode);
      expect(const AppVersion(1, 2, 3), isNot(const AppVersion(1, 2, 3, build: 1)));
    });

    test('界面/标签写法', () {
      expect(const AppVersion(1, 2, 3).toString(), '1.2.3');
      expect(const AppVersion(1, 2, 3, build: 4).toString(), '1.2.3+4');
      expect(const AppVersion(1, 2, 3).label, 'v1.2.3');
      expect(const AppVersion(1, 2, 3, build: 4).label, 'v1.2.3（构建 4）');
      expect(const AppVersion(1, 2, 3).tag, 'v1.2.3');
      expect(const AppVersion(1, 2, 3, build: 4).tag, 'v1.2.3');
    });
  });
}
