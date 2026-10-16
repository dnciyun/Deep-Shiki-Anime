/// 本构建的版本号（第三十九轮：检查更新时的比较基准）。
///
/// ⚠️ **必须与 `app/pubspec.yaml` 的 `version:` 同步**（`1.0.3+9` ↔
/// `AppVersion(1, 0, 3, build: 9)`）。`app/test/app_version_test.dart` 会直接读
/// pubspec 对账：漏改一处，检查更新就会永远说"有新版本"（或者发布了新版却没提示）。
///
/// 为什么用一个常量而不是 `package_info_plus`：
/// * 那个插件要加一份原生代码进包，而这里要的信息**编译期就已知**；
/// * 依赖 pubspec 里 `version:` 生成的宏还没有稳定形态；
/// * 一条 `const` + 一个对账测试，比多一个插件便宜得多，也不会在
///   `flutter run`（没走打包脚本）时给出 0.0.0 这种假版本。
library;

import 'package:dsanima_core/update/update.dart';

/// 当前构建的版本（发布标签就是它的 [AppVersion.tag]）。
const AppVersion kAppVersion = AppVersion(1, 0, 3, build: 9);
