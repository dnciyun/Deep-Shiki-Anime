/// 压缩包**条目级**守卫 —— 纯函数，不读盘、不解压。
///
/// 为什么要在解压**之前**逐条目过一遍：解压是唯一"把别人给的字节变成我的文件"的动作，
/// 也是唯一能一次写坏用户磁盘的动作。三类经典事故必须在这里挡住：
///
/// 1. **zip-slip**：条目名写成 `../../../../Windows/System32/x.dll` 或 `C:\x`，
///    解压器天真地拼接路径就把文件写到扩展目录外面；
/// 2. **解压炸弹**：几 KB 的 zip 解出几十 GB（`uncompressedSize`/`compressedSize`
///    比例离谱），或者几十万个小文件把 inode/目录项吃干；
/// 3. **夹带**：清单只声明了 3 个 shader，zip 里却塞了 500 个别的文件（比如替换宿主
///    自己的 dll、或者 drop 一个 exe 进数据目录）。判据很简单 —— **只允许清单里
///    声明过的文件**，多一个都不解。
///
/// 判定只依赖"条目表"（名字 + 两个大小），所以在读 zip 头之后、写任何字节之前
/// 就能跑完；测试也用内存里手搓的条目表，不必真造恶意 zip（`app` 侧另有真 zip 用例）。
library;

/// 条目数上限：一个 shader 包通常 < 20 个文件；512 已经非常宽松。
const int kPackageMaxEntries = 512;

/// 单个文件解压后大小上限（32 MB）：GLSL 都是几 KB，模型包另说 —— 1.1.0 只收资源型。
const int kPackageMaxEntryBytes = 32 * 1024 * 1024;

/// 整个包解压后总大小上限（96 MB）。
const int kPackageMaxTotalBytes = 96 * 1024 * 1024;

/// 条目总数上限（**含目录条目**）：目录条目本身不写内容，但每一条都要占解压器的工作量
/// 与内存，而且不受 [kPackageMaxEntries]（只数文件）约束 —— 恶意包可以塞几十万条 `a/b/`
/// 目录条目。2048 对真实扩展（几十个文件 + 几条目录）足够宽松。
const int kPackageMaxTotalEntries = 2048;

/// 单条目压缩比上限（解压后 / 压缩后）：正常 GLSL 文本约 3~8 倍，200 倍以上是炸弹。
const int kPackageMaxCompressionRatio = 200;

/// Windows 保留设备名（大小写不敏感，且**带扩展名也算**：`CON.txt` 依然打不开）。
const Set<String> _kReservedDeviceNames = <String>{
  'con', 'prn', 'aux', 'nul',
  'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
  'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
};

/// Windows 文件名里非法的字符（`/` 是分隔符，单独按路径处理）。
final RegExp _kIllegalChars = RegExp(r'[<>:"|?*\x00-\x1f]');

/// 单段名长度上限（NTFS 255，留余量）。
const int _kMaxSegmentLength = 200;

/// 相对路径总长上限（Windows MAX_PATH = 260，扩展目录前缀 + `.staging` 已占几十字符）。
const int _kMaxPathLength = 220;

/// 一个压缩包条目（只有"元数据"，没有内容）。
class PackageEntry {
  const PackageEntry({
    required this.name,
    required this.uncompressedSize,
    required this.compressedSize,
    this.isDirectory = false,
  });

  /// zip 里的原始条目名（用 `/` 分隔，相对包根）。
  final String name;

  /// 解压后字节数（zip 头声明的）。
  final int uncompressedSize;

  /// 压缩后字节数（zip 头声明的；`0` 对空文件是合法的）。
  final int compressedSize;

  /// 目录条目（`name` 以 `/` 结尾）。目录条目本身不写内容，只用于跟随创建。
  final bool isDirectory;
}

/// 守卫的阈值（测试要能收紧到很小，验证"超了就拒"）。
class PackageLimits {
  const PackageLimits({
    this.maxEntries = kPackageMaxEntries,
    this.maxTotalEntries = kPackageMaxTotalEntries,
    this.maxEntryBytes = kPackageMaxEntryBytes,
    this.maxTotalBytes = kPackageMaxTotalBytes,
    this.maxCompressionRatio = kPackageMaxCompressionRatio,
  });

  final int maxEntries;
  final int maxTotalEntries;
  final int maxEntryBytes;
  final int maxTotalBytes;
  final int maxCompressionRatio;
}

