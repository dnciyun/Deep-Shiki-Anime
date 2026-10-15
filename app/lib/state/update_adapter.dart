/// **检查更新的适配层**：GitHub Releases → 下载 → 覆盖安装目录 → 重启（第三十九轮）。
///
/// ⚠️ 只有 `main.dart`（装配根）可以 import 本文件 —— 与 `engine_bootstrap.dart` 同规矩：
/// UI / state 只依赖 `domain/ports.dart` 的 `UpdatePort`，这样上游在改的时候
/// 宿主的 `flutter analyze` 与 widget 测试仍然能独立跑绿。
///
/// ## 覆盖安装为什么是一个"脱离父进程的脚本"
/// Windows 上正在运行的 `dsanima.exe` / `data\app.so` **被进程锁住**，自己覆盖自己一定失败。
/// 所以流程是：解压新版本 → 写一个脚本 → 脱离启动它 → 宿主正常退出 → 脚本等进程消失后
/// `robocopy` 覆盖 → 重新拉起 exe。
///
/// 四条实现上的硬约束（都踩过或想清楚了才这么写）：
/// 1. **脚本必须是 UTF-8 带 BOM，并且只由 PowerShell 执行**：安装目录可能带中文
///    （`C:\Users\某某\Desktop\DSAnima`），而 `cmd.exe` 按 OEM 代码页读批处理，
///    UTF-8 的中文会被读成乱码 → `robocopy` 找不到目录。PowerShell 5.1 认 UTF-8 BOM。
/// 2. **路径不写进命令行参数**，只写进脚本文件里：脚本文件有 BOM 兜着，参数没有。
/// 3. **写日志、而不是默默失败**：覆盖是另一个进程干的活，宿主下次启动只能靠
///    `update\pending.json` 对账（见 `state/update.dart`）；日志里留着 robocopy 的退出码，
///    出问题时有一条能看的线索。
/// 4. **等不到就强关，而不是"等超时然后硬复制"**（2026-10-16 加固）：宿主正常退出一般
///    <3 秒，脚本给 45 秒；还在（边车卡住、用户又开了一个实例、宿主收尾没走完）就
///    `Stop-Process -Force` —— **只关路径在本安装目录下的** `dsanima` / `rqbit-engine`，
///    另一个文件夹里的 DSAnima 跟这次覆盖无关，不该被误杀。`robocopy` 退出码 ≥8
///    （= 有文件没换成，多半还被锁着）会再强关一次、再试一次。原来的写法是"等满 10 分钟
///    然后照样复制"：复制必然失败，却还是把**旧** exe 拉起来了 —— 用户看到的是"更新过了"。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsanima_core/update/update.dart' as core_update;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../domain/ports.dart';

