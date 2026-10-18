/// 扩展**地址**的规整：把用户粘贴的 GitHub 网页地址变成真正能下的地址。
///
/// 为什么需要这一层（用户 2026-10-18：「加入官方插件库，可以直接下载我加进去的插件，
/// **识别 github 上面的**」）：插件作者/用户手里最常见的地址是浏览器里那一条
/// (`https://github.com/<owner>/<repo>`)，而 `catalog.json` / `zip` 的真实下载地址在
/// `raw.githubusercontent.com` 上。让用户自己换算（repo → 默认分支 → 文件路径 →
/// raw 前缀）是不现实的，尤其是"默认分支叫 main 还是 master"这种事。
///
/// 设计取舍：
/// * **纯逻辑**（只吃 `Uri`、吐候选列表），不猜网络、不查 GitHub API —— 主窗口里那层
///   （`app/lib/state/extensions_adapter.dart`）按顺序试，第一个 200 且能解析的就是它；
/// * **返回候选而不是唯一答案**：仓库默认分支是 main 还是 master、catalog.json 在根
///   还是在 `extensions/` 下，这两件事在网页地址里都看不出来，只能列出来试；
/// * 顺序有意义：越"标准"的越靠前（raw 地址 → blob 地址 → 仓库根 + main/master）。
library;

/// GitHub 的网页域名（含 `www.`）。
bool _isGithubPageHost(String host) => host == 'github.com' || host == 'www.github.com';

/// raw 内容域名（`raw.githubusercontent.com`，也认 `gist.githubusercontent.com`）。
bool _isGithubRawHost(String host) =>
    host == 'raw.githubusercontent.com' || host == 'gist.githubusercontent.com';

/// 从 GitHub 网页路径里拆出 `owner/repo/剩余段`。
///
/// 只认第一层 `owner/repo`：GitHub 的路径第一段永远是用户名/组织，第二段是仓库名。
({String owner, String repo, List<String> rest})? _splitRepo(List<String> segments) {
  if (segments.length < 2) return null;
  final String owner = segments[0];
  final String repo = segments[1];
  if (owner.isEmpty || repo.isEmpty) return null;
  return (owner: owner, repo: repo, rest: segments.sublist(2));
}

/// 一个 GitHub 仓库根 → 可能的 `catalog.json` 地址（给定分支在前，main/master 兜底）。
///
/// `subPath` 是仓库里的目录（相对仓库根，可空）：插件库常见两种放法 ——
/// 仓库根目录直接放 `catalog.json`，或者放在 `extensions/` 子目录里，两种都给。
List<Uri> _repoCatalogCandidates(
  String owner,
  String repo, {
  String subPath = '',
  String? branch,
}) {
  final String clean = subPath.replaceAll(RegExp(r'^/+|/+$'), '');
  // 地址里写明了分支（tree/blob 形态）就先用它 —— 作者往往就在非默认分支上发东西；
  // 再兜 main/master：用户贴的分支名可能已经改名。
  final List<String> branches = <String>[
    if (branch != null && branch.isNotEmpty && branch != 'main' && branch != 'master') branch,
    'main',
    'master',
  ];
  // 贴的是仓库根：根目录优先，再试 `extensions/` 子目录（两种常见放法）。
  // 贴的是某个目录：只试那个目录，最后**再兜一次仓库根** —— 有的作者把 zip 放在
  // `extensions/` 下、catalog.json 却放在根上。
  final List<String> dirs = clean.isEmpty ? const <String>['', 'extensions'] : <String>[clean];
  final List<Uri> out = <Uri>[];
  for (final String b in branches) {
    for (final String dir in dirs) {
      final String path = dir.isEmpty ? 'catalog.json' : '$dir/catalog.json';
      out.add(Uri.parse(
        'https://raw.githubusercontent.com/$owner/$repo/$b/$path',
      ));
    }
  }
  if (clean.isNotEmpty) {
    for (final String b in branches) {
      out.add(Uri.parse(
        'https://raw.githubusercontent.com/$owner/$repo/$b/catalog.json',
      ));
    }
  }
  return out;
}

