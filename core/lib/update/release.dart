/// GitHub Release 的解析与"要不要更新"的判定（第三十九轮）。
///
/// 这一层**只做纯函数**：给一个 JSON 对象（GitHub 的 `/releases/latest` 响应体）
/// 和一个当前版本号，回答"该不该更新、用哪个文件"。网络与文件系统在
/// `app/lib/state/update_adapter.dart`（宿主侧的 `UpdatePort` 真实实现）里，
/// 所以规则本身可以在 `core/test` 里离线钉死。
///
/// ## 与发布流程的约定（重要）
/// * 发布标签写 `vX.Y.Z`；更新包的 **asset 文件名**要能被 [pickWindowsAsset] 认出来 ——
///   本项目用 `tool/release_github.ps1` 打包，文件名形如
///   `DSAnima-20261015-win-x64.zip`（含 `win-x64`、以 `.zip` 结尾）。
///   换成别的名字（比如 `.7z`、`.exe` 安装器）时**同时改** [pickWindowsAsset]，
///   否则用户会看到"有新版本但没有可用的更新包"——那句提示是诚实兜底，不是常态。
library;

import 'version.dart';

/// 更新包（GitHub release 的一个 asset）。
class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    this.apiUrl,
    this.sizeBytes = 0,
    this.contentType,
  });

  /// 文件名（例如 `DSAnima-20261015-win-x64.zip`）。
  final String name;

  /// `browser_download_url`：浏览器点一下就能下的那个地址（会 302 到 CDN）。
  /// **未登录访客读不到私有/受限仓库**，所以它只在没有 [apiUrl] 时当退路。
  final String downloadUrl;

  /// `url`：GitHub API 的资产地址（`.../releases/assets/<id>`）。
  ///
  /// 走它 + `Accept: application/octet-stream` 才是官方说的"下载资产二进制"，也是
  /// **私有仓库 / 账号被限制可见性时唯一能下的路**（第四十轮：带令牌走这条）。
  /// 手写 JSON 或老响应里可能没有 ⇒ 可空。
  final String? apiUrl;

  /// 字节数；0 = 服务端没给（进度就只能显示"已下载多少"）。
  final int sizeBytes;

  final String? contentType;

  static ReleaseAsset? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Object? name = raw['name'];
    final Object? url = raw['browser_download_url'];
    if (name is! String || url is! String || name.isEmpty || url.isEmpty) return null;
    final Object? api = raw['url'];
    return ReleaseAsset(
      name: name,
      downloadUrl: url,
      apiUrl: (api is String && api.isNotEmpty) ? api : null,
      sizeBytes: (raw['size'] as num?)?.toInt() ?? 0,
      contentType: raw['content_type'] as String?,
    );
  }
}

/// 一次 release（只要宿主用得到的那几个字段）。
class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.version,
    required this.title,
    required this.notes,
    required this.publishedAt,
    required this.htmlUrl,
    required this.assets,
    this.prerelease = false,
  });

  /// 原始标签（`v1.2.3`）。
  final String tag;

  /// 解析出来的版本号；标签不是版本号时为 null（[decideUpdate] 会说"看不懂"）。
  final AppVersion? version;

  /// release 标题（可能为空；空就回落到 [tag]）。
  final String title;

  /// 更新说明（markdown 原文，UI 自己截断显示）。
  final String notes;

  final DateTime? publishedAt;

  /// 发布页地址（`https://github.com/<owner>/<repo>/releases/tag/<tag>`）。
  final String htmlUrl;

  final List<ReleaseAsset> assets;

  final bool prerelease;

  /// 界面上的标题：优先 release 标题，其次标签。
  String get displayTitle => title.trim().isEmpty ? tag : title.trim();

  /// 解析 GitHub 的 release JSON；**草稿**（draft）直接当"不是一次发布"返回 null
  /// （`/releases/latest` 本来就不返回草稿，这里只是不让草稿有别的入口钻进来）。
  static ReleaseInfo? tryParse(Object? raw) {
    if (raw is! Map) return null;
    if (raw['draft'] == true) return null;
    final Object? tag = raw['tag_name'];
    if (tag is! String || tag.trim().isEmpty) return null;
    final List<ReleaseAsset> assets = <ReleaseAsset>[];
    final Object? rawAssets = raw['assets'];
    if (rawAssets is List) {
      for (final Object? item in rawAssets) {
        final ReleaseAsset? asset = ReleaseAsset.tryParse(item);
        if (asset != null) assets.add(asset);
      }
    }
    return ReleaseInfo(
      tag: tag.trim(),
      version: AppVersion.tryParse(tag),
      title: raw['name'] as String? ?? '',
      notes: raw['body'] as String? ?? '',
      publishedAt: DateTime.tryParse(raw['published_at'] as String? ?? ''),
      htmlUrl: raw['html_url'] as String? ?? '',
      assets: List<ReleaseAsset>.unmodifiable(assets),
      prerelease: raw['prerelease'] == true,
    );
  }
}

