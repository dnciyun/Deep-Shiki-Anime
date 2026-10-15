/// 从「正在播的那一条」的标题里用**正则**切出搜索关键字与系列指纹。
///
/// 用户原话：
/// > 播放列表里的视频不全，加逻辑，播放视频后，使用正则方式加载其他全集。
///
/// 为什么要专门一个纯函数：关键字是"拿去源站搜别的集"的唯一输入，切坏了就是两种
/// 坏结果之一 ——
/// * 切得太长（把 `1080p`、`AVC AAC`、`CHT`、截断标记 `…` 带进去）⇒ 源站的关键字
///   搜索基本命中不了任何条目，白打一次请求；
/// * 切得太短（只剩 `01`、只剩一个字母）⇒ 捞回一堆别的番，还会浪费归组预算。
/// 所以这里的原则是**宁可返回 null 不搜**，也不要用垃圾关键字去打源站。
///
/// 判"新一批算不算同一部番"的 [isSameSeriesItem] 刻意与 `playlistFor` 的归组判据
/// 逐条对齐（同源 + 同组名 + 同集号指纹 + 集号可解析）：不对齐就会出现"判为同系列、
/// 翻页也翻了，最后却被归组丢掉"的白工。
library;

import 'package:flutter/foundation.dart';

import 'episode_group.dart' show episodeFingerprint;
import 'models.dart';
import 'playlist.dart' show episodeOf;

/// 关键字至少要有几个「有意义字符」（字母 / 中日韩文字）。
///
/// 2 是实测下限：`某番` 这种两字中文名要能用来搜（mikan 上很常见），
/// 而单字（`某 - 01`）太容易撞车 —— 不如不搜。
const int kMinSeriesKeywordLength = 2;

/// 别名（`中文 / Romaji` 这种标题里的单个名字）最多给几个，供 loader 兜底尝试。
const int kMaxSeriesAliases = 2;

/// 一条「去哪里搜同系列其它集」的线索。
@immutable
class SeriesSearchQuery {
  const SeriesSearchQuery({
    required this.keyword,
    required this.fingerprint,
    this.group,
    this.aliasKeywords = const <String>[],
  });

  /// 主关键字：集号之前、去掉方括号标签与技术标记之后的那段片名。
  final String keyword;

  /// [episodeFingerprint] 的结果：判"新一批算不算同一部番"的键。
  ///
  /// 用**同一个函数**（而不是另写一份）是为了与 `playlistFor` 的归组一致 ——
  /// 只有指纹相同的条目才会被归进同一组，另写一份就有对不上的风险。
  final String fingerprint;

  /// 压制组 / 字幕组的归一化名；null = 宿主没给（此时 loader 不会去搜，
  /// 因为 `playlistFor` 拿不到组名本来就不会归组）。
  final String? group;

  /// 兜底关键字：主关键字一个同系列条目都没命中时才会用到（见 [seriesSearchQueryFor]）。
  final List<String> aliasKeywords;

  @override
  String toString() =>
      'SeriesSearchQuery($keyword, group=$group, alias=$aliasKeywords)';
}

/// 集号标记（**顺序即优先级**，与 `episode_group.dart` 的 `episodeFingerprint`
/// 用的是同一组形态、同一条"第一个命中的模式胜出"规则）。
///
/// 为什么必须同源：指纹把「集号及其之后」整段切掉，关键字也要切在**同一处**；
/// 两边规则不一致时，新搜到的条目会因为指纹对不上而被归组丢掉，等于白搜。
final List<RegExp> _kEpisodeMarkers = <RegExp>[
  RegExp(r'[Ss]\d{1,2}[Ee]\d{1,3}'),
  RegExp(r'\b[Ee][Pp]\.?\s?\d{1,3}(?![0-9])'),
  RegExp(r'第\s*\d{1,3}\s*[话話集]'),
  RegExp(r'[-–—]\s*\d{1,3}(?=\s|\[|\(|$|\.)'),
  RegExp(r'\[\s*\d{1,3}\s*\]'),
  RegExp(r'[_ ]\d{1,3}(?=[_ \.]|$)'),
];

/// 第一个命中的集号标记；找不到返回 null。
RegExpMatch? _episodeMarker(String title) {
  for (final RegExp re in _kEpisodeMarkers) {
    final RegExpMatch? m = re.firstMatch(title);
    if (m != null) return m;
  }
  return null;
}

/// 方括号/圆括号标签：`[Skymoon-Raws]`、`[ViuTV]`、`[1080p]`、`(TV)`、`【】`。
final RegExp _kBracketTag = RegExp(r'[\[\(（【]\s*[^\[\]\(\)（）【】]*\s*[\]\)）】]');

