/// 回收站护栏单测（2026-10-12 第十四轮）。
///
/// [recyclablePaths] 是**唯一**决定"哪些路径允许删"的地方，所以它的每条判据都在这里
/// 钉一遍：漏一条的后果不是 UI 难看，而是**删掉用户的整库番剧或系统目录**。
///
/// ⚠️ 真正的 `SHFileOperation`（FFI）调用不在这里验 —— 那会真的动用户机器的回收站。
/// 它由 `test/recycle_bin_live_probe.dart` 在**临时文件**上真跑一次（`flutter test`
/// 不会自动跑没有 `_test` 后缀的文件）。
library;

import 'package:dsanima/domain/recycle_bin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 本仓库只跑 Windows，所以这里直接断言 Windows 形态的路径（其它测试同样如此）。
  const String root = r'F:\Anime';

  group('recyclablePaths：允许删的', () {
    test('下载根里面的文件（正常情形）', () {
      expect(
        recyclablePaths(<String>[r'F:\Anime\Show\ep01.mkv'], downloadRoot: root),
        <String>[r'F:\Anime\Show\ep01.mkv'],
      );
    });

    test('多文件 seed 的子目录里的文件也放行', () {
      expect(
        recyclablePaths(
          <String>[r'F:\Anime\[Group] Show\ep01.mkv', r'F:\Anime\[Group] Show\ep02.mkv'],
          downloadRoot: root,
        ).length,
        2,
      );
    });

    test('没给下载根时，深度够的绝对路径也放行（护栏其余条件仍生效）', () {
      expect(
        recyclablePaths(<String>[r'F:\Elsewhere\Show\ep.mkv']),
        <String>[r'F:\Elsewhere\Show\ep.mkv'],
      );
    });

    test('顺序保持（调用方按这个顺序报告"删了哪几个"）', () {
      expect(
        recyclablePaths(
          <String>[r'F:\Anime\b.mkv', r'F:\Anime\a.mkv'],
          downloadRoot: root,
        ),
        <String>[r'F:\Anime\b.mkv', r'F:\Anime\a.mkv'],
      );
    });
  });

  group('recyclablePaths：必须挡下的（每一条都对应一次事故）', () {
    test('下载根自己 —— 引擎给的 outputFolder 就是它（真机 dump 实证）', () {
      // 第十二轮真机 dump：outputFolder = `C:\Users\…\Downloads\Anime\`
      // 如果哪次把 outputFolder 交给删除，用户整库都没了。
      expect(recyclablePaths(<String>[r'F:\Anime'], downloadRoot: root), isEmpty);
      expect(recyclablePaths(<String>[r'F:\Anime\'], downloadRoot: root), isEmpty);
      // 盘的根目录同样不能删。
      expect(recyclablePaths(<String>[r'F:\'], downloadRoot: root), isEmpty);
      expect(recyclablePaths(<String>[r'C:\'], downloadRoot: root), isEmpty);
    });

    test('下载根的祖先 —— 用户给了子目录当根时，父目录绝不能被删', () {
      expect(
        recyclablePaths(
          <String>[r'F:\Anime\Show'],
          downloadRoot: r'F:\Anime\Show\Sub',
        ),
        isEmpty,
      );
    });

    test('相对路径（会指到"当前工作目录"，最容易误删）', () {
      expect(recyclablePaths(<String>[r'Show\ep01.mkv']).isEmpty, isTrue);
      expect(recyclablePaths(<String>['ep01.mkv']).isEmpty, isTrue);
    });

    test('含 `..` 的路径（拼出来的野路径）', () {
      expect(
        recyclablePaths(<String>[r'F:\Anime\..\Windows\System32\x.dll']).isEmpty,
        isTrue,
      );
    });

    test('太浅的目录（一两层就到底的那种，删掉是灾难级）', () {
      expect(recyclablePaths(<String>[r'F:\Anime']).isEmpty, isTrue);
      expect(recyclablePaths(<String>[r'F:\Users']).isEmpty, isTrue);
    });

    test('空串 / 纯空白', () {
      expect(recyclablePaths(<String>['', '   ']).isEmpty, isTrue);
    });

    test(r'大小写与尾部斜杠等价（Windows 大小写不敏感，F:\anime\ 就是根）', () {
      expect(
        recyclablePaths(<String>[r'F:\anime'], downloadRoot: r'F:\Anime\'),
        isEmpty,
      );
    });

    test('保护清单里的路径（例如正在播的那个文件）', () {
      expect(
        recyclablePaths(
          <String>[r'F:\Anime\Show\ep01.mkv'],
          downloadRoot: root,
          protectedPaths: <String>{r'F:\Anime\Show\ep01.mkv'},
        ),
        isEmpty,
      );
    });
  });
}