/// 把用户填的地址展开成"可能是 `catalog.json`"的候选地址（按尝试顺序）。
///
/// 认得的形态：
/// * `https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>` —— 原样；
/// * `https://github.com/<owner>/<repo>`（可带尾斜杠）—— 仓库根 + `extensions/` 下各试一遍；
/// * `https://github.com/<owner>/<repo>/blob/<branch>/<path>` —— 转 raw（**blob 里可能是
///   目录页**：路径不像文件时按目录再试一次）；
/// * `https://github.com/<owner>/<repo>/tree/<branch>/<path...>` —— 转 raw 下的
///   `<path>/catalog.json`，再退到 `<path>` 自身；
/// * 其他地址（自建服务器、本机 http）—— 原样返回，仍由调用方校验内容。
///
/// 认不出来（GitHub 的 releases/用户主页之类）时返回**原地址**：让下载那份代码给出
/// "这个地址上不是 catalog.json"的明确错误，比在这里猜一个不存在的地址更好。
List<Uri> extensionCatalogUrlCandidates(Uri url) {
  final String host = url.host.toLowerCase();
  // 已经就是 raw 地址：不用换算（用户可以直链到任何位置，包括非 catalog 文件名）。
  if (_isGithubRawHost(host)) {
    return url.hasFragment ? <Uri>[_withoutFragment(url)] : <Uri>[url];
  }
  if (!_isGithubPageHost(host)) {
    return url.hasFragment ? <Uri>[_withoutFragment(url)] : <Uri>[url];
  }

  final List<String> segments = url.pathSegments.where((String s) => s.isNotEmpty).toList();
  final ({String owner, String repo, List<String> rest})? repo = _splitRepo(segments);
  if (repo == null) {
    // 用户主页 / 搜索页 / 组织页：没有仓库名，猜不出任何东西。
    return url.hasFragment ? <Uri>[_withoutFragment(url)] : <Uri>[url];
  }

  final List<String> rest = repo.rest;
  if (rest.isEmpty) {
    // 仓库根：默认分支未知 ⇒ main / master × 根目录 / extensions/ 兜一遍。
    return _repoCatalogCandidates(repo.owner, repo.repo);
  }

  final String kind = rest.first;
  if (kind == 'blob' && rest.length >= 3) {
    final String branch = rest[1];
    final String path = rest.sublist(2).join('/');
    // blob 指向的通常是一个文件：先按文件本身试（作者可能把 catalog.json 放在
    // 任意位置、甚至起别的名字）；再按"它其实是个目录"试一层。
    return <Uri>[
      Uri.parse('https://raw.githubusercontent.com/${repo.owner}/${repo.repo}/$branch/$path'),
    ];
  }
  if (kind == 'tree') {
    final String branch = rest.length >= 2 ? rest[1] : 'main';
    final String sub = rest.length > 2 ? rest.sublist(2).join('/') : '';
    return _repoCatalogCandidates(repo.owner, repo.repo, subPath: sub, branch: branch);
  }
  if (kind == 'releases' || kind == 'issues' || kind == 'pull' || kind == 'actions') {
    // 这些页面里没有 catalog.json：原样返回，让调用方报一句人话。
    return <Uri>[url];
  }
  // 其他 `/<owner>/<repo>/<something>`：当成仓库内目录（作者可能贴的是目录地址）。
  return _repoCatalogCandidates(repo.owner, repo.repo, subPath: rest.join('/'));
}

/// 把用户填的**下载**地址展开成候选（目前只换算 GitHub 的 `blob` → raw）。
///
/// 为什么安装 zip 也要这一层：作者一般把 zip 放在仓库里，复制的自然是 `blob` 地址；
/// 而 `blob` 地址返回的是 HTML 页面（带 GitHub 的页头），下载下来会当成坏 zip。
/// releases 的 `.../releases/download/...` 本身就是直链，原样放过。
List<Uri> extensionDownloadUrlCandidates(Uri url) {
  final String host = url.host.toLowerCase();
  if (!_isGithubPageHost(host)) {
    return url.hasFragment ? <Uri>[_withoutFragment(url)] : <Uri>[url];
  }
  final List<String> segments = url.pathSegments.where((String s) => s.isNotEmpty).toList();
  final ({String owner, String repo, List<String> rest})? repo = _splitRepo(segments);
  if (repo == null) return <Uri>[url];
  final List<String> rest = repo.rest;
  if (rest.length >= 3 && rest.first == 'blob') {
    final String branch = rest[1];
    final String path = rest.sublist(2).join('/');
    return <Uri>[
      Uri.parse('https://raw.githubusercontent.com/${repo.owner}/${repo.repo}/$branch/$path'),
    ];
  }
  return <Uri>[url];
}

Uri _withoutFragment(Uri url) => url.hasFragment ? url.removeFragment() : url;
