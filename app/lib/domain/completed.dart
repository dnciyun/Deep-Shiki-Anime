/// 「已完成」页的数据整理（2026-10-12 第十四轮）。
///
/// 用户原话：
/// > 「添加已完成页面，下载好的会在里面，按照名字分类，封面调用bangumi」
/// > （追问后补充）「已完成的可跳转文件夹位置，和直接播放还有删除等」
///
/// 数据源 = 引擎里 `finished` 的 torrent（不扫盘、不猜），按**番名**归成封面卡：
/// 一部番一张卡，展开就是这部番已下完的集。
/// （第二十一轮：「已缓存」页按用户要求删掉了，同一份数据源只剩这一种摆法。）
///
/// ## 第二十四轮：两种摆法（用户原话）
/// > 「已完成页面改成默认是一张一张卡片的形式，可切换回现在的形态」
/// > （追问后补充）「一部番一张卡，点开跟文件夹一样一集一集排着」
///
/// 于是：**默认** [CompletedView.grid]（一部番一张封面卡、并排铺开），点卡片 = 打开它，
/// 里面一集一行、像资源管理器的文件夹；顶部一颗开关切回 [CompletedView.list]
///（= 现在这种"一行一张宽卡 + 点「展开 N 集」"的形态）。归组规则两种摆法完全一样
/// —— 切的是**摆法**，不是数据。
///
/// 全部是纯函数 / 纯编排（副作用以参数传进来），所以不用起引擎就能单测。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'episode_group.dart' show parseEpisodeNumber;
import 'error_text.dart';
import 'models.dart';
import 'recycle_bin.dart';
import 'title_clean.dart';

/// 「已完成」页的两种摆法（第二十四轮）。
enum CompletedView {
  /// 封面卡网格：一部番一张卡、并排铺开；点卡片打开它的集列表。
  grid('封面卡'),

  /// 现在这种一行一张宽卡：点「展开 N 集」看每一集。
  list('列表');

  const CompletedView(this.label);
  final String label;
}

/// 卡里的一集（= 引擎里的一个 torrent：VCB 那种"一等集一个种子"就是一集一个 torrent，
/// 一个种子好几集的合集则在卡里展开成多个文件）。
class CompletedEpisode {
  const CompletedEpisode({
    required this.torrent,
    required this.episode,
    required this.title,
  });

  final EngineTorrentView torrent;

  /// 解析出来的集号（null = 名字里没有集号，比如剧场版/OVA）。
  final int? episode;

  /// 这一集在卡片里显示的名字（原名，不截断 —— 截断交给 UI）。
  final String title;

  /// 集号的显示文本：`51` / `SP` 那种解析不出来的显示「—」。
  String get episodeLabel => episode == null ? '—' : '$episode';
}

/// 一部番（一张卡）。
class CompletedGroup {
  const CompletedGroup({
    required this.key,
    required this.name,
    required this.episodes,
  });

  /// 归组键（`animeGroupKey` 的归一化结果；拿不到番名时是 `raw:<原名>`）。
  final String key;

  /// 卡片标题（清洗后的番名；拿不到番名时是原始 torrent 名）。
  final String name;

  final List<CompletedEpisode> episodes;

  int get count => episodes.length;

  /// 这部番已下完的总字节。
  int get bytes =>
      episodes.fold<int>(0, (int sum, CompletedEpisode e) => sum + e.torrent.totalBytes);

  /// 集数范围文案：`3 集`；连续集号时给 `51–53` 更直观。
  String get episodeRangeLabel {
    final List<int> numbers = <int>[
      for (final CompletedEpisode e in episodes)
        if (e.episode != null) e.episode!,
    ]..sort();
    if (numbers.length >= 2 && numbers.last - numbers.first == numbers.length - 1) {
      return '${numbers.length} 集（${numbers.first}–${numbers.last}）';
    }
    return '${episodes.length} 个文件';
  }
}