/// 从一堆 asset 里挑**本机能用的更新包**；挑不出来返回 null。
///
/// 打分而不是"取第一个"：发布页上通常还挂着 `.sha256`、`Source code (zip)`
/// 之类的东西，随便拿一个会把用户引到错的文件上。规则：
/// * 只认 `.zip`（本项目发布包就是这个形态，见文件头约定）；
/// * 名字里有 `win-x64` 的优先，其次 `win`，再次 `x64`；
/// * 名字以 `DSAnima` 开头再加一档（同仓多发别的产物时不会挑错）。
ReleaseAsset? pickWindowsAsset(Iterable<ReleaseAsset> assets) {
  ReleaseAsset? best;
  int bestScore = 0;
  for (final ReleaseAsset asset in assets) {
    final String name = asset.name.toLowerCase();
    if (!name.endsWith('.zip')) continue;
    int score = 1;
    if (name.contains('win-x64')) {
      score += 8;
    } else if (name.contains('win')) {
      score += 4;
    } else if (name.contains('x64')) {
      score += 2;
    }
    if (name.startsWith('dsanima')) score += 2;
    if (score > bestScore) {
      bestScore = score;
      best = asset;
    }
  }
  return best;
}

/// "要不要更新"的结论。
sealed class UpdateDecision {
  const UpdateDecision();
}

/// 已是最新（或远端更旧 —— 用户装了比发布版更新的构建，也算已是最新）。
final class UpdateUpToDate extends UpdateDecision {
  const UpdateUpToDate({required this.current, this.latest});

  final AppVersion current;

  /// 远端解析出来的版本；远端标签看不懂时为 null。
  final AppVersion? latest;
}

/// 有新版本，且找到了可用的 Windows 更新包。
final class UpdateAvailable extends UpdateDecision {
  const UpdateAvailable({required this.release, required this.asset});

  final ReleaseInfo release;
  final ReleaseAsset asset;
}

/// 有新版本，但**没有可用的更新包**（发布时忘了传 zip / 名字不符合约定）。
///
/// 单独一档而不是并进 [UpdateUpToDate]：明明有新版却说"已是最新"是撒谎。
final class UpdateNoAsset extends UpdateDecision {
  const UpdateNoAsset({required this.release});

  final ReleaseInfo release;
}

/// 远端标签不是版本号（`latest`、`nightly` 之类）。
final class UpdateUnparsableTag extends UpdateDecision {
  const UpdateUnparsableTag({required this.tag});

  final String tag;
}

/// 判定：当前 [current]，远端最新发布 [latest]。
UpdateDecision decideUpdate({required AppVersion current, required ReleaseInfo latest}) {
  final AppVersion? remote = latest.version;
  if (remote == null) return UpdateUnparsableTag(tag: latest.tag);
  if (remote.compareTo(current) <= 0) {
    return UpdateUpToDate(current: current, latest: remote);
  }
  final ReleaseAsset? asset = pickWindowsAsset(latest.assets);
  if (asset == null) return UpdateNoAsset(release: latest);
  return UpdateAvailable(release: latest, asset: asset);
}

// ─────────────────────────────────────────────────────────────────────────────
// 更新源（owner/repo）：用户从浏览器地址栏抄下来的东西，怎么都算对
// ─────────────────────────────────────────────────────────────────────────────

