/// 扩展安装**真实现**（1.1.0 M3/T14）：下载 → 校验 → 解压到 `.staging/` → 原子替换 → 卸载。
///
/// ⚠️ 只有 `main.dart`（装配根）可以 import 本文件 —— 与 `update_adapter.dart` /
/// `engine_bootstrap.dart` 同规矩：UI 与 `state/extensions.dart` 只认
/// `domain/extensions_port.dart` 的 [ExtensionsPort]，这样上游改 IO 时宿主仍能独立编译、
/// 组件测试也仍然能注入假端口（**不会真下东西、不真删文件**）。
///
/// ## 磁盘布局（`root` = `<数据根>/extensions`，由装配根注入）
/// ```
/// root/state.json                      已安装清单（原子写：state.json.tmp → rename）
/// root/<id>/manifest.json + files…     装好的扩展（目录名 = 清单 id）
/// root/.staging/<id>.<ts>/             解压中；只有全部校验通过才会 rename 出去
/// root/.trash/<id>.<ts>/               旧版本（供回滚；成功进回收站后消失）
/// root/.downloads/<id>.<ts>.part       下载中（成功后读进内存即删）
/// ```
/// 与 `docs/specs/…extension-format.md` / `core/lib/extensions/package_guard.dart` 的分工：
/// * **判据**在 core（`parseExtensionManifest` / `checkExtensionPackage`），这里只负责
///   把字节搬来搬去并按结论落盘；
/// * 本文件**不做任何界面文案决策**，抛出的 [ExtensionFailure] 只带"发生了什么 + 怎么办"。
///
/// ## 六条契约的落地位置（`domain/extensions_port.dart` 文件头）
/// 1. 原子性：全程只写 `.staging/`，全部校验通过才 `rename` 进 `root/<id>/`；旧版本先
///    `rename` 进 `.trash/`。失败/取消清临时目录，**正式目录不出现半成品**；
/// 2. 校验不可省：`checkExtensionPackage`（zip-slip / 炸弹 / 夹带）→ 逐文件 `size`+`sha256`；
///    请求里给了 zip 整体 `sha256` 就一并校验；
/// 3. 取消要干净：每个下载块、每个解压文件前都问一次 `isCancelled()`，抛
///    [ExtensionInstallCancelled]，删 `.part`/`.staging`；
/// 4. 失败要可行动：所有底层异常包成 [ExtensionFailure]（中文 + hint），不静默吞；
/// 5. 状态以磁盘为准：`scan()` 读 `state.json` 并与目录对账（目录没了→条目作废并回写；
///    目录在但无记录→读目录里的 manifest 补一条 `enabled=true`）；
/// 6. 卸载进回收站：默认 `moveToRecycleBin`，可注入替换（测试绝不真删）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../domain/app_version.dart';
import '../domain/disk_space.dart';
import '../domain/extensions.dart';
import '../domain/extensions_port.dart';
import '../domain/recycle_bin.dart';
import '../domain/reveal_in_explorer.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 常量（单测钉状态形状时用同一份字符串，别在测试里抄字面量）
// ─────────────────────────────────────────────────────────────────────────────

/// 已安装清单文件名（在 `root` 下）。
const String kExtensionsStateFileName = 'state.json';

/// `state.json` 的格式版本（本版本只认 1）。
const int kExtensionsStateSchema = 1;

/// 解压中的临时目录（以 `.` 开头 ⇒ `scan()` 天然跳过）。
const String kExtensionsStagingDirName = '.staging';

/// 旧版本 / 待回收目录。
const String kExtensionsTrashDirName = '.trash';

/// 下载中的 `.part` 文件所在目录。
const String kExtensionsDownloadsDirName = '.downloads';

/// 扩展清单必须出现在 zip **根目录**，且大小写敏感。
const String kExtensionManifestFileName = 'manifest.json';

/// `manifest.json` 自身的大小上限（防止用一个超大 JSON 拖死解析）。
///
/// 清单里的**数据文件**另由 core 的 `kPackageMaxEntryBytes`（32 MB）与
/// `kPackageMaxTotalBytes`（96 MB）管；这里是"清单本身"的护栏。
const int kMaxManifestBytes = 1024 * 1024;

/// 整个 zip 的字节数上限。
///
/// 解压后另有 core 的 96 MB 总上限；压缩包不可能比其内容大太多（store 模式的
/// 头部开销只有几十字节/条目），所以 128 MB 足够宽松，同时挡住"下载几十 GB"。
const int kMaxPackageBytes = 128 * 1024 * 1024;

/// 拉目录 / 下载的超时（与 `update_adapter.dart` 同一口径）。
const Duration _kCatalogTimeout = Duration(seconds: 20);
const Duration _kDownloadTimeout = Duration(seconds: 30);

/// 磁盘空间余量：解压前要的"总大小 + 这点余量"（日志/临时文件/文件系统块开销）。
const int _kDiskHeadroomBytes = 4 * 1024 * 1024;

/// 共享一个磁盘探测实例：`DiskSpaceProbe` 会按盘缓存 30 秒，装配根每装一个扩展
/// 都 new 一个只会重复起 PowerShell。
///
/// 取不到（null）时**跳过**这项检查 —— 宁可少一道软护栏，也不要因为查不到磁盘就把
/// 安装挡住（真正的失败会在写文件时以 [ExtensionFailure] 出现）。
final DiskSpaceProbe _sharedDiskProbe = DiskSpaceProbe();

/// 真实实现：`<数据根>/extensions` 下的下载 / 校验 / 原子替换。
class ExtensionsAdapter implements ExtensionsPort {
  ExtensionsAdapter({
    required Directory root,
    required http.Client Function() clientFactory,
    Future<void> Function(List<String>)? trash,
    RevealInExplorer? openDir,
    DateTime Function()? now,
    Future<int?> Function(String path)? freeBytes,
  })  : _root = root, // ignore: prefer_initializing_formals
        _clientFactory = clientFactory, // ignore: prefer_initializing_formals
        _trash = trash ?? _defaultTrash,
        _openDir = openDir ?? revealInExplorer,
        _now = now ?? DateTime.now,
        _freeBytes = freeBytes ?? _defaultFreeBytes;

  /// 扩展根目录（`<数据根>/extensions`）。
  final Directory _root;

  /// 每次请求新建一个客户端（与 `GitHubUpdatePort` 同一规矩：装配根会接上代理）。
  final http.Client Function() _clientFactory;

