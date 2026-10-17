/// 应用数据的**唯一根目录**（便携式）+ 旧版本遗留目录的清理。
///
/// ## 便携式（用户 2026-10-11 明确要求）
///
/// 用户原话：「我刚解压的按理说应该是重置的，不在本地留垃圾，一套文件夹一套设置，
/// 重新解压出来的就是初始化的程序」。
///
/// 所以数据根目录**跟着程序目录走**：
/// ```
/// <dsanima.exe 所在目录>\DSAnima-data\      ← 全部运行时数据都在这一个文件夹里
///   store\dsanima.hive                     设置 / 订阅 / 队列 / 源缓存
///   store\shikiin.hive                     主窗口那侧的播放器存档
///   player-store\shikiin_player.hive       播放窗口自己的存档（独立引擎，必须分开）
///   logs\shikiin-*.log                     诊断日志
///   engine\                                引擎状态（session.json / engine.log / dht.json）
///   anime4k_v4.1\                          超分 shader 解包目录（Anime4K + 随包 GLSL）
///   dsanima\                              托盘图标 + 封面缓存
/// ```
/// 于是：**解压一份 = 一套独立设置**（新落地的副本没有 `store\dsanima.hive`
/// ⇒ `firstRunCompleted` 为 false ⇒ 首启向导照常出现），**删掉文件夹 = 干净卸载**。
///
/// ### 什么时候不这么做
/// * `DSANIMA_DATA_DIR=<path>` 环境变量优先（CI / 探针 / 想把数据放到别处）；
/// * 程序目录**不可写**时（装在 `C:\Program Files` 之类）回落到
///   `getApplicationSupportDirectory()`（Windows = `%APPDATA%\<company>\<product>`）——
///   这是 Windows 的常识约束，启动日志里会写明用了哪条路。
///
/// ### 与上一版的关系
/// 上一版（同一天早些时候）把数据统一到 `%APPDATA%\com.dsanima\dsanima\store`。
/// 便携化之后**不再从那里读**：新位置没有 box 就是一套新设置 —— 用户要的就是这个。
/// 旧位置由 [cleanupLegacyDataLocations] 清掉（它已经不装任何东西了）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory, getApplicationSupportDirectory;

/// 便携式数据目录名（挂在 exe 同目录下）。
///
/// **不要**叫 `data`：Flutter 的运行期资产就在 `<exe目录>\data\`（`flutter_assets`），
/// 撞名会把用户数据塞进资产目录里。
const String kPortableDataDirName = 'DSAnima-data';

/// 覆盖数据根目录的环境变量（调试 / 探针 / 多实例）。
const String kDataDirEnvVar = 'DSANIMA_DATA_DIR';

/// 数据根目录下的子目录名。
const String kStoreDirName = 'store';
const String kPlayerStoreDirName = 'player-store';

/// 数据根目录的解析结果（写日志 / 单测断言用）。
class DataRoot {
  const DataRoot({
    required this.path,
    required this.portable,
    required this.exeDir,
    this.fallbackReason,
  });

  /// 数据根目录的绝对路径。
  final String path;

  /// true = 数据跟着程序目录（便携式：一套文件夹一套设置）。
  final bool portable;

  /// 程序（dsanima.exe）所在目录。
  final String exeDir;

  /// 非便携的原因（环境变量 / 不可写），给日志用。
  final String? fallbackReason;

  @override
  String toString() => 'DataRoot($path, portable=$portable'
      '${fallbackReason == null ? '' : ', reason=$fallbackReason'})';
}

/// 解析数据根目录。**必须先于任何写盘**（Hive / 日志 / Anime4K 解包）调用。
///
/// 四个参数都是给单测注入的；生产调用不传，走 `Platform.resolvedExecutable` 与真实环境变量。
Future<DataRoot> resolveDataRoot({
  Directory? exeDir,
  String? portableCandidate,
  String? envOverride,
  Directory? fallbackDir,
}) async {
  final Directory exe = exeDir ?? File(Platform.resolvedExecutable).parent;
  final String override = (envOverride ?? Platform.environment[kDataDirEnvVar] ?? '').trim();
  if (override.isNotEmpty) {
    final Directory dir = Directory(override);
    await dir.create(recursive: true);
    return DataRoot(
      path: dir.path,
      portable: false,
      exeDir: exe.path,
      fallbackReason: '$kDataDirEnvVar 指定',
    );
  }

  final String candidate = portableCandidate ?? p.join(exe.path, kPortableDataDirName);
  // 可写性用**真的建一次目录**来判断：Windows 上只看 ACL 不可靠，
  // 而"能不能创建子目录"就是接下来真正要做的事。
  try {
    final Directory dir = Directory(candidate);
    await dir.create(recursive: true);
    final File probe = File(p.join(dir.path, '.writable-probe'));
    await probe.writeAsString('ok', flush: true);
    await probe.delete();
    return DataRoot(path: dir.path, portable: true, exeDir: exe.path);
  } catch (error) {
    final Directory dir = fallbackDir ?? await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return DataRoot(
      path: dir.path,
      portable: false,
      exeDir: exe.path,
      fallbackReason: '程序目录不可写（$error）',
    );
  }
}

/// 数据根目录下的 `store`（Hive box 都在这）。
Directory storeDirOf(Directory dataRoot) =>
    Directory(p.join(dataRoot.path, kStoreDirName));

/// 播放子窗口自己的 Hive 目录。
///
/// 必须和主窗口的分开：Hive 的 `<box>.lock` 是**排他锁**，两个独立 Flutter 引擎
/// 开同一个 box 会抛 `PathAccessException: lock failed`，而那个异常发生在 `runApp`
/// **之前** ⇒ 弹出窗口是一片白（实测踩过）。
Directory playerStoreDirOf(Directory dataRoot) =>
    Directory(p.join(dataRoot.path, kPlayerStoreDirName));