/// 把已下完的 torrent 按番名归成卡（顺序：卡内按集号，卡间按最早的集号/名称）。
///
/// 归组判据 = [animeGroupKey]（去括号 + 去集号 + 归一化）。拿不到番名的条目
/// （`[VCB-Studio][x265].mkv` 这种）按**原始名字**单独成卡 —— 它们互相之间也可能
/// 是同一部番，但宿主认不出来，就不硬凑（宁可不合，也不要串片）。
List<CompletedGroup> completedGroups(Iterable<EngineTorrentView> torrents) {
  final Map<String, List<CompletedEpisode>> buckets = <String, List<CompletedEpisode>>{};
  final Map<String, String> names = <String, String>{};

  for (final EngineTorrentView t in torrents) {
    final String? clean = animeSearchName(t.name);
    final String key = clean == null ? 'raw:${t.name.toLowerCase()}' : animeGroupKey(t.name);
    names.putIfAbsent(key, () => clean ?? t.name);
    buckets.putIfAbsent(key, () => <CompletedEpisode>[]).add(
          CompletedEpisode(
            torrent: t,
            episode: _episodeOfTorrent(t),
            title: t.name,
          ),
        );
  }

  final List<CompletedGroup> groups = <CompletedGroup>[
    for (final MapEntry<String, List<CompletedEpisode>> e in buckets.entries)
      CompletedGroup(
        key: e.key,
        name: names[e.key] ?? e.key,
        episodes: e.value.toList()
          ..sort((CompletedEpisode a, CompletedEpisode b) {
            if (a.episode != null && b.episode != null && a.episode != b.episode) {
              return a.episode!.compareTo(b.episode!);
            }
            if (a.episode != null && b.episode == null) return -1;
            if (a.episode == null && b.episode != null) return 1;
            return a.title.compareTo(b.title);
          }),
      ),
  ];

  groups.sort((CompletedGroup a, CompletedGroup b) {
    final int? ea = a.episodes.first.episode;
    final int? eb = b.episodes.first.episode;
    if (ea != null && eb != null && ea != eb) return ea.compareTo(eb);
    return a.name.compareTo(b.name);
  });
  return groups;
}

/// 这一集的集号：从 torrent 名解析（复用播放列表那一套判据，别再造一份）。
int? _episodeOfTorrent(EngineTorrentView t) => parseEpisodeNumber(t.name);

/// 引擎给的 `path` 是**相对 outputFolder 的文件名**，不是绝对路径。
///
/// 真机 dump（第十二轮 `build/probe-seed-r12_torrents.json`）就是：
/// `outputFolder = C:\Users\…\Downloads\Anime\`、`path = xxx.mp4`。
/// 直接拿 `path` 去 `explorer` / 删除会指到"当前工作目录"下的同名文件 ——
/// 这是本轮**最危险**的一处，所以只留这一个函数算绝对路径。
///
/// ⚠️ 文件名里带 `..` 的（恶意种子 / 异常命名）**故意不折叠**：`p.normalize` 会把
/// `..\..\Windows\System32\x.dll` 折成一条看起来人畜无害的绝对路径，而
/// [recyclablePaths] 的 `..` 护栏就再也看不见它了。所以这种情况原样返回，
/// 让护栏在删除前把它挡下（拿它去"打开文件夹"最多是打开一个奇怪的目录，无害）。
String engineFileAbsolutePath(EngineTorrentView torrent, EngineFileView file) {
  final String raw = file.path.trim();
  if (raw.isEmpty) return '';
  final String folder = torrent.outputFolder.trim();
  final String joined =
      (p.isAbsolute(raw) || folder.isEmpty) ? raw : p.join(folder, raw);
  if (p.split(joined).contains('..')) return joined;
  return p.normalize(joined);
}

/// 这个 torrent 所有文件的绝对路径（去重、保序）。
List<String> engineFilesAbsolutePaths(EngineTorrentView torrent) {
  final List<String> out = <String>[];
  final Set<String> seen = <String>{};
  for (final EngineFileView f in torrent.files) {
    final String abs = engineFileAbsolutePath(torrent, f);
    if (abs.isEmpty || !seen.add(abs)) continue;
    out.add(abs);
  }
  return out;
}

/// 这部番里**能播**的那一集的绝对路径（用于「打开文件夹」定位）。
String? playableAbsolutePath(EngineTorrentView torrent) {
  final EngineFileView? file = torrent.playableFile;
  if (file == null) return null;
  return engineFileAbsolutePath(torrent, file);
}

/// 「删文件」的结果（四件事都要如实汇报：进回收站的、本来就没有的、被护栏挡下的、
/// 还剩的警告）。
class CompletedDeleteOutcome {
  const CompletedDeleteOutcome({
    required this.recycled,
    this.missing = const <String>[],
    this.blocked = const <String>[],
    this.engineWarning,
    this.failure,
  });

  /// 真的进了回收站的条目数。
  final int recycled;