/// 真实实现：GitHub API + CDN 下载 + 脚本覆盖安装。
class GitHubUpdatePort implements UpdatePort {
  GitHubUpdatePort({
    required this.workDir,
    required this.installDir,
    http.Client Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? http.Client.new;

  /// 更新工作目录（`<数据根>/update`）：下载的包、解压目录、脚本、日志、待办记录都在这。
  final Directory workDir;

  /// 安装目录（`dsanima.exe` 所在目录）—— 脚本覆盖的目标。
  final Directory installDir;

  /// HTTP 客户端工厂：**每次请求新建一个**，且由装配根接上"源抓取那套代理"
  /// （`core.IoHttpClientFactory(proxy:)`）—— GitHub 在很多网络里直连不通。
  final http.Client Function() _clientFactory;

  static const String _userAgent = 'DSAnima-Updater';
  static const String _scriptName = 'apply-update.ps1';
  static const String _logName = 'apply.log';
  static const String _pendingName = 'pending.json';

  /// 下载进度最多多久报一次（字节）。不节流的话一个 39MB 的包会触发上千次
  /// provider 更新 —— 进度条不会更准，界面反而会抖。
  static const int _progressStepBytes = 256 * 1024;

  String get _powershell => p.join(
    Platform.environment['SystemRoot'] ?? r'C:\Windows',
    'System32',
    'WindowsPowerShell',
    'v1.0',
    'powershell.exe',
  );

  File get _pendingFile => File(p.join(workDir.path, _pendingName));

  @override
  Future<core_update.ReleaseInfo> latestRelease(String repoSlug, {String token = ''}) async {
    final Uri uri = Uri.parse(core_update.releaseApiUrl(repoSlug));
    final http.Client client = _clientFactory();
    try {
      final http.Response response = await client
          .get(uri, headers: _headers(token))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw _httpFailure(
          response.statusCode,
          apiMessage: _apiMessage(response.bodyBytes),
          rateLimitReset: _rateLimitReset(response.headers),
          authenticated: token.trim().isNotEmpty,
        );
      }
      final Object? decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final core_update.ReleaseInfo? info = core_update.ReleaseInfo.tryParse(decoded);
      if (info == null) {
        throw const PortUnavailableException(
          '这个仓库还没有发布过 Release（或者被删掉了）',
          hint: '只把代码推上去不算发布：要在 GitHub 的 Releases 页新建一个 release、'
              '标签写 `v1.0.1` 这种版本号，并把 `DSAnima-*-win-x64.zip` 传成附件。',
        );
      }
      return info;
    } on PortUnavailableException {
      rethrow;
    } on TimeoutException {
      throw const PortUnavailableException(
        '请求 GitHub 超时（20 秒）',
        hint: '检查网络；GitHub 在国内常常需要代理 —— 在「设置 → 网络」配好 HTTP/SOCKS5 '
            '代理后会一起用上，也可以到项目发布页手动下载。',
      );
    } on SocketException catch (error) {
      throw PortUnavailableException(
        '连不上 GitHub（${error.osError?.message ?? error.message}）',
        hint: '检查网络与代理设置（「设置 → 网络」）；也可以到项目发布页手动下载 zip。',
      );
    } on FormatException catch (error) {
      throw PortUnavailableException(
        'GitHub 返回的内容看不懂（${error.message}）',
        hint: '可能是网络中间有东西改了响应（公司网关/加速器）；换个网络或配代理再试。',
      );
    } finally {
      client.close();
    }
  }

  @override
  Future<File> downloadAsset(
    core_update.ReleaseAsset asset, {
    String token = '',
    void Function(int received, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    await workDir.create(recursive: true);
    final File target = File(p.join(workDir.path, _safeFileName(asset.name)));
    final File partial = File('${target.path}.part');
    if (await partial.exists()) await partial.delete();

    final http.Client client = _clientFactory();
    IOSink? sink;
    bool done = false;
    try {
      // 有 API 资产地址就走它 + `Accept: application/octet-stream`：GitHub 文档里"下载
      // 资产二进制"的正式入口，**公开仓库匿名也能走**，而私有/受限仓库只能走它 ——
      // 发布页那条 `browser_download_url` 对未登录访客是 404。没有 `apiUrl`
      //（手写 JSON / 老响应）就退回浏览器地址，行为与以前完全一致。
      final String url = asset.apiUrl ?? asset.downloadUrl;
      final http.StreamedResponse response = await client
          .send(
            http.Request('GET', Uri.parse(url))
              ..headers.addAll(_headers(token, binary: true)),
          )
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw PortUnavailableException(
          '下载更新包失败（HTTP ${response.statusCode}）',
          hint: token.trim().isEmpty
              ? '到项目发布页手动下载 zip 也是一种办法（更新源那一格旁边有发布页地址）。'
              : '带了令牌还是下不来：确认这个令牌**有权访问这个仓库**、而且没有过期；'
                  '也可以到项目发布页手动下载 zip。',
        );
      }
      final int? total = response.contentLength ?? (asset.sizeBytes > 0 ? asset.sizeBytes : null);
      // 局部非空变量：`sink` 留着是为了 `finally` 里兜底关掉（取消/异常路径）。
      final IOSink out = partial.openWrite();
      sink = out;
      int received = 0;
      int reported = 0;
      await for (final List<int> chunk in response.stream) {
        if (isCancelled?.call() ?? false) {
          await out.close();
          sink = null;
          await _deleteQuietly(partial);
          throw const PortUnavailableException(
            '已取消下载',
            hint: '半截文件已经删掉，随时可以重新下。',
          );
        }
        out.add(chunk);
        received += chunk.length;
        if (received - reported >= _progressStepBytes || (total != null && received >= total)) {
          reported = received;
          onProgress?.call(received, total);
        }
      }
      await out.close();
      sink = null;
      if (total != null && total > 0 && received != total) {
        throw PortUnavailableException(
          '下载不完整（$received / $total 字节）',
          hint: '网络中断了。重新点一次「下载更新包」即可（不会用坏文件覆盖你的程序）。',
        );
      }
      onProgress?.call(received, total);
      if (await target.exists()) await target.delete();
      final File landed = await partial.rename(target.path);
      done = true;
      return landed;
    } on PortUnavailableException {
      rethrow;
    } on TimeoutException {
      throw const PortUnavailableException(
        '下载更新包超时',
        hint: 'GitHub 的下载走 CDN，国内常常要代理；也可以在发布页手动下载 zip。',
      );
    } on http.ClientException catch (error) {
      throw PortUnavailableException('下载中断（${error.message}）', hint: '重新点一次「下载更新包」。');
    } on SocketException catch (error) {
      throw PortUnavailableException(
        '下载中断（${error.osError?.message ?? error.message}）',
        hint: '重新点一次「下载更新包」；反复失败就手动下载 zip。',
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
      // 失败路径一律不留半截文件：下次解压一个坏 zip 会报一个跟原因无关的错。
      if (!done) await _deleteQuietly(partial);
    }
  }

  @override
  Future<void> prepareUpdate(File package) async {
    await workDir.create(recursive: true);
    final Directory extract = Directory(p.join(workDir.path, 'extract'));
    if (await extract.exists()) await extract.delete(recursive: true);
    await extract.create(recursive: true);
    await _unzip(package, extract);
    final Directory payload = await _locatePayload(extract);

    final File log = File(p.join(workDir.path, _logName));
    await log.writeAsString(
      'DSAnima updater: package=${package.path}\n'
      'payload=${payload.path}\n'
      'install=${installDir.path}\n',
      flush: true,
    );
    final File script = File(p.join(workDir.path, _scriptName));
    await script.writeAsBytes(
      _scriptBytes(
        source: payload.path,
        install: installDir.path,
        log: log.path,
        work: extract.path,
      ),
      flush: true,
    );
    // 脱离父进程启动：宿主马上要退出，脚本得活下去（它还要等我们消失）。
    //
    // ⚠️ 启动方式**必须是 `ProcessStartMode.normal` 且不 await 它跑完**
    //（2026-10-15 实测，原始数据见 `tool/update_spawn_probe.dart`）：
    // * `detached` / `detachedWithStdio` / `cmd /c start` 在 Windows 上给子进程一组
    //   **不可用的标准句柄** —— 进程起来了但什么都不执行（连 `cmd /c echo > file` 都不写文件），
    //   更新会静默地什么也不做；
    // * `normal` 模式子进程有可用句柄，而且实测**父进程 `exit(0)` 之后它照样跑完**
    //   （两阶段实验：父进程 spawn 完立刻退出，子进程 3 秒后写的文件确实出现了）。
    final Process process;
    try {
      process = await Process.start(
        _powershell,
        <String>[
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          script.path,
        ],
        mode: ProcessStartMode.normal,
        runInShell: false,
      );
    } catch (error) {
      throw PortUnavailableException(
        '启动覆盖脚本失败（$error）',
        hint: '也可以到项目发布页手动下载 zip，解压后覆盖安装目录'
            '（脚本自己的记录在 ${log.path}）。',
      );
    }
    // 只 await 到"进程已创建"，**不等它结束**（它要等到我们退出才开始覆盖）。
    // 两个管道挂上读端：子进程万一往 stdout/stderr 写东西，管道满了会把它卡住。
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());  }

  @override
  Future<core_update.PendingUpdate?> pendingUpdate() async {
    final File file = _pendingFile;
    if (!await file.exists()) return null;
    try {
      return core_update.PendingUpdate.tryParse(jsonDecode(await file.readAsString()));
    } catch (_) {
      // 坏掉的记录当没有：它只影响"上次更新成没成"这一句提示。
      return null;
    }
  }

  @override
  Future<void> declarePending(core_update.PendingUpdate? pending) async {
    final File file = _pendingFile;
    if (pending == null) {
      if (await file.exists()) await file.delete();
      return;
    }
    await workDir.create(recursive: true);
    await file.writeAsString(jsonEncode(pending.toJson()), flush: true);
  }

  // ── 内部 ───────────────────────────────────────────────────────────────────

  /// 请求头（第四十轮：可选令牌）。
  ///
  /// **令牌只进 `Authorization` 头**：不写进 URL（URL 会进日志/崩溃报告）、不写进日志，
  /// 也不写进报错文案（那些会显示在界面上）。空令牌 = 完全匿名，与以前一模一样。
  ///
  /// [binary] 用于下载：GitHub 的 `/releases/assets/<id>` 接口**必须**带
  /// `Accept: application/octet-stream` 才返回二进制，否则返回的是元数据 JSON。
  Map<String, String> _headers(String token, {bool binary = false}) {
    final String trimmed = token.trim();
    return <String, String>{
      'Accept': binary ? 'application/octet-stream' : 'application/vnd.github+json',
      'User-Agent': _userAgent,
      if (trimmed.isNotEmpty) 'Authorization': 'Bearer $trimmed',
    };
  }

  PortUnavailableException _httpFailure(
    int status, {
    String? apiMessage,
    DateTime? rateLimitReset,
    bool authenticated = false,
  }) {
    final core_update.UpdateFailure text = core_update.describeReleaseHttpError(
      status,
      apiMessage: apiMessage,
      rateLimitReset: rateLimitReset,
      authenticated: authenticated,
    );
    return PortUnavailableException(text.message, hint: text.hint);
  }

  String? _apiMessage(List<int> body) {
    try {
      final Object? decoded = jsonDecode(utf8.decode(body));
      if (decoded is Map) return decoded['message'] as String?;
    } catch (_) {
      // 响应不是 JSON（网关页面之类）→ 没有 message 可用。
    }
    return null;
  }

  DateTime? _rateLimitReset(Map<String, String> headers) {
    final int? epoch = int.tryParse(headers['x-ratelimit-reset'] ?? '');
    if (epoch == null || epoch <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
  }

  /// 只取文件名最后一段，别让 asset 名字里的 `..\` 跑到目录外面去。
  String _safeFileName(String raw) {
    final String name = raw.split(RegExp(r'[\\/]')).last.trim();
    return name.isEmpty ? 'update.zip' : name;
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删不掉就算了（文件锁/权限）——不要让收尾失败盖住真正的错误。
    }
  }

  /// 解压：powerShell `Expand-Archive` 为主（Windows 自带、Unicode 路径安全），
  /// Windows 10 1803+ 自带的 `tar.exe`（bsdtar）为退路。
  Future<void> _unzip(File package, Directory into) async {
    final String command = 'Expand-Archive -LiteralPath ${_psQuote(package.path)} '
        '-DestinationPath ${_psQuote(into.path)} -Force';
    final ProcessResult result = await Process.run(_powershell, <String>[
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      command,
    ]);
    if (result.exitCode == 0) return;
    final ProcessResult tar = await Process.run('tar.exe', <String>[
      '-xf',
      package.path,
      '-C',
      into.path,
    ]);
    if (tar.exitCode == 0) return;
    throw PortUnavailableException(
      '更新包解压失败（PowerShell 退出码 ${result.exitCode}，tar 退出码 ${tar.exitCode}）',
      hint: '${_tail('${result.stderr}')}｜也可以到项目发布页手动下载 zip，解压后覆盖安装目录。',
    );
  }

  /// 新版本内容在哪一层：发布包是 `Compress-Archive` 压出来的一堆顶层文件
  /// （`dsanima.exe` 在根上），但手工打的包常常多套一层文件夹，这里两种都认。
  Future<Directory> _locatePayload(Directory extract) async {
    if (await File(p.join(extract.path, 'dsanima.exe')).exists()) return extract;
    final List<Directory> subdirs = await extract
        .list()
        .where((FileSystemEntity entity) => entity is Directory)
        .cast<Directory>()
        .toList();
    for (final Directory dir in subdirs) {
      if (await File(p.join(dir.path, 'dsanima.exe')).exists()) return dir;
    }
    throw PortUnavailableException(
      '更新包里没有 dsanima.exe（顶层 ${subdirs.length} 个子目录也都没找到）',
      hint: '发布的 zip 应该是整个发布目录的内容（用 tool/release_github.ps1 打包就不会有这个问题）。',
    );
  }

  String _tail(String text, {int lines = 6}) {
    final List<String> all = const LineSplitter().convert(text.trim());
    if (all.isEmpty) return '（没有更多输出）';
    return all.length <= lines ? all.join(' / ') : all.sublist(all.length - lines).join(' / ');
  }

  /// PowerShell 单引号字符串（里面的 `'` 要翻倍；`$`、反引号在单引号里都是字面量）。
  String _psQuote(String value) => "'${value.replaceAll("'", "''")}'";

  /// 覆盖脚本本体。**UTF-8 带 BOM**（见文件头第 1 条）：注释与路径里都可以有中文，
  /// 因为 BOM 把编码钉死了；但路径**只能写在这个文件里**，不能走命令行参数。
  List<int> _scriptBytes({
    required String source,
    required String install,
    required String log,
    required String work,
  }) {
    // UTF-8 BOM：PowerShell 5.1 靠它才能把脚本里的中文路径读对。
    return <int>[
      0xEF,
      0xBB,
      0xBF,
      ...utf8.encode(
        buildUpdateScript(source: source, install: install, log: log, work: work),
      ),
    ];
  }
}

/// 覆盖脚本本体 —— 纯文本；UTF-8 BOM 由 [GitHubUpdatePort] 那边加（见文件头第 1 条）。
///
/// 为什么抽成顶层函数：真机探针（`test/update_apply_probe.dart`）量的是"它真的跑得通"，
/// 而 `test/update_script_test.dart` 量的是"它必须包含什么"（先优雅等、等不到就强关、
/// 只关本安装目录下的进程、不带 `/PURGE`、记 `robocopy` 退出码、路径里的单引号翻倍…）。
/// 这段逻辑要是被人顺手删掉，只跑 `flutter test` 的人不会发现 —— 所以它需要一条**快的**守卫。
String buildUpdateScript({
  required String source,
  required String install,
  required String log,
  required String work,
}) {
  String q(String value) => "'${value.replaceAll("'", "''")}'";
  return '''
# DSAnima 覆盖更新脚本（第三十九轮）：由宿主写好并脱离启动。
# 等宿主进程消失（等不到就只强关本安装目录下的）→ robocopy 覆盖 → 用新版本重启
# → 清掉解压出来的临时文件 → 删掉自己。
\$ErrorActionPreference = 'Continue'
\$src = ${q(source)}
\$dst = ${q(install)}
\$exe = Join-Path \$dst 'dsanima.exe'
\$log = ${q(log)}
\$work = ${q(work)}

function Write-Log([string]\$text) {
  try {
    Add-Content -LiteralPath \$log -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), \$text) -Encoding UTF8
  } catch { }
}

Write-Log 'updater started; waiting for DSAnima to exit'
\$grace = 45
\$prefix = \$dst.TrimEnd('\\') + '\\'

# 只认"从本安装目录跑起来的"进程：另一个文件夹里的 DSAnima 与这次覆盖无关，
# 等它只会白等到超时（而超时之后照样复制 = 旧 exe 还被锁着 → 复制必然失败）。
function Get-DsProcess {
  \$found = @()
  foreach (\$name in @('dsanima', 'rqbit-engine')) {
    foreach (\$proc in @(Get-Process -Name \$name -ErrorAction SilentlyContinue)) {
      \$path = ''
      try { \$path = [string]\$proc.Path } catch { }
      # 路径读不到（权限/UAC）时也当成目标：宁可多关一次，也不让覆盖注定失败。
      if (-not \$path -or \$path -like (\$prefix + '*')) { \$found += ,\$proc }
    }
  }
  ,\$found
}

function Stop-DsProcess([string]\$why) {
  \$n = 0
  foreach (\$proc in Get-DsProcess) {
    try {
      Stop-Process -Id \$proc.Id -Force -ErrorAction Stop
      \$n = \$n + 1
      Write-Log ("force-closed {0} (pid {1}): {2}" -f \$proc.ProcessName, \$proc.Id, \$why)
    } catch {
      Write-Log ("cannot close {0} (pid {1}): {2}" -f \$proc.ProcessName, \$proc.Id, \$_.Exception.Message)
    }
  }
  \$n
}

# 先优雅等（宿主正常退出一般 <3 秒）；等不到就**强关**，而不是"等满时间再硬复制"。
\$deadline = (Get-Date).AddSeconds(\$grace)
while ((Get-DsProcess).Count -gt 0 -and (Get-Date) -lt \$deadline) { Start-Sleep -Milliseconds 500 }
if ((Get-DsProcess).Count -gt 0) {
  Write-Log ("still running after {0}s: closing them" -f \$grace)
  \$null = Stop-DsProcess 'graceful wait timed out'
  Start-Sleep -Seconds 2
}
Write-Log 'processes gone; robocopy start'
\$rc = 1
\$round = 0
while (\$true) {
  \$round = \$round + 1
  \$rc = 1
  try {
    \$null = & "\$env:SystemRoot\\System32\\robocopy.exe" \$src \$dst /E /R:3 /W:1 /NFL /NDL /NJH /NJS /NP
    \$rc = \$LASTEXITCODE
  } catch {
    Write-Log ("robocopy exception: {0}" -f \$_.Exception.Message)
  }
  Write-Log ("robocopy exit={0} (round {1})" -f \$rc, \$round)
  # 0-7 都算成功（1 = 有文件被复制）；>=8 = 有文件没换成（多半还被锁着）
  # → 再关一次、再试一次。只试两次：一个真被占用到关不掉的目录，多试也没用。
  if (\$rc -lt 8 -or \$round -ge 2) { break }
  Write-Log 'robocopy reported failures; force-closing leftovers and retrying'
  \$null = Stop-DsProcess 'robocopy could not replace locked files'
  Start-Sleep -Seconds 2
}
try {
  Start-Process -FilePath \$exe -WorkingDirectory \$dst
  Write-Log 'restart requested'
} catch {
  Write-Log ("restart failed: {0}" -f \$_.Exception.Message)
}
if (\$rc -ge 8) { Write-Log ("WARNING: robocopy exit={0}: some files were NOT replaced" -f \$rc) }
try { Remove-Item -LiteralPath \$work -Recurse -Force -ErrorAction SilentlyContinue } catch { }
Start-Sleep -Seconds 2
try { Remove-Item -LiteralPath \$MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue } catch { }
''';
}
