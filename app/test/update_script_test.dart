/// 覆盖脚本"必须包含什么"（第三十九轮；2026-10-16 加固）。
///
/// 真机探针 `test/update_apply_probe.dart` 量的是"这段脚本真的跑得通"（解压、robocopy、
/// 强关占着旧 exe 的进程……），但它得手动跑（`_probe.dart` 不被 `flutter test` 发现）。
/// 这一条是**快的**守卫：钉住那些"少一句就静默出事"的句子 —— 等不到进程消失要**关掉它**、
/// 只关本安装目录下的、robocopy 不带 `/PURGE`、退出码要记下来、路径里的单引号要翻倍。
///
/// 少了这些的后果都不是报错，而是**看起来更新过了**：覆盖失败却照样把旧 exe 拉起来，
/// 用户下次启动才被告知"上次更新没有生效"。
library;

import 'package:dsanima/state/update_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一份典型的脚本（安装目录带空格，路径全在 `DSAnima-data\update` 下）。
String _script({
  String install = r'C:\Users\some user\Desktop\DSAnima',
  String source = r'C:\Users\some user\Desktop\DSAnima\DSAnima-data\update\extract',
  String log = r'C:\Users\some user\Desktop\DSAnima\DSAnima-data\update\apply.log',
}) => buildUpdateScript(source: source, install: install, log: log, work: source);

void main() {
  test('要有"等不到就关掉它"的落点，而不是等满时间再硬复制', () {
    final String text = _script();
    // 谁会被等/被关：宿主与边车（两个都会锁着安装目录里的文件）。
    expect(text, contains('Get-Process -Name'));
    expect(text, contains("@('dsanima', 'rqbit-engine')"));
    // 先优雅等（宿主正常退出 <3 秒），到点还在就自己动手。
    expect(text, contains(r'$grace = 45'));
    expect(text, contains(r'(Get-Date).AddSeconds($grace)'));
    expect(text, contains('still running after'));
    expect(text, contains(r'Stop-Process -Id $proc.Id -Force'));
    // 老写法（等满 10 分钟然后照样复制）**必须没有了** —— 那在有第二个实例/边车卡住时
    // 必然复制失败，却还是把旧 exe 拉起来。
    expect(text, isNot(contains('AddMinutes(10)')), reason: '不能回到"等满时间再硬复制"');
    expect(text, isNot(contains('timeout waiting for exit; copying anyway')));
  });

  test('只关**本安装目录**里的进程：另一个文件夹的 DSAnima 不该被误杀', () {
    final String text = _script();
    expect(text, contains(r"$prefix = $dst.TrimEnd('\') + '\'"));
    expect(text, contains(r"$path -like ($prefix + '*')"));
    // 路径读不出来（权限/UAC）时也要当目标 —— 不然覆盖注定失败。
    expect(text, contains(r'if (-not $path -or'));
  });

  test('robocopy：/E 但不带 /PURGE，记下退出码，≥8 时再关一次、再试一次', () {
    final String text = _script();
    expect(text, contains(r'/E /R:3 /W:1 /NFL /NDL /NJH /NJS /NP'));
    expect(
      text,
      isNot(contains('/PURGE')),
      reason: '不带 /PURGE：新包里没有的文件要留着（用户自己放的东西、上一版留下的组件）',
    );
    expect(text, contains(r'robocopy exit='), reason: '退出码是排查的唯一线索');
    expect(text, contains(r'($rc -lt 8 -or $round -ge 2) { break }'), reason: '0-7 算成功，≥8 重试一次');
    expect(text, contains('robocopy reported failures'));
    expect(text, contains(r'WARNING: robocopy exit='), reason: '没换成功不能只在心里失败');
    expect(text, contains(r'Start-Process -FilePath $exe'), reason: '覆盖完要用新版本把程序拉起来');
  });

  test('路径里的单引号按 PowerShell 单引号规则翻倍（不然脚本直接语法错）', () {
    final String text = buildUpdateScript(
      source: r"C:\a b\it's\extract",
      install: r"C:\a b\it's\install",
      log: r"C:\a b\it's\apply.log",
      work: r"C:\a b\it's\extract",
    );
    expect(text, contains(r"$dst = 'C:\a b\it''s\install'"));
    expect(text, contains(r"$src = 'C:\a b\it''s\extract'"));
    expect(text, contains(r"$log = 'C:\a b\it''s\apply.log'"));
  });

  test('收尾：清掉解压目录（约 112MB）并删掉自己', () {
    final String text = _script();
    expect(text, contains(r'Remove-Item -LiteralPath $work -Recurse -Force'));
    expect(text, contains(r'$MyInvocation.MyCommand.Path'));
  });
}