  /// 已经不在磁盘上的（外部删过/移走过）——不算失败，但要说出来。
  final List<String> missing;

  /// 被安全护栏挡下的路径（见 [recyclablePaths]）——**永远不删**，只报告。
  final List<String> blocked;

  /// 引擎那一步的警告（`removeByEngine` 的返回值：记录删了但引擎没删成功）。
  final String? engineWarning;

  /// 回收站这一步整个失败（用户要看到怎么办）。
  final String? failure;
}

/// 「删除文件到回收站」的完整流程（**顺序不能换**）。
///
/// 1. 先算好要回收的**文件**绝对路径（引擎给的 path 是相对的），并过一遍护栏；
/// 2. `移除任务(deleteFiles: false)`：先把 torrent 从引擎拿掉，**不能带 deleteFiles** ——
///    带上的话引擎会把文件**永久删除**，回收站里就什么都没有了（这正是本轮要改的事）；
/// 3. 再把这些文件移进回收站（可恢复）。
///
/// 顺序为什么必须是"先移除任务"：反过来的话，文件已经离开原位、而引擎还挂着这个
/// torrent，它下一轮扫描会发现文件消失、把任务标成错误 —— 用户看到一条坏任务。
///
/// 副作用全部以参数传入（[removeFromEngine] / [recycle]），所以本函数可单测。
Future<CompletedDeleteOutcome> deleteCompletedFiles({
  required EngineTorrentView torrent,
  required Future<String?> Function(int engineId) removeFromEngine,
  required Future<int> Function(List<String> paths) recycle,
  String? downloadRoot,
}) async {
  final List<String> all = engineFilesAbsolutePaths(torrent);
  final List<String> targets = recyclablePaths(all, downloadRoot: downloadRoot);
  final Set<String> targetKeys = <String>{for (final String s in targets) s.toLowerCase()};
  final List<String> blocked = <String>[
    for (final String s in all)
      if (!targetKeys.contains(s.toLowerCase())) s,
  ];
  final List<String> missing = <String>[
    for (final String s in targets)
      if (!File(s).existsSync() && !Directory(s).existsSync()) s,
  ];

  final String? engineWarning;
  try {
    engineWarning = await removeFromEngine(torrent.id);
  } catch (error, stackTrace) {
    // ⚠️ 移除任务失败就**到此为止，一个文件都不动**：引擎还挂着这个 torrent，
    // 文件先走了它下一轮扫描就会发现文件消失、把任务标成错误（上面"顺序"那段说的
    // 就是这件事）。所以以失败收场，并明说"文件没动"。
    //
    // 第四十二轮 UX #13：这一次 await 原来在 try 之外 —— 它抛异常时整函数直接
    // 从这里冒出去，调用方那句 `if (outcome.failure != null)` 根本轮不到执行，
    // 用户看到的是"确认之后一片寂静：对话框关了、什么都没发生、零说明"。
    final DsFailure f = describeFailure(error, stackTrace: stackTrace);
    return CompletedDeleteOutcome(
      recycled: 0,
      missing: missing,
      blocked: blocked,
      failure: '没能从引擎里移除这个任务，所以文件一个都没动。${f.message}'
          '${f.hint == null ? '' : '\n怎么办：${f.hint}'}',
    );
  }

  if (targets.isEmpty) {
    return CompletedDeleteOutcome(
      recycled: 0,
      missing: missing,
      blocked: blocked,
      engineWarning: engineWarning,
    );
  }
  try {
    final int moved = await recycle(targets);
    return CompletedDeleteOutcome(
      recycled: moved,
      missing: missing,
      blocked: blocked,
      engineWarning: engineWarning,
    );
  } on RecycleBinException catch (e) {
    return CompletedDeleteOutcome(
      recycled: 0,
      missing: missing,
      blocked: blocked,
      engineWarning: engineWarning,
      failure: e.hint == null ? e.message : '${e.message}\n怎么办：${e.hint}',
    );
  } catch (error, stackTrace) {
    // 不再 `'$error'`（整串技术文本，还可能带本机路径）—— 走统一文案（UX #15）。
    final DsFailure f = describeFailure(error, stackTrace: stackTrace);
    return CompletedDeleteOutcome(
      recycled: 0,
      missing: missing,
      blocked: blocked,
      engineWarning: engineWarning,
      failure: f.hint == null ? f.message : '${f.message}\n怎么办：${f.hint}',
    );
  }
}
