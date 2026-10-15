import 'dart:io';

import 'package:dsanima_core/dsanima_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// locator 的全部候选来源都可注入，所以这里**不碰真实文件系统**。
EngineLocator locatorWith({
  Set<String> existing = const <String>{},
  Map<String, String> environment = const <String, String>{},
  String currentDirectory = r'C:\repo',
  String resolvedExecutable = r'C:\app\dsanima.exe',
  int maxParentLevels = 6,
}) {
  return EngineLocator(
    environment: environment,
    currentDirectory: currentDirectory,
    resolvedExecutable: resolvedExecutable,
    fileExists: existing.contains,
    maxParentLevels: maxParentLevels,
  );
}

Matcher throwsEngineException(String fragment) => throwsA(
  isA<EngineException>().having(
    (e) => e.message,
    'message',
    contains(fragment),
  ),
);

void main() {
  final String engineFileName = EngineLocator.defaultEngineFileName;

  group('EngineLocator', () {
    test('平台默认文件名', () {
      expect(
        engineFileName,
        Platform.isWindows ? 'rqbit-engine.exe' : 'rqbit-engine',
      );
      expect(EngineLocator.envVarName, 'DSANIMA_ENGINE');
    });

    test('显式路径命中，优先于所有自动候选', () {
      final explicit = p.join(r'C:\custom', engineFileName);
      final locator = locatorWith(
        existing: <String>{explicit, p.join(r'C:\app', engineFileName)},
        environment: <String, String>{
          EngineLocator.envVarName: p.join(r'C:\env', engineFileName),
        },
      );
      expect(locator.locate(exePath: explicit), explicit);
      expect(locator.searched, <String>[explicit]);
    });

    test('显式路径不存在 → 立刻报错，不静默回退', () {
      final locator = locatorWith(
        existing: <String>{p.join(r'C:\app', engineFileName)},
      );
      expect(
        () => locator.locate(exePath: r'C:\nope\rqbit-engine.exe'),
        throwsEngineException(r'C:\nope\rqbit-engine.exe'),
      );
    });

    test('环境变量 DSANIMA_ENGINE 命中', () {
      final fromEnv = p.join(r'C:\tools', engineFileName);
      final locator = locatorWith(
        existing: <String>{fromEnv, p.join(r'C:\app', engineFileName)},
        environment: <String, String>{EngineLocator.envVarName: fromEnv},
      );
      expect(locator.locate(), fromEnv);
    });

    test('环境变量指向的文件不存在 → 明确报错（配置错了必须看得见）', () {
      final locator = locatorWith(
        existing: <String>{p.join(r'C:\app', engineFileName)},
        environment: <String, String>{
          EngineLocator.envVarName: r'C:\gone\rqbit-engine.exe',
        },
      );
      expect(
        () => locator.locate(),
        throwsEngineException(r'C:\gone\rqbit-engine.exe'),
      );
    });

    test('宿主 exe 同目录（打包后的首选位置）', () {
      final beside = p.join(r'C:\app', engineFileName);
      final locator = locatorWith(existing: <String>{beside});
      expect(locator.locate(), beside);
      expect(locator.searched, contains(beside));
    });

    test('向上逐级找 engine/target/release 产物（开发期）', () {
      final expected = p.join(
        r'C:\repo',
        'engine',
        'target',
        'release',
        engineFileName,
      );
      final locator = locatorWith(
        currentDirectory: p.join(r'C:\repo', 'core'),
        existing: <String>{expected},
      );
      expect(locator.locate(), expected);
      expect(
        locator.searched,
        containsAllInOrder(<String>[
          p.join(
            r'C:\repo',
            'core',
            'engine',
            'target',
            'release',
            engineFileName,
          ),
          expected,
        ]),
      );
    });

    test('从宿主 exe 目录向上找（cwd 是别处时）', () {
      final expected = p.join(
        r'C:\build',
        'engine',
        'target',
        'release',
        engineFileName,
      );
      final locator = locatorWith(
        currentDirectory: r'C:\unrelated',
        resolvedExecutable: p.join(r'C:\build', 'release', 'dsanima.exe'),
        existing: <String>{expected},
      );
      expect(locator.locate(), expected);
    });

    test('全部候选都失败 → 报错列出所有尝试过的路径 + 修复建议', () {
      final locator = locatorWith(maxParentLevels: 2);
      try {
        locator.locate();
        fail('应当抛 EngineException');
      } on EngineException catch (error) {
        expect(error.message, contains('找不到引擎可执行文件'));
        expect(error.message, contains(engineFileName));
        expect(error.message, contains('cargo build --release'));
        expect(error.message, contains(EngineLocator.envVarName));
        expect(error.message, contains('显式传入 exePath'));
        for (final path in locator.searched) {
          expect(error.message, contains(path), reason: '失败信息要回显候选路径: $path');
        }
        expect(locator.searched, isNotEmpty);
      }
    });

    test('maxParentLevels 限制向上搜索的层数', () {
      final deep = p.join(
        r'C:\root\sub',
        'engine',
        'target',
        'release',
        engineFileName,
      );
      final notDeepEnough = locatorWith(
        currentDirectory: p.join(r'C:\root\sub', 'core'),
        existing: <String>{deep},
        maxParentLevels: 0,
      );
      expect(() => notDeepEnough.locate(), throwsEngineException('找不到引擎可执行文件'));

      final deepEnough = locatorWith(
        currentDirectory: p.join(r'C:\root\sub', 'core'),
        existing: <String>{deep},
        maxParentLevels: 1,
      );
      expect(deepEnough.locate(), deep);
    });

    test('searched 每次调用都重置', () {
      final locator = locatorWith(
        existing: <String>{p.join(r'C:\app', engineFileName)},
      );
      locator.locate();
      final first = locator.searched.toList();
      expect(first, isNotEmpty);
      locator.locate();
      expect(locator.searched.toList(), first);
    });
  });
}
