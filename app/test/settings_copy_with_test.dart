/// `AppSettings.copyWith` 的「清空开关」契约。
///
/// 背景（审查发现）：`copyWith` 的 `?? this.x` 语义下，传 `null` 表示"**不改**"，
/// 于是"清空输入框"这种动作永远清不掉已有的值 —— 输入框看着是空的、设置里还是旧值。
/// 设置页的下载目录与引擎路径都写着「留空 = 用默认 / 自动查找」，就必须有对应的
/// `clearXxx` 开关把值**真的**清成 null（`clearDownloadDir` 先有，`clearEnginePath` 后补）。
library;

import 'package:dsanima/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const AppSettings base = AppSettings(
    downloadDir: r'F:\Anime',
    enginePath: r'F:\old\rqbit-engine.exe',
  );

  test('不传就是不改（null 的 ?? 语义）', () {
    expect(base.copyWith().enginePath, r'F:\old\rqbit-engine.exe');
    expect(base.copyWith().downloadDir, r'F:\Anime');
  });

  test('clearEnginePath: true 真的把引擎路径清成 null（留空 = 自动查找）', () {
    expect(base.copyWith(clearEnginePath: true).enginePath, isNull);
  });

  test('clearDownloadDir: true 真的把下载目录清成 null（留空 = 用默认目录）', () {
    expect(base.copyWith(clearDownloadDir: true).downloadDir, isNull);
  });

  test('清空其中一个字段，别的字段一个都不许动', () {
    final AppSettings cleared = base.copyWith(clearEnginePath: true);
    expect(cleared.downloadDir, r'F:\Anime');
    expect(cleared.toJson().length, base.toJson().length);
  });

  test('传了新值就以新值为准（清空开关不该盖掉新值）', () {
    expect(
      base.copyWith(enginePath: r'F:\new\rqbit-engine.exe').enginePath,
      r'F:\new\rqbit-engine.exe',
    );
    expect(
      base.copyWith(downloadDir: r'F:\NewDir').downloadDir,
      r'F:\NewDir',
    );
  });
}
