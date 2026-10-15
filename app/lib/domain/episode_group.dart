/// 同剧集归组（宿主侧）—— 决策 B31 的落地。
///
/// 用户的原始要求（原话）：
/// > 「在哪播的在哪搜，比如播放 `[Skymoon-Raws] 遭到流放的转生重骑士… - 01 [ViuTV]…`，
/// > 那么在他的播放列表里就有 `… - 01 …`、`… - 02 …`」
///
/// 两种场景：
/// * **网流（引擎 HTTP）**：一个 torrent 里通常就是一个合集，里面按 `- 01 / - 02`
///   命名各集，每集有自己的 per-file 串流 URL（`streamUrl(id, fileIndex)`）。
/// * **本地文件**：同一个文件夹里同名不同集。
///
/// 归组规则（保守，宁可少给一集也不要把无关的片子串进去）：
/// 1. 目录必须相同（网流场景 = torrent 相同）；
/// 2. 从文件名里切出「集号之前的那段」作为剧集指纹，指纹（去空白、转小写）必须相同；
/// 3. 从文件名里解析出的集号必须成功 —— 解析不出来就不参与归组（不会把
///    `[Skymoon-Raws] 遭到流放的转生重骑士 / SP01` 之类混进正片集）；
/// 4. 结果按集号升序，同集号按文件名自然序。
library;

import 'package:path/path.dart' as p;

/// 一个可播放的条目（与 shikiin 的 `MediaItem` 解耦，便于纯函数测试）。
class EpisodeEntry {
  const EpisodeEntry({
    required this.title,
    required this.path,
    this.streamUri,
    this.episode,
  });

  /// 显示标题（一般用文件名去掉扩展名）。
  final String title;

  /// 本地路径；网流场景下是 URL 文本（保持与 `MediaItem.path` 一致）。
  final String path;

  /// 网流：带 token 的完整串流 URL。本地文件为 null。
  final Uri? streamUri;

  /// 解析出的集号（归组内部用；null = 没解析出来）。
  final int? episode;

  @override
  String toString() => 'EpisodeEntry($episode, $title)';
}

/// 分组结果：一组剧集 + 当前在放的那一集的下标。
class EpisodeGrouping {
  const EpisodeGrouping(this.entries, this.currentIndex);

  final List<EpisodeEntry> entries;
  final int currentIndex;

  bool get hasPrev => currentIndex > 0;
  bool get hasNext => currentIndex >= 0 && currentIndex < entries.length - 1;
  EpisodeEntry? get prev => hasPrev ? entries[currentIndex - 1] : null;
  EpisodeEntry? get next => hasNext ? entries[currentIndex + 1] : null;
}

/// 归组用的「所在位置」：本地文件 = 目录；HTTP 串流 = **torrent 级前缀**。
///
/// ⚠️ 这里不能用 `p.dirname` 处理 URL：它会把 URL 的路径段当目录，于是
/// `…/torrents/3/files/0/stream` 与 `…/3/files/1/stream` 会得到**不同的目录**
/// （`…/files/0` vs `…/files/1`），同 torrent 的剧集永远归不到一组。
/// 这个 bug 是 `episode_group_test.dart` 的网流用例抓出来的。
///
/// 引擎的 per-file URL 形状固定为 `<base>/torrents/{id}/files/{idx}/stream?token=…`，
/// 所以取 `/files/` 之前的那一段做键（保留 host，避免跨引擎撞号）。
String episodeLocationKey(String pathOrUrl) {
  final Uri? uri = Uri.tryParse(pathOrUrl);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    final String marker = '/files/';
    final int at = uri.path.indexOf(marker);
    final String prefix =
        at >= 0 ? uri.path.substring(0, at) : uri.path;
    return '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}$prefix'
        .toLowerCase();
  }
  return p.dirname(pathOrUrl).toLowerCase();
}

