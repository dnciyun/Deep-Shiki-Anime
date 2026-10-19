/// 扩展清单/目录解析里的一条 **问题** —— 解析器的公共词汇，单独一个文件。
///
/// 为什么单独一个文件：`manifest.dart` 与 `generic.dart`（通用扩展载荷）都要报同一种
/// 问题，但 `generic.dart` 不能反过来 import `manifest.dart`（manifest 要 import generic
/// 做分发，会成环）。这个类型只依赖它自己，于是两边都能用；`manifest.dart` 继续
/// `export` 它，既有 `import 'manifest.dart'` 的代码（含 `picture.dart`）不受影响。
library;

/// 一条**致命**问题（装了也用不了 / 根本不该装）或**非致命**提醒。
class ManifestIssue {
  const ManifestIssue(this.field, this.message);

  /// 出问题的字段路径（`files[2].path`），日志与界面都用它定位。
  final String field;

  /// 给用户看的一句话（中文，带"怎么办"）。
  final String message;

  @override
  String toString() => '$field: $message';
}