/// 写在方括号**之外**的技术/语言标记（有些源不给方括号）。
///
/// 用"前后不是字母数字"的边界做整词匹配、不按子串删：`AAC`、`AVC`、`BD` 这类短词
/// 一旦按子串匹配，会把真实片名里的字母一起吃掉。
///
/// **公开**（第十七轮起）：`title_clean.dart` 的兜底也要判"这一段括号内容是不是
/// 纯技术标记"，判别清单必须与这里**同一份**（两份清单一定会漂移）。
final RegExp kNoiseToken = RegExp(
  r'(?<![0-9A-Za-z])(?:'
  r'\d{3,4}\s*[pi]' // 1080p / 2160p / 480i
  r'|\d{3,4}\s*[x×]\s*\d{3,4}' // 1920x1080
  r'|4k|8bit|10bit|12bit|hi10p|ma10p'
  r'|x26[45]|h\.?26[45]|hevc|avc|av1|vp9'
  r'|aac|flac|ac3|eac3|dts(?:-hd)?|opus|truehd'
  r'|web-?dl|web-?rip|bdrip|bdmv|bluray|blu-ray|hdtv|tvrip|dvdrip'
  r'|cht|chs|jpsc|jptc|multi-?sub'
  r'|简繁|简体|繁体|内嵌|外挂|双语|中日'
  // 第十七轮补：发布标记（`无修正` / `uncensored` / `简日`）也算噪音 ——
  // `title_clean.dart` 的兜底靠这张清单判"这一段括号内容是不是纯标记"。
  r'|无修(?:正)?|uncensored|简日|繁日|简繁日|日语|中字|无删减'
  r')(?![0-9A-Za-z])',
  caseSensitive: false,
);

/// 关键字首尾的纯分隔符（方括号标签被拿掉后常留下一串）。
///
/// 刻意**不含** `…`：它是片名的一部分（列表页截断留下的），不属于分隔符。
final RegExp _kEdgeTrim = RegExp(r'^[\s\-–—_.,;:|/\\·]+|[\s\-–—_.,;:|/\\·]+$');

/// 中英混排标题里「两个名字」的分隔符：`某某 / Romaji Title`。
final RegExp _kAliasSplit = RegExp(r'\s*[/／|｜]\s*');

/// 末尾的截断标记（`Tsuihou …`、`Show...`）—— 只对**别名**去，见 [_aliasKeywordsFor]。
final RegExp _kTrailingEllipsis = RegExp(r'[\s]*[.．。…]+[\s]*$');

/// 有意义的「字」：拉丁/带音标/希腊/西里尔字母与中日韩文字。
///
/// 为什么不用 `\w`：Dart 的 `\w` 默认只认 ASCII，中文片名会全被判成"没有字"。
final RegExp _kLetterish = RegExp(
  r'[A-Za-z\u00c0-\u024f\u0370-\u03ff\u0400-\u04ff\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]',
);

/// 「字或数字」：用来数关键字里有多少有意义字符。
final RegExp _kWordish = RegExp(
  r'[0-9A-Za-z\u00c0-\u024f\u0370-\u03ff\u0400-\u04ff\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]',
);

/// 从标题切出搜索关键字；**切不出像样的关键字就返回 null**。
///
/// 覆盖的真实命名（用例在 `test/series_search_test.dart`）：
/// * `[Skymoon-Raws] 遭到流放的转生重骑士 / Tsuihou … - 01 [ViuTV][WEB-DL][CHT][1080p][AVC AAC]`
///   → `遭到流放的转生重骑士 / Tsuihou …`
/// * `[ANi] 某番 - 12 [1080P][Baha]` → `某番`
/// * `某番 第07话` → `某番`
/// * `Show.S01E07.1080p` → `Show`
///
/// [group] 由调用方（宿主条目）给，宿主没解析出来就是 null —— 这里不从标题里猜组名：
/// 猜错会把别的组并进列表，而 `playlistFor` 用的就是宿主那一份，两边必须同一个来源。
SeriesSearchQuery? seriesSearchQueryFor(String title, {String? group}) {
  final String raw = title.trim();
  if (raw.isEmpty) return null;

  // 1. 切掉集号及其之后的一切（`- 01 [ViuTV][WEB-DL][CHT][1080p][AVC AAC]`）。
  //    切不出集号 ⇒ 这一条不是"某一集"（合集/整季包/SP），按它的标题搜回来的单集
  //    条目指纹必然与它不同、进不了列表 —— 宁可不动。
  final RegExpMatch? marker = _episodeMarker(raw);
  if (marker == null) return null;
  final String head = raw.substring(0, marker.start);

  // 2. 去掉方括号标签：`[Skymoon-Raws] 遭到流放的转生重骑士 / Tsuihou …`
  //    在这里变成 ` 遭到流放的转生重骑士 / Tsuihou … `。
  String keyword = head.replaceAll(_kBracketTag, ' ');

  // 3. 收拾方括号外的技术/语言标记，再收敛空白与首尾分隔符。
  keyword = keyword.replaceAll(kNoiseToken, ' ');
  keyword = keyword.replaceAll(RegExp(r'\s+'), ' ').trim();
  keyword = keyword.replaceAll(_kEdgeTrim, '').trim();

  if (!_isUsableKeyword(keyword)) return null;

  return SeriesSearchQuery(
    keyword: keyword,
    fingerprint: episodeFingerprint(raw),
    group: normalizedGroupName(group),
    aliasKeywords: _aliasKeywordsFor(keyword),
  );
}