/// 便携化之后，这些位置都**不再被读写**，属于纯粹的遗留（用户：
/// 「不在本地留垃圾」）。清理结果只用于日志。
class LegacyCleanup {
  const LegacyCleanup({required this.removed});

  static const LegacyCleanup none = LegacyCleanup(removed: <String>[]);

  /// 真删掉的路径（含文件与目录）。
  final List<String> removed;

  bool get changed => removed.isNotEmpty;
}

/// 清掉旧版本写在**系统用户目录**里的数据。
///
/// 清理清单（全部是 DSAnima 自己写的、且新版不再读的东西）：
/// * `<roaming>\com.dsanima\dsanima`（上一版的 support 目录：logs / engine /
///   player-store / store / anime4k / 托盘图标 / 封面缓存）；
/// * `<roaming>\com.dsanima\DSAnima`（更早的 appId 拼法；Windows 大小写不敏感时
///   它就是上面那一个，靠真实路径比较不会重复删）；
/// * `<documents>\DSAnima`（hive_flutter 时代的 Hive 位置）；
/// * `<local>\rqbit\dht\cache\dht.json`（librqbit 默认 DHT 路由表；新版把 DHT 放进
///   数据根目录的 `engine\dht.json`），顺带清掉空的 `rqbit` 目录。
///
/// **三条保险**（单测覆盖）：绝不删 [dataRoot] 自己（比真实路径）、绝不删数据根目录的
/// 祖先目录、任何一步失败都只记进返回结果不抛。
///
/// [roamingDir] / [documentsDir] / [localDir] 给单测注入。
Future<LegacyCleanup> cleanupLegacyDataLocations({
  required Directory dataRoot,
  Directory? roamingDir,
  Directory? documentsDir,
  Directory? localDir,
  bool includeDhtCache = true,
}) async {
  final List<String> removed = <String>[];
  final String rootCanonical = _canonicalPath(dataRoot);

  Future<void> removeIfOutsideRoot(Directory dir) async {
    if (!dir.existsSync()) return;
    final String canonical = _canonicalPath(dir);
    // 只删"不在数据根目录里、也不是它的祖先"的目录。
    if (canonical == rootCanonical) return;
    if (rootCanonical.startsWith('$canonical${p.separator}')) return;
    try {
      await dir.delete(recursive: true);
      removed.add(dir.path);
    } catch (_) {
      // 删不掉（被占用/权限）不该影响启动。
    }
  }

  try {
    final Directory roaming = roamingDir ?? defaultRoamingDir();
    if (roaming.path.isNotEmpty) {
      final Directory vendor = Directory(p.join(roaming.path, 'com.dsanima'));
      await removeIfOutsideRoot(Directory(p.join(vendor.path, 'dsanima')));
      await removeIfOutsideRoot(Directory(p.join(vendor.path, 'DSAnima')));
      // 厂商目录空了就一起收掉。
      try {
        if (vendor.existsSync() &&
            vendor.listSync().isEmpty &&
            _canonicalPath(vendor) != rootCanonical) {
          await vendor.delete();
          removed.add(vendor.path);
        }
      } catch (_) {}
    }
  } catch (_) {}

  try {
    final Directory documents = documentsDir ?? await getApplicationDocumentsDirectory();
    await removeIfOutsideRoot(Directory(p.join(documents.path, 'DSAnima')));
  } catch (_) {}

  if (includeDhtCache) {
    try {
      final Directory local = localDir ?? defaultLocalDir();
      if (local.path.isNotEmpty) {
        final Directory rqbit = Directory(p.join(local.path, 'rqbit'));
        final File dht = File(p.join(rqbit.path, 'dht', 'cache', 'dht.json'));
        if (dht.existsSync()) {
          await dht.delete();
          removed.add(dht.path);
        }
        try {
          // 只在"一个文件都不剩"时才收目录：standalone rqbit 自己的状态文件还在的话
          // 我们一个都不碰。
          final bool noFilesLeft = rqbit.existsSync() &&
              rqbit.listSync(recursive: true).whereType<File>().isEmpty;
          if (noFilesLeft) {
            await rqbit.delete(recursive: true);
            removed.add(rqbit.path);
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  return LegacyCleanup(removed: removed);
}

/// 解析真实路径（判断两个 `Directory` 是不是同一个目录）。
///
/// NTFS 会在解析后回填**磁盘上真实的大小写**：所以同一个目录解析结果相同，而"真的
/// 存在两个只差大小写的目录"（目录级大小写敏感）解析结果不同。
String _canonicalPath(Directory dir) {
  try {
    return p.canonicalize(dir.resolveSymbolicLinksSync());
  } catch (_) {
    return p.canonicalize(dir.path);
  }
}

/// 「我的文档」目录：旧版 Hive 落点（`hive_flutter` 的
/// `getApplicationDocumentsDirectory()/DSAnima`）。
///
/// 用 platform channel 问系统，**不拼 `USERPROFILE\Documents`**：文档目录可能被
/// OneDrive 重定向、也可能被本地化改名。
Future<Directory> defaultDocumentsDir() => getApplicationDocumentsDirectory();

/// `%APPDATA%`（旧版 support 目录的根）。
///
/// 语义与 [cleanupLegacyDataLocations] 的 `roamingDir` 注入一致：传的是**根目录**，
/// 函数内部再拼 `com.dsanima\...`。
Directory defaultRoamingDir() => Directory(Platform.environment['APPDATA'] ?? '');

/// `%LOCALAPPDATA%`（librqbit 默认 DHT 缓存所在盘的根）。
Directory defaultLocalDir() => Directory(Platform.environment['LOCALAPPDATA'] ?? '');
