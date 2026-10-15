/// 更新层公共出口（供 `lib/dsanima_core.dart` 汇总导出）。
///
/// * `version.dart` —— 版本号解析与比较；
/// * `release.dart` —— GitHub Release 的解析、挑选更新包、判定与错误文案。
///
/// 这一层**没有任何 I/O**（网络/解压/替换文件在宿主的 `state/update_adapter.dart`），
/// 所以它可以在 `flutter test` 里离线跑。
library;

export 'release.dart';
export 'version.dart';
