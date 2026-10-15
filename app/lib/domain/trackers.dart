/// 公共 tracker 列表及其**来源**（spec §3.7 + §7.3 Q19②）。
///
/// 引擎自己有一份兜底默认列表；宿主这份是给用户「看得见、能一键写入设置」用的。
///
/// 用户 2026-10-10 的清单要求：**参照 BitComet 的做法**，内置列表来自
/// ngosang 的 `trackers_best.txt`（社区每天更新、被多数客户端采用），
/// 一键更新时优先联网拉这份列表，拉不到才回落到下面这份离线快照。
///
/// 用户 2026-10-11 追加要求：「加强下 tracker，可通过导入
/// <https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt>
/// 获取内的所有 tracker，也可以使用多条获取」—— 所以这里从「一条写死的 URL」
/// 升级成**一份用户可编辑的来源清单**（[trackerSourcePresets] 是常用来源，
/// 一条一键更新会把**全部来源**拉下来合并去重）。
library;

import 'package:flutter/foundation.dart' show immutable;

/// ngosang 维护的公共 tracker 精选列表（BitComet / qBittorrent 等都在用这个源）。
const String kTrackersListUrl =
    'https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt';

/// 同一个仓库的**全量**列表：条目比 best 多得多（用户想要"里面的所有 tracker"时用这条）。
const String kTrackersAllUrl =
    'https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all.txt';

/// 同一份 best 的 jsDelivr 镜像：直连 `raw.githubusercontent.com` 不稳时用。
const String kTrackersBestMirrorUrl =
    'https://cdn.jsdelivr.net/gh/ngosang/trackerslist@master/trackers_best.txt';

/// 一个可选的 tracker 来源（UI 里做成「一键加上」的按钮）。
@immutable
class TrackerSourcePreset {
  const TrackerSourcePreset(this.label, this.url, {this.hint = ''});

  final String label;
  final String url;
  final String hint;
}

/// 内置的可选来源：**不写进设置**，只是给用户点一下就填进来源清单。
const List<TrackerSourcePreset> trackerSourcePresets = <TrackerSourcePreset>[
  TrackerSourcePreset('best（推荐）', kTrackersListUrl, hint: 'ngosang 每日精选，BitComet / qBittorrent 同源'),
  TrackerSourcePreset('all（全量）', kTrackersAllUrl, hint: '同仓库全量列表，条目多得多'),
  TrackerSourcePreset('best 镜像', kTrackersBestMirrorUrl, hint: 'jsDelivr 镜像，直连 GitHub 不稳时用'),
];

/// 默认来源清单：就一条 best（与旧行为一致，升级不改变已有用户的抓取结果）。
const List<String> kDefaultTrackerSourceUrls = <String>[kTrackersListUrl];

/// 与引擎内置一致的公共 tracker（spec §3.7）：**离线快照**，联网拉取失败时用。
const List<String> builtinTrackers = <String>[
  'udp://tracker.opentrackr.org:1337/announce',
  'udp://open.stealth.si:80/announce',
  'udp://tracker.torrent.eu.org:451/announce',
  'udp://exodus.desync.com:6969/announce',
  'http://tracker.anirena.com:80/announce',
  'udp://tracker.dler.org:6969/announce',
];

/// 逗号分隔形态（引擎 `--trackers` 参数）。
String trackerListText(List<String> trackers) => trackers.join(',');

/// 解析用户手填/粘贴的列表（支持逗号、空格、换行分隔，去重保序）。
List<String> parseTrackerList(String raw) {
  final List<String> out = <String>[];
  for (final String piece in raw.split(RegExp(r'[,\s]+'))) {
    final String value = piece.trim();
    if (value.isEmpty) continue;
    if (out.contains(value)) continue;
    out.add(value);
  }
  return out;
}

/// 多个来源的响应合并成一份：**按来源顺序拼接 + 跨来源去重保序**。
///
/// 顺序有意义（引擎按顺序尝试），所以不做排序；去重是为了同样的 tracker
/// 在 best 与 all 里重复出现时不会把列表撑成两倍。
List<String> mergeTrackerLists(Iterable<List<String>> lists) {
  final List<String> out = <String>[];
  final Set<String> seen = <String>{};
  for (final List<String> list in lists) {
    for (final String tracker in list) {
      final String value = tracker.trim();
      if (value.isEmpty || !seen.add(value)) continue;
      out.add(value);
    }
  }
  return out;
}

/// 这个字符串能不能当来源 URL（http/https、有主机名）。
///
/// UI 层的用途：用户粘贴的东西五花八门，**先拦掉**再进来源清单，
/// 否则一键更新时只会得到一条"取值失败"的分支，看不出到底哪里填错了。
bool isTrackerSourceUrl(String raw) {
  final Uri? uri = Uri.tryParse(raw.trim());
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  return uri.host.isNotEmpty;
}

/// 来源清单规范化：去掉空白项、无效项与重复项（保序），供 UI 与存储共用。
List<String> normalizeTrackerSourceUrls(Iterable<String> raw) {
  final List<String> out = <String>[];
  for (final String url in raw) {
    final String value = url.trim();
    if (!isTrackerSourceUrl(value)) continue;
    if (out.contains(value)) continue;
    out.add(value);
  }
  return out;
}
