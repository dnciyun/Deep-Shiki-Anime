/// 「同一个端口只能有一份 provider 声明」—— 2026-10-20 用户报障的回归测试。
///
/// 用户原话：
/// > 「修复下系统目录选择器未接通」
///
/// 根因不是选择器坏了，而是 **`pickerPortProvider` 被声明了两份**：
/// `state/infra.dart` 一份、`state/providers.dart` 一份。装配根（`main.dart`）
/// 的 `overrideWithValue(FilePickerPort())` 命中的是 `providers.dart` 那份，
/// 而 `local_library.dart` 直接 import `infra.dart`，读到的是**从没被 override**
/// 的那份 ⇒ 点「本地 → 添加文件夹」就抛 `UnavailablePickerPort` 的
/// 「系统目录选择器未接通」。
///
/// 这种错编译不报、测试也不一定抓到（测试里 import 用了 `show` 时只看得到一份，
/// 覆写与读取恰好在同一份上）。所以这里直接钉住三件事：
/// 1. 两侧拿到的是**同一个** provider 对象；
/// 2. 用 `providers.dart` 那一侧做 override，`infra.dart` 那一侧读到同一实现；
/// 3. 端到端：按装配根的写法注入选择器之后，「添加文件夹」真的用上了它。
library;

import 'package:dsanima/domain/local_media.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/state/infra.dart' as infra;
import 'package:dsanima/state/local_library.dart';
import 'package:dsanima/state/providers.dart' as state;
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const String _picked = r'F:\Anime';

class _FakePicker implements PickerPort {
  int calls = 0;

  @override
  Future<String?> pickDirectory({String? title}) async {
    calls++;
    return _picked;
  }

  @override
  Future<String?> pickFile({String? title, List<String> extensions = const <String>[]}) async => null;
}

class _NoopScanner implements LocalMediaScannerPort {
  const _NoopScanner();

  @override
  bool get isSupported => true;

  @override
  Future<List<LocalFileStat>> scan(String folder) async => const <LocalFileStat>[];
}

void main() {
  test('pickerPortProvider 只有一份：infra 与 providers 是同一个 provider', () {
    expect(
      identical(state.pickerPortProvider, infra.pickerPortProvider),
      isTrue,
      reason: '两份同名 provider ⇒ 覆写只命中一份，另一份静默落回"未接通"',
    );
  });

  test('在 providers 那一侧 override，infra 那一侧读到同一个实现', () async {
    final _FakePicker fake = _FakePicker();
    final ProviderContainer container = ProviderContainer(
      overrides: [state.pickerPortProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);

    expect(identical(container.read(infra.pickerPortProvider), fake), isTrue);
    expect(await container.read(infra.pickerPortProvider).pickDirectory(), _picked);
  });

  test('按装配根的写法注入之后，「添加文件夹」真的用上了它（不是"未接通"）', () async {
    final _FakePicker fake = _FakePicker();
    final InMemoryKeyValueStore store = InMemoryKeyValueStore();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        infra.keyValueStoreProvider.overrideWithValue(store),
        // ⚠️ 这里刻意用 `providers.dart` 那一侧（= main.dart 的写法）：
        // 修之前这一步会把 override 打到"另一份"上，控制器读到的仍是未接通。
        state.pickerPortProvider.overrideWithValue(fake),
        infra.localMediaScannerProvider.overrideWithValue(const _NoopScanner()),
      ],
    );
    addTearDown(container.dispose);

    final String? added = await container.read(localLibraryProvider.notifier).addFolder();
    expect(added, _picked);
    expect(fake.calls, 1);
    expect(container.read(localLibraryProvider).folders, <String>[_picked]);
    expect(container.read(localLibraryProvider).error, isNull);
  });
}
