/// 「打开所在文件夹」的落点解析（2026-10-12 第十七轮 · 用户报的"跳到文档文件夹"）。
///
/// 缺陷回顾：老实现把 `/select,<绝对路径>` 整个交给 `explorer.exe`，而 Dart 会给
/// **含空格的参数整体加引号** → 资源管理器不再把开头认成 `/select,` 开关 → 回落打开
/// **文档**。番剧文件名几乎都带空格，所以用户那边是"每次都跳文档"。
/// 现在交给资源管理器的东西必须满足两条硬约束（下面逐条钉住）：
/// **绝对路径**、**目标存在**。
library;

import 'dart:io';

import 'package:dsanima/domain/reveal_in_explorer.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;

  setUp(() {
    // 目录名**故意带空格**：这正是老实现翻车的那种路径。
    root = Directory.systemTemp.createTempSync('ds aninma reveal ');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
  });

  test('存在的文件：打开它所在目录 + 选中它（带空格的目录/文件名）', () {
    final File file = File(p.join(root.path, 'With Space ep01.mp4'))
      ..writeAsStringSync('x');

    final RevealTarget? t = revealTargetFor(file.path);
    expect(t, isNotNull);
    expect(t!.select, file.path);
    expect(t.folder, root.path);
    expect(p.isAbsolute(t.folder), isTrue, reason: '交给资源管理器的一律绝对路径');
    expect(Directory(t.folder).existsSync(), isTrue);
  });

  test('存在的目录：打开它并选中它', () {
    final Directory dir = Directory(p.join(root.path, 'Sub Dir'))..createSync();
    final RevealTarget? t = revealTargetFor(dir.path);
    expect(t, isNotNull);
    expect(t!.folder, dir.path);
    expect(t.select, dir.path);
  });

  test('文件不在了：打开它所在的那一级（不把不存在的路径丢出去）', () {
    final RevealTarget? t =
        revealTargetFor(p.join(root.path, 'gone ep02.mp4'));
    expect(t, isNotNull);
    expect(t!.folder, root.path);
    expect(t.select, isNull);
    expect(Directory(t.folder).existsSync(), isTrue);
  });

  test('连目录都不在了：往上找到最近一个还存在的目录', () {
    final RevealTarget? t =
        revealTargetFor(p.join(root.path, 'no such dir', 'deeper', 'ep03.mp4'));
    expect(t, isNotNull);
    expect(t!.folder, root.path, reason: 'root 是最近的还存在的祖先');
    expect(t.select, isNull);
  });

  test('相对路径 → null（绝不猜：资源管理器会按它自己的工作目录去解析）', () {
    expect(revealTargetFor('ep01.mp4'), isNull);
    expect(revealTargetFor(r'..\..\Windows\System32\x.dll'), isNull);
    expect(revealTargetFor('.'), isNull);
  });

  test('空串 / 纯空白 → null', () {
    expect(revealTargetFor(''), isNull);
    expect(revealTargetFor('   '), isNull);
  });

  test('用户那种真实文件名（方括号 + 空格 + &）原样保留', () {
    const String name =
        '[Tsukigakirei] Kanojo no Tomodachi - 02 [WebRip 1080P AVC-8bit AAC][CHS&JPN][Uncencored].mp4';
    final File file = File(p.join(root.path, name))..writeAsStringSync('x');
    final RevealTarget? t = revealTargetFor(file.path);
    expect(t, isNotNull);
    expect(t!.select, file.path);
    expect(t.folder, root.path);
  });
}
