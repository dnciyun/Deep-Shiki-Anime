/// 启动失败窗口：`main()` 装配不下去时，用户必须**看得见原因**。
///
/// 审查发现的那条路径：后台常驻的实例还占着 `dsanima.lock`，第二个实例
/// `HiveKeyValueStore.open('dsanima')` 抛 `PathAccessException`，旧代码让异常从
/// `main()` 冒出去 → 进程结束、窗口起不来，用户双击图标看到的是"什么都没发生"。
/// 这里只钉住那个窗口本身（`main()` 的真实装配无法在单测里跑）。
library;

import 'package:dsanima/app.dart';
import 'package:dsanima/domain/error_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('启动失败窗口把「为什么」和「怎么办」都摆出来', (WidgetTester tester) async {
    await tester.pumpWidget(
      const DsStartupFailureApp(
        failure: DsFailure(
          '文件系统错误',
          hint: '检查数据目录是否存在且可写；磁盘是否已满',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('DSAnima 没能启动'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(dsStartupFailureTextKey)).data,
      '文件系统错误',
      reason: '失败原因必须原样显示（describeFailure 的中文口径）',
    );
    expect(find.textContaining('怎么办：检查数据目录是否存在且可写'), findsOneWidget);
    expect(
      find.textContaining('托盘'),
      findsOneWidget,
      reason: '后台常驻撞锁是最常见的原因，要给用户可行动的下一步',
    );
  });

  testWidgets('没有 hint 时也不崩（只显示原因）', (WidgetTester tester) async {
    await tester.pumpWidget(
      const DsStartupFailureApp(failure: DsFailure('端口被占用')),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(dsStartupFailureTextKey)).data, '端口被占用');
    expect(find.textContaining('怎么办：'), findsNothing);
  });
}
