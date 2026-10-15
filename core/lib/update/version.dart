/// 版本号（第三十九轮：检查更新走 GitHub Releases）。
///
/// 为什么比较规则放在 core 而不是宿主 UI：**它全是纯逻辑** —— 解析标签、比较大小、
/// 判断"更新包在哪儿"。放这里一份，宿主 UI / 探针 / 以后可能的 CLI 共用同一套判据，
/// 而且能在 `core/test` 里直接喂字符串断言，不必为了"v1.2.3 比 v1.2.2 新"起一个 UI。
library;

/// 版本号：`major.minor.patch`（可选 `+build`）。
///
/// * 发布标签写成 `v1.2.3`（GitHub 上大多数项目如此），也容忍不带 `v`；
/// * `+build` 对应 pubspec 的 `version: 1.2.3+4` —— **参与比较**：
///   同一个版本号下 `1.2.3+4` 比 `1.2.3` 新（重发一次打包也能被认出来）；
/// * 预发布后缀（`-rc1`）只用于解析成功，**不参与比较**：GitHub 的
///   `/releases/latest` 本来就不会返回预发布版，这里不为此加一套排序规则。
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, {this.build = 0});

  final int major;
  final int minor;
  final int patch;

  /// 构建号（pubspec 里 `+` 后面那个）；缺失 = 0。
  final int build;

  /// 解析版本号；不是版本号时返回 null（**不抛**：调用方要能"看不懂就说不懂"）。
  ///
  /// 容忍：两边空白 / `v`·`V` 前缀 / 少写段（`1.2` → `1.2.0`）/ `+build` / `-rc1` 后缀。
  /// 拒绝：`latest`、`v`、`1.2.3.4`、负数、含空段的 `1..2`。
  static AppVersion? tryParse(String? raw) {
    if (raw == null) return null;
    String text = raw.trim();
    if (text.isEmpty) return null;
    if (text.startsWith('v') || text.startsWith('V')) text = text.substring(1);

    int build = 0;
    final int plus = text.indexOf('+');
    if (plus >= 0) {
      final String tail = text.substring(plus + 1).trim();
      text = text.substring(0, plus);
      // `+4` / `+4.1` / `+4-beta` 都取开头那段数字。
      final RegExpMatch? digits = RegExp(r'^\d+').firstMatch(tail);
      build = digits == null ? 0 : int.parse(digits.group(0)!);
    }
    final int dash = text.indexOf('-');
    if (dash >= 0) text = text.substring(0, dash);

    text = text.trim();
    if (text.isEmpty) return null;
    final List<String> parts = text.split('.');
    if (parts.length > 3) return null;
    final List<int> nums = <int>[];
    for (final String part in parts) {
      final String piece = part.trim();
      if (piece.isEmpty) return null;
      final int? value = int.tryParse(piece);
      if (value == null || value < 0) return null;
      nums.add(value);
    }
    return AppVersion(
      nums[0],
      nums.length > 1 ? nums[1] : 0,
      nums.length > 2 ? nums[2] : 0,
      build: build,
    );
  }

  /// 发布标签形态：`v1.2.3`（**不带** build —— 标签里带 `+` 在 URL 里很别扭）。
  String get tag => 'v$major.$minor.$patch';

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    return build.compareTo(other.build);
  }

  /// 比较算子（`Comparable` 只保证 [compareTo]；
  /// `package:collection` 的 `ComparableExtension` 不在这里的依赖里，自己写四行更省事）。
  bool operator <(AppVersion other) => compareTo(other) < 0;
  bool operator <=(AppVersion other) => compareTo(other) <= 0;
  bool operator >(AppVersion other) => compareTo(other) > 0;
  bool operator >=(AppVersion other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch &&
      other.build == build;

  @override
  int get hashCode => Object.hash(major, minor, patch, build);

  /// 纯版本号（日志/比较用）：`1.2.3` 或 `1.2.3+4`。
  @override
  String toString() => build > 0 ? '$major.$minor.$patch+$build' : '$major.$minor.$patch';

  /// 界面上的写法：带 `v`，构建号另起一句（`v1.2.3（构建 4）`）。
  String get label => build > 0 ? 'v$major.$minor.$patch（构建 $build）' : 'v$major.$minor.$patch';
}
