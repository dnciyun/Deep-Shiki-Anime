/// 入口可编译性守卫：import 整个 `main.dart`（shikiin + dsanima_core + media_kit +
/// riverpod 全量依赖图）并在测试里编译一次。
///
/// 意义：本机没有 Visual Studio（无法 `flutter build windows`），
/// `flutter test` 与 `flutter build bundle --target-platform=windows-x64`
/// 是当前唯一能证明「产品入口及其依赖图可编译」的手段。
library;

import 'package:dsanima/main.dart' as entry;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('main.dart 导入图可编译，且暴露 main(List<String>)', () {
    expect(entry.main, isA<Function>());
  });
}