  /// 「把路径移进回收站」（可注入；默认真的走 Windows 回收站）。
  final Future<void> Function(List<String> paths) _trash;

  /// 「在资源管理器里打开目录」（可注入；默认 `revealInExplorer`）。
  final RevealInExplorer _openDir;

  /// 时钟（可注入；目录名后缀与 `installedAt` 都用它，测试因此可确定）。
  final DateTime Function() _now;

  /// 磁盘剩余空间探测（可注入；测试里给固定值，生产走 [DiskSpaceProbe]）。
  final Future<int?> Function(String path) _freeBytes;

  /// 同一毫秒内多次操作时给临时目录名去重（`now` 可能被测试钉死）。
  int _sequence = 0;

  static Future<void> _defaultTrash(List<String> paths) async {
    await moveToRecycleBin(paths);
  }

  static Future<int?> _defaultFreeBytes(String path) => _sharedDiskProbe.freeBytes(path);

  // ── 路径 ────────────────────────────────────────────────────────────────────

  @override
  String get extensionsDir => _root.path;

  File get _stateFile => File(p.join(_root.path, kExtensionsStateFileName));

  Directory get _stagingDir => Directory(p.join(_root.path, kExtensionsStagingDirName));

  Directory get _trashDir => Directory(p.join(_root.path, kExtensionsTrashDirName));

  Directory get _downloadsDir =>
      Directory(p.join(_root.path, kExtensionsDownloadsDirName));

  String _uniqueStem() => '${_now().millisecondsSinceEpoch}-${_sequence++}';

  // ── scan ────────────────────────────────────────────────────────────────────

  /// 扫描已安装扩展：**以磁盘为准**，`state.json` 只提供 `enabled` / 来源等元信息。
  ///
  /// 对账规则（契约 5）：
  /// * 目录在 + 记录在 → 用记录里的 `enabled`/来源，`bytes` 按磁盘重算；
  /// * 目录在 + 记录不在（用户手拷进来 / state.json 丢了）→ 补一条 `enabled=true`；
  /// * 记录在 + 目录没了（用户手删）→ 条目作废，并回写 `state.json`。
  ///
  /// 清单解析**不传 `currentAppVersion`**：装好之后应用版本可能被降级，已安装的扩展
  /// 仍应列出来（"装上 ≠ 能用"由 [InstalledExtension.usable] 与界面说明负责），
  /// 兼容性检查只在**安装**时做（见 [install]）。
  ///
  /// 坏 `state.json`（不是 JSON / 结构不对）→ 备份成 `state.json.corrupt-<ts>` 当空处理，
  /// 下次扫描从目录重建 —— 绝不因为一份坏记录把用户装好的扩展"弄丢"。
  @override
  Future<List<InstalledExtension>> scan() async {
    final _LoadedState loaded = await _readState();
    bool dirty = loaded.needsWrite;
    final Map<String, _StateEntry> kept = <String, _StateEntry>{};
    final List<InstalledExtension> result = <InstalledExtension>[];

    if (await _root.exists()) {
      final List<Directory> dirs = (await _root.list(followLinks: false).toList())
          .whereType<Directory>()
          .toList()
        ..sort((Directory a, Directory b) => a.path.compareTo(b.path));
      for (final Directory dir in dirs) {
        final String name = p.basename(dir.path);
        // `.staging` / `.trash` / `.downloads` 与一切点开头的东西都不是扩展。
        if (name.isEmpty || name.startsWith('.')) continue;
        final core.ExtensionManifest? manifest = await _readManifestIn(dir);
        // 目录名与清单 id 必须一致：不一致时**不猜**（否则 remove/setEnabled 会找错目录）。
        if (manifest == null || manifest.id != name) {
          dirty = true;
          continue;
        }
        final int bytes = await _directoryBytes(dir);
        final _StateEntry? old = loaded.entries[name];
        final InstalledExtension installed;
        if (old == null) {
          dirty = true;
          installed = InstalledExtension(
            manifest: manifest,
            enabled: true,
            installedAt: _now(),
            origin: ExtensionOrigin.localZip,
            bytes: bytes,
          );
        } else {
          // 盘上的清单被换过（手动改/别的进程装的）→ 以磁盘为准，并回写记录。
          if (old.manifest.version != manifest.version) dirty = true;
          installed = old.toInstalled(manifest, bytes);
        }
        kept[name] = _StateEntry.of(installed);
        result.add(installed);
      }
    }

    for (final String id in loaded.entries.keys) {
      if (!kept.containsKey(id)) dirty = true; // 目录被删掉了
    }

    if (dirty) {
      try {
        await _writeState(kept);
      } catch (error) {
        // 写不进去也不该让"扫描"失败：界面照样能看到磁盘上有什么。
        debugPrint('DSAnima extensions: 回写 state.json 失败（${_stateFile.path}）：$error');
      }
    }
    return List<InstalledExtension>.unmodifiable(result);
  }

  // ── install ─────────────────────────────────────────────────────────────────

