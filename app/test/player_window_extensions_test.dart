/// 扩展变更 → **已打开的播放窗口**热重载的接线守卫（1.1.0 第六十四轮）。
///
/// 用户实测：「删除扩展后，超分内的 anime4k-mini 不会消失，只有重启后才会没」。
/// 链路是：扩展页装/卸/启停成功 → 状态机 `extensionsRevisionProvider` +1 →
/// `main.dart` 监听 → `PlayerWindowService.notifyExtensionsChanged()` →
/// 子窗口收到 `kMethodExtensionsChanged` → 重扫 + 回退。
///
/// 为什么要源码守卫：这条链路跨三个文件、中间任何一截被删掉都**不会报错**，
/// 只会安静地退化成"重启才生效"（正是用户报的现象）。真跑窗口通道需要真窗口，
/// 单测里跑不了，所以用"每一截都在"的守卫钉住接线，行为本身由
/// `extension_schemes_test.dart` 的 `refreshExtensionSchemes` 用例覆盖。
library;

import 'dart:io';

import 'package:dsanima/state/player_window.dart';
import 'package:flutter_test/flutter_test.dart';

/// 源码里去掉注释行后的代码文本（注释会引用这些名字做说明，不算接线）。
String _codeOnly(String path) => File(path)
    .readAsLinesSync()
    .where((String line) {
      final String s = line.trimLeft();
      return !s.startsWith('//') && !s.startsWith('///') && !s.startsWith('*');
    })
    .join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('接线守卫（少一截就退化成"重启才生效"）', () {
    test('主窗口侧：常量 + 发送方法都在 player_window.dart', () {
      final String code = _codeOnly('lib/state/player_window.dart');
      expect(code.contains("const String kMethodExtensionsChanged = 'extensionsChanged';"), isTrue);
      expect(code.contains('Future<void> notifyExtensionsChanged()'), isTrue);
      expect(code.contains('invokeMethod<void>(kMethodExtensionsChanged)'), isTrue);
      // 没有窗口时必须是**空操作**（不是抛异常：装扩展不该因为"没开窗"而失败）。
      final int noWindowBranch = code.indexOf('if (c == null) {');
      expect(noWindowBranch, greaterThan(-1));
    });

    test('子窗口侧：收到方法名就重扫（player_window_app.dart）', () {
      final String code = _codeOnly('lib/ui/player_window_app.dart');
      expect(code.contains('case kMethodExtensionsChanged:'), isTrue);
      expect(code.contains('_reloadExtensionSchemes()'), isTrue);
      expect(code.contains('refreshExtensionSchemes('), isTrue);
      expect(code.contains('resolveDataRoot()'), isTrue, reason: '子窗口自己按数据根重扫');
    });

    test('主窗口装配根：监听扩展版本号并通知（main.dart）', () {
      final String code = _codeOnly('lib/main.dart');
      expect(code.contains('extensionsRevisionProvider'), isTrue);
      expect(code.contains('notifyExtensionsChanged()'), isTrue);
    });
  });

  group('无窗口时不报错', () {
    test('notifyExtensionsChanged 在没有播放窗口时静默返回（装/卸扩展不能被它拖失败）', () async {
      final PlayerWindowService service = PlayerWindowService(
        logger: (String message) {},
      );
      expect(service.hasWindow, isFalse);
      await expectLater(service.notifyExtensionsChanged(), completes);
    });

    test('未装配的占位实例同样不抛', () async {
      final PlayerWindowService service = PlayerWindowService.unconfigured();
      await expectLater(service.notifyExtensionsChanged(), completes);
    });
  });
}