/// 关键字够不够格拿去搜（保守判据，见文件头）。
bool _isUsableKeyword(String keyword) {
  // 必须含至少一个"字"（不是纯数字/符号）：`01`、`1080` 是集号/分辨率不是片名，
  // 拿它们去搜只会捞回一堆无关条目。
  if (!_kLetterish.hasMatch(keyword)) return false;
  // 有意义字符至少 [kMinSeriesKeywordLength] 个：`某番` 这种两字中文名要能用。
  return _kWordish.allMatches(keyword).length >= kMinSeriesKeywordLength;
}

/// 从主关键字里切出单个「名字」作为兜底关键字（最多 [kMaxSeriesAliases] 个）。
///
/// 为什么需要兜底：`中文名 / Romaji` 这种拼接串在源站的关键字搜索里几乎必定搜不到
/// （站点的标题要么是完整罗马字、要么是完整中文，不会是这么一段拼接）。退回单个名字
/// 才可能命中；而"是不是同一部番"仍由指纹 + 组名判定，所以多试一次不会串片。
///
/// 别名里的截断标记必须去掉：`Tsuihou …` 里的 `…` 是列表页截断留下的，
/// 带着它永远不可能命中任何标题（主关键字保留原样是刻意的，见测试里的期望值）。
List<String> _aliasKeywordsFor(String keyword) {
  final List<String> out = <String>[];
  for (final String part in keyword.split(_kAliasSplit)) {
    if (out.length >= kMaxSeriesAliases) break;
    final String alias = part
        .replaceAll(_kTrailingEllipsis, '')
        .replaceAll(_kEdgeTrim, '')
        .trim();
    if (alias == keyword || out.contains(alias)) continue;
    if (!_isUsableKeyword(alias)) continue;
    out.add(alias);
  }
  return List<String>.unmodifiable(out);
}

/// 组名归一化：`Skymoon-Raws` / `skymoon raws` / ` Skymoon_Raws ` → `skymoon-raws`。
///
/// 为什么归一化：同一个组在源站的写法会在空格/下划线/连字符之间飘（mikan 番剧页的
/// 字幕组名与 RSS 标题里的方括号标签就常不一致）。分隔符统一成 `-` 而不是删掉，
/// 是为了保住 `A-One` 与 `AOne` 的区别。
String? normalizedGroupName(String? raw) {
  final String text = (raw ?? '').trim().toLowerCase();
  if (text.isEmpty) return null;
  final String normalized = text
      .replaceAll(RegExp(r'[\s_\-–—.]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return normalized.isEmpty ? null : normalized;
}

/// 新搜到的 [other] 算不算"正在播的 [base] 那一部番"。
///
/// 判据与 `playlistFor` 的归组规则**逐条对齐**（同源 + 同组名 + 同集号指纹 +
/// 集号可解析），因为不对齐就会出现"判为同系列、翻页也翻了，最后却被归组丢掉"的
/// 白工。保守是第一位的：判错会把别的番并进播放列表。
bool isSameSeriesItem(SourceItemView base, SourceItemView other) {
  if (other.id == base.id) return false;
  if (other.sourceId != base.sourceId) return false;
  // 组名只认宿主给的那一份（与 `playlistFor` 同源）；不从标题里猜。
  final String? mine = normalizedGroupName(base.group);
  final String? theirs = normalizedGroupName(other.group);
  if (mine == null || theirs == null || mine != theirs) return false;
  // 集号解析不出来的（SP01 / 纯合集）`playlistFor` 不会收，这里也排除 ——
  // 否则"这一页有新增"的计数会被它们虚报，让我们在该继续翻页的页面上提前收手。
  if (episodeOf(other) == null) return false;
  final String a = episodeFingerprint(base.title ?? '');
  final String b = episodeFingerprint(other.title ?? '');
  if (a.isEmpty || b.isEmpty) return false;
  return a == b;
}