/// 从文件名里解析集号。
///
/// 覆盖真实遇到的命名：
/// `… - 01 [ViuTV]…` / `… -01.mkv` / `第03话` / `[Group] Show EP12` /
/// `Show.S01E07.1080p` / `Show_05_简繁` / `Show [03].mkv`。
///
/// 排除（实测踩过）：`1080p` / `2160p` 这类分辨率、`19xx–20xx` 年份、
/// `x264` / `H.264` / `AVC AAC` 这类编解码标记 —— 早期实现把 `[AVC AAC]`
/// 里的 `264` 当成了集号 264（测试 `episode_group_test.dart` 抓住的）。
int? parseEpisodeNumber(String fileName) {
  final String base = p.basenameWithoutExtension(fileName);

  // 优先匹配强模式：S01E07 / EP07 / 第07话 / - 07 / 尾部 [_ 07]
  final List<RegExp> strong = <RegExp>[
    RegExp(r'[Ss]\d{1,2}[Ee](\d{1,3})'),
    RegExp(r'\b[Ee][Pp]\.?\s?(\d{1,3})(?![0-9])'),
    RegExp(r'第\s*(\d{1,3})\s*[话話集]'),
    RegExp(r'[-–—]\s*(\d{1,3})(?=\s|\[|\(|$|\.)'),
    RegExp(r'\[\s*(\d{1,3})\s*\]'),
    RegExp(r'[_ ](\d{1,3})(?=[_ \.]|$)'),
  ];
  for (final RegExp re in strong) {
    final RegExpMatch? m = re.firstMatch(base);
    if (m != null) {
      final int? v = int.tryParse(m.group(1)!);
      if (v != null && v > 0 && v <= 999) return v;
    }
  }

  // 兜底：右起第一个「不在方括号里」的独立数字（方括号里多是分辨率/编码/字幕组尾标）。
  final RegExp weak = RegExp(r'(?<![0-9\[])(\d{1,3})(?![0-9\]])');
  final List<RegExpMatch> all = weak.allMatches(base).toList();
  for (final RegExpMatch m in all.reversed) {
    final int? v = int.tryParse(m.group(1)!);
    if (v == null || v <= 0) continue;
    if (_kBoringNumbers.contains(v)) continue;
    if (v >= 1900 && v <= 2099) continue;
    return v;
  }
  return null;
}

/// 这些数字在番剧文件名里几乎一定不是集号（分辨率/编码/帧率）。
const Set<int> _kBoringNumbers = <int>{
  10, 12, // 10bit / 12bit
  23, 24, 25, 30, 50, 60, 120, // 帧率
  264, 265, 266, 270, 272, 480, 540, 576, 720, 1080, 1440, 2160, 4320,
  444, // yuv444
};

/// 把「集号及其之后的内容」整段切掉（**保留原大小写**，不做归一化）。
///
/// [fileName] 传已去掉扩展名的名字最稳（`episodeFingerprint` 会先做这一步）；
/// 但直接传完整文件名也不会错 —— 这些「集号标记」的模式都不吃扩展名。
///
/// [minBareDigits]：**裸数字**（`Show 05` 里那个 `05`，前面只有一个空格/下划线）
/// 至少几位才算集号。剧集指纹用默认 1（`Show_05_简繁` 必须切）；
/// 番名搜索（`title_clean.dart`）用 2 —— `K-ON! 2`、`Re:Zero 2` 是**第二季**，
/// 当作集号切掉会搜到第一季去。带分隔符的形式（`- 03` / `第3话` / `EP03` / `S01E03`）
/// 不受这个参数影响，永远是集号。
String stripEpisodeMarker(String fileName, {int minBareDigits = 1}) {
  String base = fileName;

  final List<RegExp> cutters = <RegExp>[
    RegExp(r'[Ss]\d{1,2}[Ee]\d{1,3}'),
    RegExp(r'\b[Ee][Pp]\.?\s?\d{1,3}(?![0-9])'),
    RegExp(r'第\s*\d{1,3}\s*[话話集]'),
    RegExp(r'[-–—]\s*\d{1,3}(?=\s|\[|\(|$|\.)'),
    RegExp(r'\[\s*\d{1,3}\s*\]'),
    // ⚠️ 这里必须用字符串拼接而不是 `r'...{$minBareDigits,3}...'`：
    // **Dart 的 raw string 不做插值**（`r'$x'` 就是字面 `$x`），写成一整条 raw string
    // 会把 `{$minBareDigits,3}` 原样塞进正则、永远匹配不上（实测踩过，
    // `zz_probe` 打印出的 pattern 就是 `\d{$minBareDigits,3}`）。
    RegExp(r'[_ ]\d{' + minBareDigits.toString() + r',3}(?=[_ \.]|$)'),
  ];
  for (final RegExp re in cutters) {
    final RegExpMatch? m = re.firstMatch(base);
    if (m != null) {
      base = base.substring(0, m.start);
      break;
    }
  }
  // 去掉尾部空白与分隔符（`… - ` 这种切完会剩一条尾巴）。
  return base.replaceAll(RegExp(r'[\s_\-–—/\\|]+$'), '').trim();
}