/// 一条守卫问题。
class PackageIssue {
  const PackageIssue(this.code, this.message, {this.entry});

  /// 机器可读的问题码（`unsafe-path` / `duplicate-entry` / `unexpected-file` /
  /// `missing-file` / `too-large` / `ratio` / `empty`）。
  final String code;

  /// 给用户/日志看的一句话。
  final String message;

  /// 出问题的条目名（如果有）。
  final String? entry;

  @override
  String toString() => entry == null ? '$code: $message' : '$code($entry): $message';
}

/// 守卫结论。[ok] 为 true 才能解压。
class PackageCheck {
  const PackageCheck({
    required this.issues,
    required this.totalUncompressedBytes,
    required this.fileCount,
  });

  final List<PackageIssue> issues;

  /// 所有文件条目声明的解压后总字节数（**只累加通过名字校验的条目**）。
  final int totalUncompressedBytes;

  /// 文件条目数（不含目录条目）。
  final int fileCount;

  bool get ok => issues.isEmpty;
}

/// 单条相对路径的安全判据：返回 null = 可用，否则返回"为什么不可用"（中文，给用户看）。
///
/// 规则（每条都对应 Windows 上的真实坑）：
/// * 空串 / 绝对路径（`/x`、`\\server\share`）/ 盘符（`C:`）/ UNC；
/// * 反斜杠：zip 规范用 `/`，出现 `\` 说明打包工具不对，且 Windows 会把 `a\..\b` 解析成穿越；
/// * 任何一段是 `.` 或 `..`（穿越）、空段（`a//b`）、纯空白；
/// * 段首尾带空格或点（Windows 存盘时会**悄悄去掉**，导致"清单里是 a.glsl、落盘是 a"）；
/// * Windows 非法字符 `< > : " | ? *` 与控制字符；
/// * 保留设备名（`CON`、`NUL`、`COM1`…，带扩展名也算）；
/// * 单段超长 / 整条路径超长（MAX_PATH 与解压器自己的临时前缀）。
String? unsafeRelativePathReason(String rawPath) {
  if (rawPath.isEmpty) return '路径为空';
  if (rawPath.length > _kMaxPathLength) {
    return '路径太长（${rawPath.length} 字符，上限 $_kMaxPathLength）';
  }
  if (rawPath.contains(r'\')) {
    return '用了反斜杠（压缩包里的路径必须用正斜杠 /）';
  }
  if (rawPath.startsWith('/')) return '是绝对路径（不能以 / 开头）';
  if (RegExp(r'^[A-Za-z]:').hasMatch(rawPath)) return '带了盘符（只能是相对包根的路径）';
  if (rawPath.contains(':')) return '含冒号（Windows 上不合法）';
  if (_kIllegalChars.hasMatch(rawPath)) return '含 Windows 不允许的字符（< > : " | ? * 或控制字符）';

  final List<String> segments = rawPath.split('/');
  for (final String segment in segments) {
    if (segment.isEmpty) return '含空路径段（不能有 //）';
    if (segment == '.' || segment == '..') return '含 . 或 .. 路径段（会解压到目录外面）';
    if (segment != segment.trim()) return '路径段「$segment」首尾有空格（Windows 会去掉）';
    // 只拒**尾点**：`a.` 与 `a` 在 NTFS 上是同一个名字；**前导点合法**（`.hidden` 是正常
    // 文件名），所以 `.config` 之类放行。
    if (segment.endsWith('.')) return '路径段「$segment」以点结尾（Windows 会去掉）';
    if (segment.length > _kMaxSegmentLength) {
      return '路径段太长（${segment.length} 字符，上限 $_kMaxSegmentLength）';
    }
    final String base = segment.split('.').first.toLowerCase();
    if (_kReservedDeviceNames.contains(base)) {
      return '「$segment」是 Windows 保留设备名，解压会失败';
    }
  }
  return null;
}

/// 校验一个包的条目表。
///
/// [expectedFiles]：**允许且必须**出现的文件条目（相对包根、大小写不敏感），
/// 一般 = `{'manifest.json'} ∪ 清单里 files 的 path`。多一个文件就报
/// `unexpected-file`（这是"夹带"的判据），少一个报 `missing-file`。
///
/// 目录条目不做白名单校验（它们只是"顺带建目录"），但仍然过名字校验。
PackageCheck checkExtensionPackage(
  List<PackageEntry> entries, {
  required Set<String> expectedFiles,
  PackageLimits limits = const PackageLimits(),
}) {
  final List<PackageIssue> issues = <PackageIssue>[];
  if (entries.isEmpty) {
    return const PackageCheck(
      issues: <PackageIssue>[PackageIssue('empty', '压缩包是空的')],
      totalUncompressedBytes: 0,
      fileCount: 0,
    );
  }
  if (entries.length > limits.maxTotalEntries) {
    return PackageCheck(
      issues: <PackageIssue>[
        PackageIssue(
          'too-large',
          '条目总数 ${entries.length} 个，超过上限 ${limits.maxTotalEntries}',
        ),
      ],
      totalUncompressedBytes: 0,
      fileCount: 0,
    );
  }

  final Set<String> expectedLower = <String>{
    for (final String path in expectedFiles) path.toLowerCase(),
  };
  final Set<String> seen = <String>{};
  final Set<String> present = <String>{};
  int totalBytes = 0;
  int fileCount = 0;

  for (final PackageEntry entry in entries) {
    final String name = entry.isDirectory && entry.name.endsWith('/')
        ? entry.name.substring(0, entry.name.length - 1)
        : entry.name;
    final String? unsafe = unsafeRelativePathReason(name);
    if (unsafe != null) {
      issues.add(PackageIssue('unsafe-path', unsafe, entry: entry.name));
      continue;
    }
    final String lower = name.toLowerCase();
    if (!seen.add(lower)) {
      issues.add(PackageIssue(
        'duplicate-entry',
        '条目重复（Windows 上后一个会覆盖前一个，行为不可控）',
        entry: entry.name,
      ));
      continue;
    }
    if (entry.isDirectory) continue;

    fileCount++;
    if (entry.uncompressedSize < 0 || entry.compressedSize < 0) {
      issues.add(PackageIssue('too-large', '条目大小是负数（zip 头坏了）', entry: entry.name));
      continue;
    }
    if (entry.uncompressedSize > limits.maxEntryBytes) {
      issues.add(PackageIssue(
        'too-large',
        '解压后 ${entry.uncompressedSize} 字节，超过单文件上限 ${limits.maxEntryBytes}',
        entry: entry.name,
      ));
      continue;
    }
    totalBytes += entry.uncompressedSize;

    if (!expectedLower.contains(lower)) {
      issues.add(PackageIssue(
        'unexpected-file',
        '包里多了一个没在清单里声明的文件（扩展只允许清单里列出的文件）',
        entry: entry.name,
      ));
      continue;
    }
    present.add(lower);

    if (entry.uncompressedSize > 0) {
      if (entry.compressedSize <= 0) {
        issues.add(PackageIssue(
          'ratio',
          '解压后 ${entry.uncompressedSize} 字节但压缩后是 ${entry.compressedSize} 字节，'
              '压缩比异常（疑似解压炸弹）',
          entry: entry.name,
        ));
      } else {
        final double ratio = entry.uncompressedSize / entry.compressedSize;
        if (ratio > limits.maxCompressionRatio) {
          issues.add(PackageIssue(
            'ratio',
            '压缩比 ${ratio.toStringAsFixed(0)}:1 超过上限 ${limits.maxCompressionRatio}:1'
                '（疑似解压炸弹）',
            entry: entry.name,
          ));
        }
      }
    }
  }

  if (fileCount > limits.maxEntries) {
    issues.add(PackageIssue(
      'too-large',
      '文件条目 $fileCount 个，超过上限 ${limits.maxEntries}',
    ));
  }
  if (totalBytes > limits.maxTotalBytes) {
    issues.add(PackageIssue(
      'too-large',
      '解压后总计 $totalBytes 字节，超过整包上限 ${limits.maxTotalBytes}',
    ));
  }
  for (final String expected in expectedFiles) {
    if (!present.contains(expected.toLowerCase())) {
      issues.add(PackageIssue(
        'missing-file',
        '清单里声明了这个文件，但压缩包里没有',
        entry: expected,
      ));
    }
  }

  return PackageCheck(
    issues: List<PackageIssue>.unmodifiable(issues),
    totalUncompressedBytes: totalBytes,
    fileCount: fileCount,
  );
}
