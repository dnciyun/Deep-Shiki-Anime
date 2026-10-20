/// `DsDesktopPicker`：目录走自己实现的 Win32 对话框（可注入），文件仍走 file_picker。
///
/// 为什么不测真对话框：这里跑的是 headless 测试，弹不了原生窗口。真正要钉的是
/// **失败怎么表现**——用户 2026-10-20 报「刚选完会闪退一下」就是这条路上的原生崩溃
/// （comdlg32 · 0xc0000005），新的实现必须做到：取消 = 静默返回 null、
/// 出错 = 抛 `PortUnavailableException`（页面据此退回「手动输入路径」），
/// 绝不让一次"打不开"变成"进程没了"。
library;

import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/state/win32_picker.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeFilePicker implements PickerPort {
  String? picked;
  int calls = 0;

  @override
  Future<String?> pickDirectory({String? title}) async => throw UnimplementedError();

  @override
  Future<String?> pickFile({String? title, List<String> extensions = const <String>[]}) async {
    calls++;
    return picked;
  }
}

void main() {
  test('用户取消：返回 null，不抛异常', () async {
    final DsDesktopPicker picker = DsDesktopPicker(
      folderDialog: ({String? title}) async => (path: null, error: null),
      filePicker: _FakeFilePicker(),
    );
    expect(await picker.pickDirectory(title: '选目录'), isNull);
  });

  test('选到目录：去掉首尾空白后返回', () async {
    final DsDesktopPicker picker = DsDesktopPicker(
      folderDialog: ({String? title}) async => (path: r'  F:\Anime\番剧  ', error: null),
      filePicker: _FakeFilePicker(),
    );
    expect(await picker.pickDirectory(), r'F:\Anime\番剧');
  });

  test('对话框打不开：抛 PortUnavailableException，原因在 hint 里（页面据此退回手输）', () async {
    final DsDesktopPicker picker = DsDesktopPicker(
      folderDialog: ({String? title}) async =>
          (path: null, error: 'COM 初始化失败：0x80010106'),
      filePicker: _FakeFilePicker(),
    );
    await expectLater(
      picker.pickDirectory(),
      throwsA(
        isA<PortUnavailableException>()
            .having((PortUnavailableException e) => e.message, 'message', contains('目录选择器'))
            .having((PortUnavailableException e) => e.hint, 'hint', contains('0x80010106')),
      ),
    );
  });

  test('空路径当成"什么都没选"（不返回空串）', () async {
    final DsDesktopPicker picker = DsDesktopPicker(
      folderDialog: ({String? title}) async => (path: '   ', error: null),
      filePicker: _FakeFilePicker(),
    );
    expect(await picker.pickDirectory(), isNull);
  });

  test('选文件仍然交给 file_picker（这条链路不动）', () async {
    final _FakeFilePicker files = _FakeFilePicker()..picked = r'F:\a\pack.zip';
    final DsDesktopPicker picker = DsDesktopPicker(
      folderDialog: ({String? title}) async => (path: null, error: null),
      filePicker: files,
    );
    expect(await picker.pickFile(extensions: <String>['zip']), r'F:\a\pack.zip');
    expect(files.calls, 1);
  });

  test('默认实现指向真正弹窗的那个函数（防"接错了"）', () {
    const DsDesktopPicker picker = DsDesktopPicker();
    expect(identical(picker.folderDialog, win32FolderDialog), isTrue);
  });
}
