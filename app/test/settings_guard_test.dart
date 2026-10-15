/// 「有未保存的改动就拦一下」这条规则的单测（2026-10-12 第十六轮）。
///
/// 切页（`ui/shell.dart`）与关窗（`state/window_close.dart`）都只调
/// [resolveUnsavedSettings]，真正的三选对话框由设置页自己实现（它才握着草稿）。
/// 这里钉住三个边界：没挂处理器 / 不脏 / 拿不到 context。
library;

import 'package:dsanima/state/settings_guard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('设置页没挂出来（没开过设置）→ 直接放行，不弹任何东西', (WidgetTester tester) async {
    final ValueNotifier<SettingsDraftGuard?> holder = ValueNotifier<SettingsDraftGuard?>(null);
    addTearDown(holder.dispose);
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext c) {
            context = c;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(await resolveUnsavedSettings(holder, context), isTrue);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('设置页干净 → 放行，且不打扰用户（resolve 不该被调用）', (WidgetTester tester) async {
    int resolved = 0;
    final ValueNotifier<SettingsDraftGuard?> holder = ValueNotifier<SettingsDraftGuard?>(null);
    addTearDown(holder.dispose);
    holder.value = SettingsDraftGuard(
      dirty: () => false,
      resolve: (BuildContext context) async {
        resolved++;
        return false;
      },
    );
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext c) {
            context = c;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(await resolveUnsavedSettings(holder, context), isTrue);
    expect(resolved, 0);
  });

  testWidgets('脏了 → 交给设置页处理，它的答案就是能不能走', (WidgetTester tester) async {
    bool answer = false;
    final ValueNotifier<SettingsDraftGuard?> holder = ValueNotifier<SettingsDraftGuard?>(null);
    addTearDown(holder.dispose);
    holder.value = SettingsDraftGuard(
      dirty: () => true,
      resolve: (BuildContext context) async => answer,
    );
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext c) {
            context = c;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(await resolveUnsavedSettings(holder, context), isFalse, reason: '用户选了「留在这」');
    answer = true; // 用户改成「保存并生效」/「放弃改动」
    expect(await resolveUnsavedSettings(holder, context), isTrue);
  });

  testWidgets('拿不到 context → 放行（困住用户比丢一次未保存的改动更糟）', (WidgetTester tester) async {
    int resolved = 0;
    final ValueNotifier<SettingsDraftGuard?> holder = ValueNotifier<SettingsDraftGuard?>(null);
    addTearDown(holder.dispose);
    holder.value = SettingsDraftGuard(
      dirty: () => true,
      resolve: (BuildContext context) async {
        resolved++;
        return false;
      },
    );
    expect(await resolveUnsavedSettings(holder, null), isTrue);
    expect(resolved, 0);
  });
}
