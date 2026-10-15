/// fixture 加载器。
///
/// 所有站点样本都是 **2026-10-08 用 curl 从真实站点抓取** 后截断的原文
/// （见 `test/fixtures/README.md`），测试**绝不联网**。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// `core/` 包根目录（`flutter test` 的 CWD，兜底向上查找 pubspec.yaml）。
Directory packageRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 4; i++) {
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current;
}

Directory fixtureDir([String sub = '']) =>
    Directory(p.join(packageRoot().path, 'test', 'fixtures', sub));

File fixtureFile(String name) => File(p.join(fixtureDir().path, name));

/// 读取 fixture 的 UTF-8 原文。
///
/// 找不到文件直接抛错（**不允许静默跳过**，否则测试会假绿）。
String loadFixture(String name) {
  final file = fixtureFile(name);
  if (!file.existsSync()) {
    throw StateError('缺少 fixture: ${file.path}（测试必须在 core/ 包根目录下运行）');
  }
  return utf8.decode(file.readAsBytesSync());
}

/// 读取 fixture 原始字节（非 UTF-8 兜底测试用）。
List<int> loadFixtureBytes(String name) {
  final file = fixtureFile(name);
  if (!file.existsSync()) {
    throw StateError('缺少 fixture: ${file.path}');
  }
  return file.readAsBytesSync();
}

/// 合成边界样本（空 feed / 字段缺失 / 非法日期 / 缺 enclosure）。
String loadEdgeFixture(String name) {
  final file = File(p.join(fixtureDir('edge').path, name));
  if (!file.existsSync()) {
    throw StateError('缺少边界 fixture: ${file.path}');
  }
  return utf8.decode(file.readAsBytesSync());
}

List<int> loadEdgeFixtureBytes(String name) {
  final file = File(p.join(fixtureDir('edge').path, name));
  if (!file.existsSync()) {
    throw StateError('缺少边界 fixture: ${file.path}');
  }
  return file.readAsBytesSync();
}