/// 把用户粘进来的"仓库地址"规范成 `owner/repo`；认不出来返回 null。
///
/// 用户 2026-10-15 第三十九轮的原话是「我仓库建了在哪找 api」—— 所以这里**故意宽松**：
/// 仓库页面地址、`.git` 结尾的克隆地址、`git@github.com:` 形态、发布页地址、
/// 甚至把 API 地址整条粘进来，都能认出来（地址栏里那两段就是答案）。
String? normalizeRepoSlug(String? raw) {
  if (raw == null) return null;
  String text = raw.trim();
  if (text.isEmpty) return null;

  // `git@github.com:owner/repo.git` → `owner/repo.git`
  final int at = text.indexOf('@');
  if (at >= 0 && !text.contains('://')) {
    final int colon = text.indexOf(':', at);
    if (colon > 0) text = text.substring(colon + 1);
  }
  text = text.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '');
  text = text.replaceFirst(RegExp(r'^www\.', caseSensitive: false), '');
  // 主机段：只认 github.com（或 api.github.com）。没有 '/' 就一定不是 `owner/repo`。
  final int slash = text.indexOf('/');
  if (slash < 0) return null;
  final String host = text.substring(0, slash).toLowerCase();
  if (host.contains('.')) {
    if (host != 'github.com' && host != 'api.github.com') return null;
    text = text.substring(slash + 1);
  }
  text = text.replaceFirst(RegExp(r'^repos/', caseSensitive: false), '');
  text = text.split('?').first.split('#').first;
  if (text.endsWith('.git')) text = text.substring(0, text.length - 4);
  text = text.replaceAll(RegExp(r'/+$'), '');
  if (text.isEmpty) return null;

  final List<String> segments = text
      .split('/')
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toList(growable: false);
  if (segments.length < 2) return null;
  final String owner = segments[0];
  final String repo = segments[1];
  final RegExp allowed = RegExp(r'^[A-Za-z0-9._-]+$');
  if (!allowed.hasMatch(owner) || !allowed.hasMatch(repo)) return null;
  if (owner.toLowerCase() == 'releases' || repo.toLowerCase() == 'releases') return null;
  return '$owner/$repo';
}

/// 检查更新真正请求的接口地址（**把这条显示在设置页**：用户问的就是"api 在哪"）。
String releaseApiUrl(String slug) => 'https://api.github.com/repos/$slug/releases/latest';

/// **内置的更新源**（第四十一轮）：这一格留空就用它 —— 用户不用去仓库页面抄那两段。
///
/// 2026-10-18（第七十五轮）换了仓库：`ciciyouxihao-source/DSAnima` → `dnciyun/Deep-Shiki-Anime`。
/// 原因：旧账号被 GitHub 限制可见性（匿名 / 未登录访客 404，程序里检查更新永远失败），
/// 新仓库是公开的、匿名能读；源码与发布包都放它下面。
///
/// ⚠️ 这个值必须和**实际发 Release 的仓库**一致（`tool/release_github.ps1` 会读这里校验）：
/// 发到别处而这里不改，用户那边的「检查更新」就会一直显示"已是最新"。
const String kBuiltinUpdateRepo = 'dnciyun/Deep-Shiki-Anime';

/// 真正拿去请求的那个 slug：填了就用填的，留空（或只有空白）就用 [kBuiltinUpdateRepo]。
///
/// 为什么把"留空"解释成"用内置"、而不是"没配"：**从哪更新是产品的一部分**，不该要求用户
/// 自己去找 `owner/repo`。所以设置里那一格是**覆盖**入口 —— 想换成自己的 fork 或别的仓库
/// 就填上，清空就回到内置。老设置里存的空串也因此自动享受到内置值（不用迁移）。
String effectiveUpdateRepo(String raw) {
  final String trimmed = raw.trim();
  return trimmed.isEmpty ? kBuiltinUpdateRepo : trimmed;
}

/// 发布页地址（手动下载的兜底入口）。
String releasePageUrl(String slug) => 'https://github.com/$slug/releases/latest';

// ─────────────────────────────────────────────────────────────────────────────
// 出错了怎么跟用户说（纯函数：状态码 + GitHub 的 message → 中文两句话）
// ─────────────────────────────────────────────────────────────────────────────

/// 给用户看的失败说明（消息 + 怎么办）。
class UpdateFailure {
  const UpdateFailure(this.message, {this.hint});

  final String message;
  final String? hint;

  @override
  String toString() => hint == null ? message : '$message（$hint）';
}