/// 剧集指纹：把「集号及其之后的内容」整段切掉，只留前面的稳定部分。
///
/// 例：`[Skymoon-Raws] 遭到流放的转生重骑士 / Tsuihou … - 01 [ViuTV][WEB-DL][CHT][1080p][AVC AAC]`
/// → 指纹 `[skymoon-raws] 遭到流放的转生重骑士 / tsuihou …`，
/// 于是 01 与 02 同指纹 → 同组。
String episodeFingerprint(String fileName) {
  final String base = stripEpisodeMarker(p.basenameWithoutExtension(fileName));
  // 归一化：合并空白、转小写。
  return base.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
}

/// 把一批候选文件按 B31 规则归成「当前这一集所在的那一组」。
///
/// [candidates] 的 `path` 用于算目录与指纹；[currentPath] 必须能在其中找到
/// （按 `path` 精确匹配），否则返回 null（无法定位就不给上一集/下一集，
/// 而不是猜一个像是"下一集"的东西）。
///
/// 返回的 `entries` 已按集号升序；`currentIndex` 指向 [currentPath] 那一项。
EpisodeGrouping? groupEpisodes(
  Iterable<EpisodeEntry> candidates,
  String currentPath,
) {
  final List<EpisodeEntry> all = candidates.toList();
  EpisodeEntry? current;
  for (final EpisodeEntry e in all) {
    if (e.path == currentPath) current = e;
  }
  if (current == null) return null;

  // 只有集号解析成功、且与当前集同目录同指纹的条目才算同组。
  final int? currentEp = current.episode ?? parseEpisodeNumber(current.path);
  final String currentDir = episodeLocationKey(current.path);
  final String currentKey = episodeFingerprint(p.basename(current.path));
  // **调用方显式给了集号**（= 宿主从引擎文件清单构造的网流）时，
  // 用「同目录」当系列判据：一个 torrent 内的文件天然是同一部番，
  // 而每集 URL 不同 → 按 URL 算指纹必然各不相同。
  final bool explicitMode = current.episode != null;

  final List<EpisodeEntry> group = <EpisodeEntry>[];
  for (final EpisodeEntry e in all) {
    final String name = p.basename(e.path);
    final int? ep = e.episode ?? parseEpisodeNumber(name);
    if (ep == null) continue;
    if (episodeLocationKey(e.path) != currentDir) continue;
    if (!explicitMode && episodeFingerprint(name) != currentKey) continue;
    group.add(EpisodeEntry(
      title: e.title,
      path: e.path,
      streamUri: e.streamUri,
      episode: ep,
    ));
  }
  if (group.length <= 1) return null;

  group.sort((EpisodeEntry a, EpisodeEntry b) {
    final int byEp = (a.episode ?? 0).compareTo(b.episode ?? 0);
    if (byEp != 0) return byEp;
    return a.title.compareTo(b.title);
  });

  int index = 0;
  for (int i = 0; i < group.length; i++) {
    if (group[i].path == currentPath) index = i;
  }
  // 当前集本轮没进组（例如它的集号没解析出来）：退化为按集号找最近的一集。
  if (group[index].path != currentPath && currentEp != null) {
    index = 0;
    for (int i = 0; i < group.length; i++) {
      if ((group[i].episode ?? 0) <= currentEp) index = i;
    }
  }
  return EpisodeGrouping(group, index);
}