  @override
  Future<InstalledExtension> install(
    ExtensionInstallRequest request, {
    void Function(ExtensionProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    bool cancelled() => isCancelled?.call() ?? false;

    Directory? staging;
    try {
      await _root.create(recursive: true);
      await _stagingDir.create(recursive: true);
      await _downloadsDir.create(recursive: true);
      await _trashDir.create(recursive: true);

      // ① 拿到 zip 字节（在线下载或读本地文件；两条路都校验整体 sha256/size）。
      final List<int> bytes = request.url != null
          ? await _download(request, onProgress, cancelled)
          : await _readLocal(request, cancelled);
      if (cancelled()) throw const ExtensionInstallCancelled();

      // ② 解 zip（只解析，不写盘）+ 取根 manifest.json。
      final _DecodedPackage package = _decode(bytes);
      final core.ManifestParseResult parsed = core.parseExtensionManifest(
        package.manifestJson,
        currentAppVersion: kAppVersion.toString(),
      );
      if (!parsed.ok) {
        final List<core.ManifestIssue> issues = parsed.issues;
        throw ExtensionFailure(
          '扩展清单不合法：${issues.first.message}',
          hint: issues.length > 1
              ? '还有 ${issues.length - 1} 个问题：'
                  '${issues.skip(1).take(3).map((core.ManifestIssue i) => i.message).join('；')}'
              : '这个 zip 不是 DSAnima 1.1.0 能装的扩展：让作者按清单格式重新打包，或换一个包',
        );
      }
      final core.ExtensionManifest manifest = parsed.manifest!;

      // ③ 条目级守卫：zip-slip / 解压炸弹 / 夹带（多一个文件都不解）。
      final core.PackageCheck check = core.checkExtensionPackage(
        package.entries,
        expectedFiles: core.expectedPackageFiles(manifest),
      );
      if (!check.ok) {
        throw ExtensionFailure(
          '扩展包不安全或与清单不符：${check.issues.first.message}',
          hint: '这个包可能被改过、或打包工具不标准。换成作者发布的原包重试；'
              '仍不行就联系扩展作者（不要手工改 zip 里的文件）',
        );
      }

      // ④ 磁盘余量：解压前就知道要占多大，别解到一半才发现没空间。
      final int? free = await _freeBytes(_root.path);
      final int needed = check.totalUncompressedBytes + package.manifestBytes.length;
      if (free != null && free < needed + _kDiskHeadroomBytes) {
        throw ExtensionFailure(
          '磁盘空间不足：这个扩展要解压出约 ${_formatBytes(needed)}，'
          '但「${_root.path}」所在盘只剩 ${_formatBytes(free)}',
          hint: '清出一些空间再装（扩展目录在数据根下，跟着程序目录走）',
        );
      }

      // ⑤ 解压进 `.staging/`，逐文件比对 size + sha256。
      staging = Directory(p.join(_stagingDir.path, '${manifest.id}.${_uniqueStem()}'));
      await staging.create(recursive: true);
      final int dirBytes =
          await _extract(package, manifest, staging, cancelled);

      // ⑥ 旧版本先挪进 `.trash/`（新版本还没就位前，旧目录的名字是空的）。
      final Directory finalDir = Directory(p.join(_root.path, manifest.id));
      Directory? oldInTrash;
      if (await finalDir.exists()) {
        final Directory trashSlot =
            Directory(p.join(_trashDir.path, '${manifest.id}.${_uniqueStem()}'));
        try {
          oldInTrash = await finalDir.rename(trashSlot.path);
        } catch (error) {
          throw ExtensionFailure(
            '无法替换旧版本：目录「${finalDir.path}」被占用（可能正在被播放器/其它程序使用）',
            hint: '关掉正在使用这个扩展的程序后重试。旧版本没有被动过，文件仍然完整（$error）',
          );
        }
      }

      // ⑦ staging → 正式目录（同一个卷上的 rename = 原子替换）。
      try {
        await staging.rename(finalDir.path);
      } catch (error) {
        // 回滚：把旧版本从 .trash 挪回去，保证"失败后磁盘状态和装之前一样"。
        if (oldInTrash != null) {
          try {
            await oldInTrash.rename(finalDir.path);
          } catch (rollbackError) {
            debugPrint(
              'DSAnima extensions: 安装失败后回滚旧版本也失败（旧目录留在 ${oldInTrash.path}）：'
              '$rollbackError',
            );
          }
        }
        throw ExtensionFailure(
          '安装失败：无法把解压好的扩展放到「${finalDir.path}」（$error）',
          hint: '这通常是文件被占用/权限被拒。关掉相关程序后重试；'
              '若旧版本还在（见 hint 里的目录），数据没有丢',
        );
      }

      // ⑧ 写 state.json（升级时**保留原来的 enabled**：用户禁用过的包升级后不该自己变启用）。
      final _LoadedState loaded = await _readState();
      final bool enabled = loaded.entries[manifest.id]?.enabled ?? true;
      loaded.entries[manifest.id] = _StateEntry(
        id: manifest.id,
        enabled: enabled,
        installedAt: _now(),
        origin: request.origin,
        sourceUrl: request.sourceUrl,
        bytes: dirBytes,
        manifest: manifest,
      );
      try {
        await _writeState(loaded.entries);
      } catch (error) {
        // 目录已经就位、但记录没写进去：下一次 scan() 会以磁盘为准补一条
        //（只是会丢掉"原来的 enabled"）。这**不是**安装失败，不该显示成红字。
        debugPrint('DSAnima extensions: 安装成功但写 state.json 失败：$error');
      }

      // ⑨ 旧版本交给回收站；失败就把目录留在 .trash/ 里（下次安装/手动清理再说）。
      if (oldInTrash != null) {
        try {
          await _trash(<String>[oldInTrash.path]);
        } catch (error) {
          debugPrint(
            'DSAnima extensions: 旧版本进回收站失败，目录保留在 ${oldInTrash.path}：$error',
          );
        }
      }

      final _StateEntry stored = loaded.entries[manifest.id]!;
      return stored.toInstalled(manifest, dirBytes);
    } on ExtensionInstallCancelled {
      await _deleteDirQuietly(staging);
      rethrow;
    } on ExtensionFailure {
      await _deleteDirQuietly(staging);
      rethrow;
    } catch (error) {
      await _deleteDirQuietly(staging);
      throw ExtensionFailure(
        '安装扩展失败：$error',
        hint: '重新下载一次；反复失败就换一个包（这不会破坏已有的扩展）',
      );
    }
  }

  // ── setEnabled / remove / catalog / openDirectory ──────────────────────────

  @override
  Future<void> setEnabled(String id, bool enabled) async {
    _requireSafeId(id);
    final _LoadedState loaded = await _readState();
    _StateEntry? entry = loaded.entries[id];
    if (entry == null) {
      // state.json 里没有但磁盘上有（手拷进来的包）：先按磁盘补一条，再改。
      final Directory dir = Directory(p.join(_root.path, id));
      final core.ExtensionManifest? manifest = await _readManifestIn(dir);
      if (manifest == null || manifest.id != id) {
        throw ExtensionFailure(
          '找不到扩展「$id」：它可能刚被卸载，或者目录里的 manifest.json 坏了',
          hint: '回到扩展页刷新一下列表再试；目录在「${_root.path}」',
        );
      }
      entry = _StateEntry(
        id: id,
        enabled: enabled,
        installedAt: _now(),
        origin: ExtensionOrigin.localZip,
        sourceUrl: null,
        bytes: await _directoryBytes(dir),
        manifest: manifest,
      );
    } else {
      entry = entry.withEnabled(enabled);
    }
    loaded.entries[id] = entry;
    try {
      await _writeState(loaded.entries);
    } catch (error) {
      throw ExtensionFailure(
        '启用状态没保存成功（$error）',
        hint: '检查数据目录是否可写、有没有被杀软占用，然后重试',
      );
    }
  }

  @override
  Future<void> remove(String id) async {
    _requireSafeId(id);
    final Directory dir = Directory(p.join(_root.path, id));
    final _LoadedState loaded = await _readState();
    final bool hasDir = await dir.exists();
    final bool hasEntry = loaded.entries.containsKey(id);
    if (!hasDir && !hasEntry) return; // 重复点卸载 / 已经不在：静默成功，不报错

    if (hasDir) {
      try {
        await _trash(<String>[dir.path]);
      } catch (error) {
        throw ExtensionFailure(
          '无法把「$id」放进回收站（$error）',
          hint: '文件可能正被占用、或所在盘不支持回收站。关掉正在使用它的程序后重试；'
              '文件仍在「${dir.path}」，没有丢',
        );
      }
    }
    if (hasEntry) {
      loaded.entries.remove(id);
      try {
        await _writeState(loaded.entries);
      } catch (error) {
        throw ExtensionFailure(
          '扩展目录已经进了回收站，但 state.json 没更新（$error）',
          hint: '重新打开扩展页可自动修复这条记录；文件已进回收站，可在回收站里恢复',
        );
      }
    }
  }

  @override
  Future<List<core.CatalogEntry>> fetchCatalog(Uri url) async {
    // 用户（2026-10-18：「识别 github 上面的」）贴的通常是浏览器里的 GitHub 网页地址，
    // 而 catalog.json 的真实地址在 raw.githubusercontent.com 上 —— 换算规则在
    // `core/lib/extensions/urls.dart`（纯逻辑、有测试）。这里按候选顺序试，
    // 第一个能解析成目录的算数：默认分支叫 main 还是 master、catalog 放根还是
    // 放 extensions/ 下，这几种作者习惯都覆盖掉。
    final List<Uri> candidates = core.extensionCatalogUrlCandidates(url);
    final http.Client client = _clientFactory();
    ExtensionFailure? lastFailure;
    try {
      for (int i = 0; i < candidates.length; i++) {
        final Uri candidate = candidates[i];
        final String? unsafe = core.unsafeExtensionUrlReason(candidate);
        if (unsafe != null) {
          lastFailure = ExtensionFailure(
            '目录地址不可用：$unsafe',
            hint: '填 https:// 开头的目录 json 地址（本机回环可用 http）',
          );
          continue;
        }
        final _CatalogAttempt attempt = await _fetchCatalogOnce(client, candidate);
        if (attempt.entries != null) return attempt.entries!;
        lastFailure = attempt.failure;
        // 网络层错误（超时/连不上）换候选也没用：同一个 host，只会再慢一轮。
        if (attempt.fatal) break;
      }
    } finally {
      client.close();
    }
    ExtensionFailure failure = lastFailure ??
        const ExtensionFailure(
          '拉取扩展目录失败',
          hint: '检查地址：它应当返回 catalog.json（不是网页）',
        );
    // 试过一串候选时要把这一点说清楚，否则用户只会看到"404"却不知道我们去过哪儿。
    if (candidates.length > 1) {
      failure = ExtensionFailure(
        '${failure.message}（试过 ${candidates.length} 个候选地址：'
        '${candidates.map((Uri u) => u.path).join(' / ')}）',
        hint: failure.hint,
      );
    }
    // 官方插件库失败要单独说一句：用户点的是"官方"按钮，看到的却是 404，
    // 只会以为是程序的网坏了。实际最常见的原因就是**仓库刚建好、还没推内容**。
    if (_isOfficialCatalogUrl(url)) {
      throw ExtensionFailure(
        '${failure.message}｜官方插件库仓库（dnciyun/DSAnima-plungin）里还没有内容',
        hint: '把 catalog.json 和 packs/ 推上去之后这里一键就能拉；'
            '现在也可以先粘别的目录地址，或用「从地址安装」直接填 zip 直链',
      );
    }
    throw failure;
  }

  /// 这个地址是不是**出厂默认的官方插件库**（用户 2026-10-18 给的仓库）。
  ///
  /// 只用来把失败提示说得更具体，**不参与**拉取逻辑：官方库与任何第三方目录走完全
  /// 同一条路（候选展开 / 安全判据 / 解析），不能因为"是官方的"就放宽任何校验。
  bool _isOfficialCatalogUrl(Uri url) {
    final String want = kOfficialExtensionsCatalogUrl;
    if (want.isEmpty) return false;
    String normalize(Uri value) =>
        value.removeFragment().toString().replaceAll(RegExp(r'/+$'), '').toLowerCase();
    return normalize(url) == normalize(Uri.parse(want));
  }

  /// 试一个候选地址拉目录：成功返回条目；失败返回原因（[fatal] = 换地址也没用）。
  Future<_CatalogAttempt> _fetchCatalogOnce(http.Client client, Uri url) async {
    final http.Response response;
    try {
      response = await client.get(url).timeout(_kCatalogTimeout);
    } on TimeoutException {
      return const _CatalogAttempt.failure(
        ExtensionFailure(
          '拉取扩展目录超时（20 秒）',
          hint: '检查网络；国内访问 GitHub/raw 常常需要代理（设置 → 网络 那一份会一起用上）',
        ),
        fatal: true,
      );
    } on http.ClientException catch (error) {
      return _CatalogAttempt.failure(
        ExtensionFailure('拉取扩展目录失败（${error.message}）', hint: '检查网络与代理设置后重试'),
        fatal: true,
      );
    } on SocketException catch (error) {
      return _CatalogAttempt.failure(
        ExtensionFailure(
          '连不上目录地址（${error.osError?.message ?? error.message}）',
          hint: '检查网络与代理设置（设置 → 网络）；也可以改用「从地址安装」直接填 zip 直链',
        ),
        fatal: true,
      );
    }

    if (response.statusCode != 200) {
      return _CatalogAttempt.failure(
        ExtensionFailure(
          '拉取扩展目录失败（HTTP ${response.statusCode}）',
          hint: response.statusCode == 404
              ? '这个地址上没有目录 json：确认仓库里放了 catalog.json、'
                  '默认分支叫 main 或 master；也可以直接贴仓库网页地址让应用自己找'
              : '检查网络/代理设置后重试',
        ),
      );
    }
    // GitHub 对不存在的路径有时回 200 + HTML（网页/登录页），直接 jsonDecode 会报
    // "不是合法 JSON"，用户看不懂。content-type 是网页时给一句人话。
    final String contentType = (response.headers['content-type'] ?? '').toLowerCase();
    if (contentType.contains('text/html')) {
      return const _CatalogAttempt.failure(
        ExtensionFailure(
          '这个地址返回的是一张网页，不是 catalog.json',
          hint: '贴仓库地址（https://github.com/作者/仓库）或 catalog.json 的 raw 地址；'
              '私有仓库的网页拿不到内容',
        ),
      );
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException catch (error) {
      return _CatalogAttempt.failure(
        ExtensionFailure(
          '扩展目录不是合法 JSON（${error.message}）',
          hint: '确认这个地址返回的是 catalog.json 本身，而不是网页/HTML',
        ),
      );
    }
    final core.CatalogParseResult parsed = core.parseExtensionCatalog(
      json,
      baseUrl: url,
      currentAppVersion: kAppVersion.toString(),
    );
    if (parsed.entries.isEmpty) {
      if (parsed.issues.isEmpty) {
        return const _CatalogAttempt.failure(
          ExtensionFailure(
            '扩展目录里没有任何条目',
            hint: '目录 json 的 extensions 是空数组：让作者先发布扩展再拉目录',
          ),
        );
      }
      return _CatalogAttempt.failure(
        ExtensionFailure(
          '扩展目录里没有能用的条目：${parsed.issues.first.message}',
          hint: '这份目录的条目都过不了校验（地址/清单格式问题）；'
              '可以改用「从地址安装」直接填 zip 直链',
        ),
      );
    }
    return _CatalogAttempt.success(List<core.CatalogEntry>.unmodifiable(parsed.entries));
  }

  /// 依次试下载候选地址，返回第一个可用的流式响应。
  ///
  /// 为什么要看 content-type：GitHub 的 `blob` 网页对 GET 返回 **200 + HTML**，
  /// 只看状态码会"下载成功"然后死在解压上，错误信息对用户毫无意义。
  Future<http.StreamedResponse> _openDownload(
    http.Client client,
    List<Uri> candidates,
  ) async {
    ExtensionFailure? lastFailure;
    for (final Uri candidate in candidates) {
      final http.StreamedResponse response;
      try {
        response = await client
            .send(http.Request('GET', candidate))
            .timeout(_kDownloadTimeout);
      } on TimeoutException {
        throw const ExtensionFailure(
          '下载扩展包超时（30 秒）',
          hint: '检查网络/代理后重试；也可以让作者把包发给你，用「本地 zip」安装',
        );
      }
      if (response.statusCode != 200) {
        lastFailure = ExtensionFailure(
          '下载扩展包失败（HTTP ${response.statusCode}）',
          hint: response.statusCode == 404
              ? '这个地址上没有扩展包：确认链接是作者发布的 zip 直链'
                  '（GitHub 的 blob 网页地址也行，应用会自己换算成 raw）'
              : '检查网络/代理设置后重试；也可以改用本地 zip 安装',
        );
        continue;
      }
      final String contentType = (response.headers['content-type'] ?? '').toLowerCase();
      if (contentType.contains('text/html')) {
        lastFailure = const ExtensionFailure(
          '这个地址返回的是网页，不是 zip',
          hint: '贴 GitHub 里文件页（blob）的地址，或作者发布的 releases 直链；'
              '私有仓库的网页拿不到文件',
        );
        continue;
      }
      return response;
    }
    throw lastFailure ??
        const ExtensionFailure(
          '下载扩展包失败',
          hint: '检查地址后重试；也可以改用本地 zip 安装',
        );
  }

  @override
  Future<void> openDirectory() async {
    try {
      await _root.create(recursive: true);
    } catch (error) {
      throw ExtensionFailure(
        '建不出扩展目录「${_root.path}」（$error）',
        hint: '数据目录可能不可写（被杀软/权限限制）；到资源管理器手动看一下那个路径',
      );
    }
    try {
      await _openDir(_root.path);
    } catch (error) {
      throw ExtensionFailure(
        '打不开扩展目录（$error）',
        hint: '到资源管理器手动打开「${_root.path}」',
      );
    }
  }

  // ── 内部：输入 ──────────────────────────────────────────────────────────────

  /// 在线下载：`http.Client.send` + 流式写 `.part`（与 `update_adapter` 同一写法）。
  ///
  /// 每个 chunk 之前都问一次 `isCancelled()`（契约 3）；`onProgress` **每次都调**，
  /// 节流由状态机负责（`state/extensions.dart` 80ms）。
  Future<List<int>> _download(
    ExtensionInstallRequest request,
    void Function(ExtensionProgress progress)? onProgress,
    bool Function() cancelled,
  ) async {
    // 作者通常把 zip 放在 GitHub 仓库里，复制出来的是 `blob` 网页地址 —— 那个地址
    // 下到的是 HTML（GitHub 的页头），会被当成坏 zip。换算规则见
    // `core/lib/extensions/urls.dart`；releases 的直链原样通过。
    final List<Uri> candidates = core.extensionDownloadUrlCandidates(request.url!);
    for (final Uri candidate in candidates) {
      final String? unsafe = core.unsafeExtensionUrlReason(candidate);
      if (unsafe != null) {
        throw ExtensionFailure(
          '下载地址不可用：$unsafe',
          hint: '只接受 https:// 地址（本机回环可用 http）；换个地址或改用本地 zip 安装',
        );
      }
    }

    final String stem = _safeStem(request.manifest?.id);
    final File part = File(p.join(_downloadsDir.path, '$stem.${_uniqueStem()}.part'));
    final http.Client client = _clientFactory();
    IOSink? sink;
    try {
      // 候选地址依次试，第一个 200 且不是网页的算数（GitHub 的 blob 页会回 200 + HTML）。
      final http.StreamedResponse response = await _openDownload(client, candidates);

      final int? declared = response.contentLength ?? request.size;
      if (declared != null && declared > kMaxPackageBytes) {
        throw ExtensionFailure(
          '扩展包太大（${_formatBytes(declared)}，上限 ${_formatBytes(kMaxPackageBytes)}）',
          hint: '确认下载的是扩展包而不是别的大文件',
        );
      }

      final IOSink out = part.openWrite();
      sink = out;
      int received = 0;
      await for (final List<int> chunk in response.stream) {
        // 取消检查放在写入**之前**：用户一点取消，这个块就不落盘。
        if (cancelled()) throw const ExtensionInstallCancelled();
        out.add(chunk);
        received += chunk.length;
        if (received > kMaxPackageBytes) {
          throw ExtensionFailure(
            '扩展包超过上限（已收到 ${_formatBytes(received)}，上限 ${_formatBytes(kMaxPackageBytes)}）',
            hint: '这个下载可能不是扩展包，换一个地址或改用本地 zip',
          );
        }
        onProgress?.call(ExtensionProgress(received: received, total: declared));
      }
      await out.close();
      sink = null;

      // 最后一个 chunk 的 onProgress 里用户可能刚点了取消 —— 收尾再问一次。
      if (cancelled()) throw const ExtensionInstallCancelled();
      if (declared != null && received != declared) {
        throw ExtensionFailure(
          '下载不完整（收到 $received 字节，预期 $declared 字节）',
          hint: '网络中断了。重新点一次安装即可（临时文件已删除，不会留下坏包）',
        );
      }

      final List<int> bytes = await part.readAsBytes();
      _verifyPackageBytes(bytes, request);
      return bytes;
    } on ExtensionFailure {
      rethrow;
    } on http.ClientException catch (error) {
      throw ExtensionFailure(
        '下载扩展包中断（${error.message}）',
        hint: '重新点一次安装；反复失败就改用本地 zip',
      );
    } on SocketException catch (error) {
      throw ExtensionFailure(
        '下载扩展包中断（${error.osError?.message ?? error.message}）',
        hint: '检查网络与代理设置后重试',
      );
    } finally {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {
          // 收尾失败无所谓：下面会把半截文件删掉。
        }
      }
      client.close();
      // 无论成功失败都不留半截：成功时字节已在内存里，`.part` 没有用途。
      await _deleteQuietly(part);
    }
  }

  /// 本地 zip：读文件 + 同一套整体校验（本地来源也不能跳过 checkExtensionPackage）。
  Future<List<int>> _readLocal(
    ExtensionInstallRequest request,
    bool Function() cancelled,
  ) async {
    final String path = request.localPath!.trim();
    final File file = File(path);
    if (!await file.exists()) {
      throw ExtensionFailure(
        '找不到这个文件：$path',
        hint: '重新选一次 zip（文件可能被移动/删除了）',
      );
    }
    if (cancelled()) throw const ExtensionInstallCancelled();
    final int length = await file.length();
    if (length > kMaxPackageBytes) {
      throw ExtensionFailure(
        '这个 zip 太大（${_formatBytes(length)}，上限 ${_formatBytes(kMaxPackageBytes)}）',
        hint: '确认选的是扩展包，不是别的压缩包',
      );
    }
    final List<int> bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (error) {
      throw ExtensionFailure(
        '读不了这个文件（$error）',
        hint: '文件可能正被别的程序占用；关掉它再试，或把 zip 复制到桌面后重选',
      );
    }
    _verifyPackageBytes(bytes, request);
    return bytes;
  }

  /// 校验 zip 整体：字节数（目录里声明过才查）与 sha256（给了才查）。
  void _verifyPackageBytes(List<int> bytes, ExtensionInstallRequest request) {
    final int? expectedSize = request.size;
    if (expectedSize != null && bytes.length != expectedSize) {
      throw ExtensionFailure(
        '扩展包大小不符（收到 ${bytes.length} 字节，目录里写的是 $expectedSize 字节）',
        hint: '文件在传输中被截断或换过。重新下载一次；仍不行就联系扩展作者',
      );
    }
    final String? expectedSha = request.sha256;
    if (expectedSha != null) {
      final String actual = sha256.convert(bytes).toString();
      if (actual != expectedSha.toLowerCase()) {
        throw ExtensionFailure(
          '扩展包校验失败（sha256 不符）',
          hint: '下载到的字节和发布方给的不一致：可能被中间人改过、或拿到的是旧文件。'
              '重新下载一次；仍然不符就不要再装，联系扩展作者',
        );
      }
    }
  }

  // ── 内部：zip ───────────────────────────────────────────────────────────────

  /// 解码 zip 并取出根目录的 `manifest.json`；**不写任何文件**。
  _DecodedPackage _decode(List<int> bytes) {
    final ZipDecoder decoder = ZipDecoder();
    final Archive archive;
    try {
      // `verify: true` 在 archive 4.3.0 里是空实现（源码里 CRC 校验被注释掉了），
      // 真正的完整性由我们对每个文件算 sha256 来保证（比 CRC 强得多）。
      archive = decoder.decodeBytes(bytes, verify: true);
    } catch (error) {
      throw ExtensionFailure(
        '扩展包不是有效的 zip（$error）',
        hint: '确认下载下来的是 .zip（不是网页/HTML），并且下载完整（文件大小对得上）',
      );
    }

    final List<core.PackageEntry> entries = <core.PackageEntry>[
      for (final ZipFileHeader header in decoder.directory.fileHeaders)
        core.PackageEntry(
          name: header.filename,
          uncompressedSize: header.uncompressedSize,
          compressedSize: header.compressedSize,
          isDirectory: header.filename.endsWith('/') || header.filename.endsWith(r'\'),
        ),
    ];
    if (entries.isEmpty) {
      throw const ExtensionFailure(
        '扩展包是空 zip（或根本不是 zip）',
        hint: '换成作者发布的 .zip 重试；确认文件没有在下途中被截断',
      );
    }

    final ArchiveFile? manifestEntry = archive.find(kExtensionManifestFileName);
    if (manifestEntry == null) {
      throw const ExtensionFailure(
        '扩展包里没有 manifest.json（它必须在 zip 根目录，不能套一层文件夹）',
        hint: '换成作者发布的原包；如果你自己打包，把 manifest.json 放在压缩包最外层'
            '（和 shaders/ 这些目录同级，不要多套一层文件夹）',
      );
    }
    final List<int> manifestBytes = manifestEntry.readBytes() ?? <int>[];
    if (manifestBytes.isEmpty) {
      throw const ExtensionFailure(
        '扩展包里的 manifest.json 是空的',
        hint: '让作者重新打包（清单不可能为空）',
      );
    }
    if (manifestBytes.length > kMaxManifestBytes) {
      throw ExtensionFailure(
        '扩展包里的 manifest.json 太大（${_formatBytes(manifestBytes.length)}，'
        '上限 ${_formatBytes(kMaxManifestBytes)}）',
        hint: '这不是正常的扩展清单，换一个包',
      );
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(manifestBytes));
    } on FormatException catch (error) {
      throw ExtensionFailure(
        '扩展包里的 manifest.json 不是合法 JSON（${error.message}）',
        hint: '清单被改坏了。换作者发布的原包重试',
      );
    }
    return _DecodedPackage(
      entries: entries,
      archive: archive,
      manifestBytes: manifestBytes,
      manifestJson: json,
    );
  }

  /// 解压到 [staging]，逐文件比对 `size`+`sha256`；返回写入的字节数（= 目录占用）。
  Future<int> _extract(
    _DecodedPackage package,
    core.ExtensionManifest manifest,
    Directory staging,
    bool Function() cancelled,
  ) async {
    int written = 0;
    try {
      // manifest.json 原样写进去：`scan()` 靠它认目录、显示名字/版本。
      await File(p.join(staging.path, kExtensionManifestFileName))
          .writeAsBytes(package.manifestBytes, flush: true);
      written += package.manifestBytes.length;

      final Map<String, ArchiveFile> byPath = <String, ArchiveFile>{
        for (final ArchiveFile file in package.archive.files) file.name.toLowerCase(): file,
      };
      for (final core.ExtensionFile file in manifest.files) {
        if (cancelled()) throw const ExtensionInstallCancelled();
        // 双重保险：条目的路径已在 core 的守卫里过了一遍，这里再确认"真的落在 staging 里"。
        final String? unsafe = core.unsafeRelativePathReason(file.path);
        if (unsafe != null) {
          throw ExtensionFailure(
            '扩展包里的路径不可用：${file.path}（$unsafe）',
            hint: '换作者发布的原包重试',
          );
        }
        final File target = File(
          p.joinAll(<String>[staging.path, ...file.path.split('/')]),
        );
        if (!p.isWithin(staging.path, target.path)) {
          throw ExtensionFailure(
            '扩展包里的路径越界（${file.path}）',
            hint: '这个包会写到扩展目录外面，已拒绝安装',
          );
        }
        final ArchiveFile? entry = byPath[file.path.toLowerCase()];
        if (entry == null) {
          throw ExtensionFailure(
            '扩展包里缺少清单声明的文件「${file.path}」',
            hint: '包和清单对不上（可能被打包工具漏了文件）。换作者发布的原包重试',
          );
        }
        final List<int> data = entry.readBytes() ?? <int>[];
        if (data.length != file.size) {
          throw ExtensionFailure(
            '文件「${file.path}」大小不符（解压出 ${data.length} 字节，清单写 ${file.size} 字节）',
            hint: '包被截断或清单过期（作者改了文件但没更新清单）。重新下载；仍不行就联系作者',
          );
        }
        final String actual = sha256.convert(data).toString();
        if (actual != file.sha256) {
          throw ExtensionFailure(
            '文件「${file.path}」校验失败（sha256 不符）',
            hint: '包内容和清单不一致：可能被打包工具改过、或下载被篡改。'
                '重新下载一次；仍不行就不要安装，联系扩展作者',
          );
        }
        await target.parent.create(recursive: true);
        await target.writeAsBytes(data, flush: true);
        written += data.length;
      }
      // 收尾再问一次：用户在最后一个文件解压期间点了取消。
      if (cancelled()) throw const ExtensionInstallCancelled();
      return written;
    } catch (error) {
      await _deleteDirQuietly(staging);
      rethrow;
    }
  }

  // ── 内部：state.json ───────────────────────────────────────────────────────

  /// 读 `state.json`；坏文件备份成 `state.json.corrupt-<ts>` 后当空处理。
  Future<_LoadedState> _readState() async {
    final File file = _stateFile;
    if (!await file.exists()) {
      return _LoadedState(entries: <String, _StateEntry>{}, needsWrite: false);
    }
    String text;
    try {
      text = await file.readAsString();
    } catch (error) {
      debugPrint('DSAnima extensions: 读不了 state.json（${file.path}）：$error');
      return _LoadedState(entries: <String, _StateEntry>{}, needsWrite: false);
    }
    Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      await _backupCorruptState(file);
      return _LoadedState(entries: <String, _StateEntry>{}, needsWrite: true);
    }
    if (json is! Map) {
      await _backupCorruptState(file);
      return _LoadedState(entries: <String, _StateEntry>{}, needsWrite: true);
    }
    final Object? rawExtensions = json['extensions'];
    if (rawExtensions is! Map) {
      await _backupCorruptState(file);
      return _LoadedState(entries: <String, _StateEntry>{}, needsWrite: true);
    }

    bool changed = false;
    final Map<String, _StateEntry> entries = <String, _StateEntry>{};
    for (final MapEntry<Object?, Object?> item in rawExtensions.entries) {
      final String id = '${item.key}';
      final Object? value = item.value;
      if (value is! Map) {
        changed = true;
        continue;
      }
      if (core.unsafeRelativePathReason(id) != null) {
        changed = true;
        continue;
      }
      final Map<String, Object?> map = <String, Object?>{
        for (final MapEntry<Object?, Object?> e in value.entries) '${e.key}': e.value,
      };
      // 记录里的清单只用来显示与对账；兼容性检查留给安装时。
      final core.ManifestParseResult parsed = core.parseExtensionManifest(
        map['manifest'],
        currentAppVersion: null,
      );
      if (!parsed.ok || parsed.manifest == null) {
        changed = true;
        continue;
      }
      final core.ExtensionManifest manifest = parsed.manifest!;
      if (manifest.id != id) {
        changed = true;
        continue;
      }
      final Object? rawEnabled = map['enabled'];
      final Object? rawOrigin = map['origin'];
      final Object? rawSourceUrl = map['sourceUrl'];
      final Object? rawBytes = map['bytes'];
      final Object? rawInstalledAt = map['installedAt'];
      entries[id] = _StateEntry(
        id: id,
        enabled: rawEnabled is bool ? rawEnabled : true,
        installedAt: rawInstalledAt is String
            ? (DateTime.tryParse(rawInstalledAt) ?? _now())
            : _now(),
        origin: ExtensionOrigin.values.firstWhere(
          (ExtensionOrigin origin) => origin.name == rawOrigin,
          orElse: () => ExtensionOrigin.localZip,
        ),
        sourceUrl: rawSourceUrl is String && rawSourceUrl.isNotEmpty ? rawSourceUrl : null,
        bytes: rawBytes is num && rawBytes >= 0 ? rawBytes.toInt() : 0,
        manifest: manifest,
      );
    }
    return _LoadedState(entries: entries, needsWrite: changed);
  }

  /// 原子写 `state.json`：先写 `<state.json>.tmp`，`flush` 后 rename 覆盖。
  ///
  /// 与 `core` 的 `FileKeyValueStore`（`kv.dart`）同一做法：宁可整份换掉，也不要在
  /// 写一半时被杀掉留下半截 JSON（下次启动会当成"坏记录"备份掉，等于所有扩展都消失）。
  Future<void> _writeState(Map<String, _StateEntry> entries) async {
    await _root.create(recursive: true);
    final Map<String, Object?> json = <String, Object?>{
      'schema': kExtensionsStateSchema,
      'extensions': <String, Object?>{
        for (final MapEntry<String, _StateEntry> e in entries.entries) e.key: e.value.toJson(),
      },
    };
    final File tmp = File('${_stateFile.path}.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(_stateFile.path);
  }

  Future<void> _backupCorruptState(File file) async {
    final File target =
        File('${file.path}.corrupt-${_uniqueStem()}');
    try {
      await file.rename(target.path);
      debugPrint('DSAnima extensions: state.json 坏了，已备份到 ${target.path}（按空处理）');
    } catch (error) {
      debugPrint('DSAnima extensions: 备份坏 state.json 失败（${file.path}）：$error');
    }
  }

  // ── 内部：杂项 ──────────────────────────────────────────────────────────────

  /// `id` 同时是目录名 ⇒ 任何路径成分都不许有（防 `../` 把卸载指向外面）。
  void _requireSafeId(String id) {
    final String? unsafe = core.unsafeRelativePathReason(id);
    if (unsafe != null || id.contains('/')) {
      throw ExtensionFailure(
        '扩展 id 不可用：$id${unsafe == null ? '' : '（$unsafe）'}',
        hint: '这是数据损坏或调用方传错了参数；刷新扩展列表后重试',
      );
    }
  }

  /// 下载 `.part` 用的文件名前缀（只取安全的 id；没有就 `package`）。
  String _safeStem(String? id) {
    final String raw = (id ?? '').trim();
    if (raw.isEmpty) return 'package';
    if (core.unsafeRelativePathReason(raw) != null || raw.contains('/')) {
      return 'package';
    }
    return raw;
  }

  /// 读 `<dir>/manifest.json` 并解析（坏文件返回 null，不抛）。
  Future<core.ExtensionManifest?> _readManifestIn(Directory dir) async {
    try {
      final File file = File(p.join(dir.path, kExtensionManifestFileName));
      if (!await file.exists()) return null;
      if (await file.length() > kMaxManifestBytes) return null;
      final Object? json = jsonDecode(utf8.decode(await file.readAsBytes()));
      final core.ManifestParseResult parsed = core.parseExtensionManifest(
        json,
        currentAppVersion: null,
      );
      return parsed.ok ? parsed.manifest : null;
    } catch (_) {
      return null;
    }
  }

  /// 目录占用字节数（界面「大小」列；读不出来的部分跳过，不抛）。
  Future<int> _directoryBytes(Directory dir) async {
    int total = 0;
    try {
      await for (final FileSystemEntity entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        try {
          total += await entity.length();
        } catch (_) {
          // 单个文件读不到就算了（文件被占用/刚被删）。
        }
      }
    } catch (_) {
      // 目录读不了 → 0（界面显示「—」）。
    }
    return total;
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删不掉（被占用/权限）也不该盖住真正的错误。
    }
  }

  Future<void> _deleteDirQuietly(Directory? dir) async {
    if (dir == null) return;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (error) {
      debugPrint('DSAnima extensions: 清理临时目录失败（${dir.path}）：$error');
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 内部数据类
// ─────────────────────────────────────────────────────────────────────────────

/// 解码后的 zip（清单原始字节 + 条目表 + archive 本体）。
class _DecodedPackage {
  const _DecodedPackage({
    required this.entries,
    required this.archive,
    required this.manifestBytes,
    required this.manifestJson,
  });

  /// 条目表（名字 + 压缩/解压大小），交给 core 的守卫。
  final List<core.PackageEntry> entries;

  final Archive archive;

  /// `manifest.json` 的原始字节（原样写进扩展目录）。
  final List<int> manifestBytes;

  /// 解析后的 JSON（可能是任何形状；校验由 core 的 parseExtensionManifest 做）。
  final Object? manifestJson;
}

/// `state.json` 里的一条记录（+ 内存里的解析结果）。
class _StateEntry {
  const _StateEntry({
    required this.id,
    required this.enabled,
    required this.installedAt,
    required this.origin,
    required this.sourceUrl,
    required this.bytes,
    required this.manifest,
  });

  factory _StateEntry.of(InstalledExtension installed) => _StateEntry(
        id: installed.id,
        enabled: installed.enabled,
        installedAt: installed.installedAt,
        origin: installed.origin,
        sourceUrl: installed.sourceUrl,
        bytes: installed.bytes,
        manifest: installed.manifest,
      );

  final String id;
  final bool enabled;
  final DateTime installedAt;
  final ExtensionOrigin origin;
  final String? sourceUrl;
  final int bytes;
  final core.ExtensionManifest manifest;

  _StateEntry withEnabled(bool next) => _StateEntry(
        id: id,
        enabled: next,
        installedAt: installedAt,
        origin: origin,
        sourceUrl: sourceUrl,
        bytes: bytes,
        manifest: manifest,
      );

  InstalledExtension toInstalled(core.ExtensionManifest latest, int latestBytes) =>
      InstalledExtension(
        manifest: latest,
        enabled: enabled,
        installedAt: installedAt,
        origin: origin,
        sourceUrl: sourceUrl,
        bytes: latestBytes,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'enabled': enabled,
        'installedAt': installedAt.toIso8601String(),
        'origin': origin.name,
        if (sourceUrl != null) 'sourceUrl': sourceUrl,
        'bytes': bytes,
        'manifest': manifest.toJson(),
      };
}

/// `_readState` 的结果。
class _LoadedState {
  const _LoadedState({required this.entries, required this.needsWrite});

  final Map<String, _StateEntry> entries;

  /// 读进来的东西是否和文件里的不同（坏文件 / 丢了坏条目）→ scan 需要回写。
  final bool needsWrite;
}

/// 一次候选地址的拉取结果（成功 = 有 entries；失败 = 原因 + 是否"换地址也没用"）。
class _CatalogAttempt {
  const _CatalogAttempt._(this.entries, this.failure, this.fatal);

  const _CatalogAttempt.success(List<core.CatalogEntry> entries)
      : this._(entries, null, false);

  const _CatalogAttempt.failure(ExtensionFailure failure, {bool fatal = false})
      : this._(null, failure, fatal);

  final List<core.CatalogEntry>? entries;
  final ExtensionFailure? failure;
  final bool fatal;
}