/// 把一次失败的检查翻成人话。
///
/// [rateLimitReset] 是 GitHub 响应头 `x-ratelimit-reset`（秒级 epoch）换算来的时间；
/// 匿名调用每小时只有 60 次，命中额度时**必须说清楚**，否则用户会以为"这软件坏了"。
///
/// [authenticated] = 这次请求带了访问令牌（第四十轮）。它改两句话，两处都是
/// "把用户指到正确的修法上"：
/// * `401` 单独说"令牌无效" —— 以前 401/404 合并成一句，会把"令牌填错了"说成
///   "仓库找不到"，用户就去改仓库名，怎么改都好不了；
/// * `404` 且带了令牌 ⇒ 还得考虑"令牌没权限看这个仓库"（私有仓库生成令牌时没勾）。
UpdateFailure describeReleaseHttpError(
  int status, {
  String? apiMessage,
  DateTime? rateLimitReset,
  bool authenticated = false,
}) {
  final String detail = (apiMessage ?? '').trim();
  switch (status) {
    case 401:
      return const UpdateFailure(
        '访问令牌无效或已过期',
        hint: '到 GitHub → `Settings → Developer settings → Fine-grained tokens` 重新生成一个：'
            '只勾这个仓库的 **Contents: Read-only**（够用，别给写权限），粘回「访问令牌」那一格。'
            '公开仓库其实可以不填令牌 —— 清空那一格就能退回匿名请求。',
      );
    case 404:
      if (authenticated) {
        return const UpdateFailure(
          '找不到这个仓库，或者这个令牌没权限看它',
          hint: '两件事各查一遍：① 「更新源」填的是仓库地址里的 `<用户名>/<仓库名>` 两段吗；'
              '② 生成令牌时那个仓库勾上了吗（`Repository access` 选 All repositories，'
              '或把本仓库加进 Selected；权限只要 **Contents: Read-only**）。',
        );
      }
      return const UpdateFailure(
        '找不到这个仓库，或它还没有发布过 Release',
        hint: '更新源要填仓库页面地址里的 `<用户名>/<仓库名>` 两段（例如 `abc/DSAnima`）。'
            '确认仓库是**公开**的，并且已经在 GitHub 上建过一次 Release（只推代码不算）。'
            '仓库是私有的、或者账号对未登录访客不可见（匿名怎么读都是 404），'
            '就在「访问令牌」那一格填一个只读令牌。',
      );
    case 403:
      if (detail.toLowerCase().contains('rate limit') || rateLimitReset != null) {
        final String when = rateLimitReset == null
            ? '大约一小时后'
            : '${rateLimitReset.toLocal().hour.toString().padLeft(2, '0')}:'
                '${rateLimitReset.toLocal().minute.toString().padLeft(2, '0')} 之后';
        return UpdateFailure(
          'GitHub 接口的匿名额度用完了（每小时 60 次）',
          hint: '等到 $when 再试，或直接到项目发布页手动下载 zip 覆盖安装。',
        );
      }
      return UpdateFailure('GitHub 拒绝了这次请求（403）', hint: detail.isEmpty ? '稍后再试。' : detail);
    default:
      if (status >= 500) {
        return UpdateFailure(
          'GitHub 服务器出错（HTTP $status）',
          hint: '这不是本机的问题，过几分钟再试一次。',
        );
      }
      return UpdateFailure(
        '检查更新失败（HTTP $status）',
        hint: detail.isEmpty ? '检查网络/代理设置后重试。' : detail,
      );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 更新过没有：下次启动时对一次账
// ─────────────────────────────────────────────────────────────────────────────

/// 重启更新前写下的"我要升到哪一版"（<数据目录>/update/pending.json）。
///
/// 为什么需要它：更新是**另一个进程**（批处理）在我们退出之后干的活 ——
/// 覆盖失败、被安全软件拦住、用户点错目录，宿主都看不见。下次启动拿自己现在的版本
/// 和这里记的目标比一下，就能诚实地说"上次更新没生效"，而不是让用户以为更新过了。
class PendingUpdate {
  const PendingUpdate({
    required this.tag,
    required this.target,
    required this.startedAt,
    this.packagePath,
  });

  final String tag;
  final AppVersion target;
  final DateTime startedAt;

  /// 下载下来的 zip 路径（排查用）。
  final String? packagePath;

  Map<String, Object?> toJson() => <String, Object?>{
    'tag': tag,
    'target': target.toString(),
    'startedAt': startedAt.toIso8601String(),
    if (packagePath != null) 'packagePath': packagePath,
  };

  static PendingUpdate? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final AppVersion? target = AppVersion.tryParse(raw['target'] as String?);
    if (target == null) return null;
    return PendingUpdate(
      tag: raw['tag'] as String? ?? target.tag,
      target: target,
      startedAt: DateTime.tryParse(raw['startedAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      packagePath: raw['packagePath'] as String?,
    );
  }
}

/// 上次更新到底成没成。
enum UpdateAftermath {
  /// 现在的版本已经不低于目标版本 → 覆盖成功了。
  applied,

  /// 还是老版本 → 覆盖没生效（要如实告诉用户，并把批处理日志指给他）。
  notApplied,
}

/// 对账（纯函数）。
UpdateAftermath compareAftermath({
  required AppVersion current,
  required PendingUpdate pending,
}) => current.compareTo(pending.target) >= 0 ? UpdateAftermath.applied : UpdateAftermath.notApplied;
