/// 番名清洗（2026-10-12 第十四轮）：从种子名 / 文件名里提取**「只搜名字」的那个名字**。
///
/// 用户原话与例子：
/// > 「bangumi搜索逻辑去除框里面的只搜名字，比如
/// >  `[hyakuhuyu&VCB-Studio] Re Zero kara Hajimeru Isekai Seikatsu 3rd Season
/// >   [51][Ma10p_1080p][x265_flac_aac].CHS.mp4`
/// >  只搜 `Re Zero kara Hajimeru Isekai Seikatsu 3rd Season`」
///
/// 分三步（顺序不能换）：
/// 1. 去掉**媒体扩展名**（`.mp4` / `.mkv` / `.ass` …；用白名单，不是"最后一个点之后"）；
/// 2. 去掉所有成对括号分组 `[...]` / `【...】` / `(...)` / `（...）`
///    —— 组名、集号、画质、编码、字幕语言几乎全在这几种括号里；
/// 3. 去掉尾巴上还挂着的语言标记（`.CHS` / `.BIG5` / `简体` …）与多余空白 / 分隔符。
///
/// **第 2 步的例外（第十七轮补）**：有些中文命名把**番名自己也放在括号里**——
/// `【今晚月色真美】[女友的朋友 / 彼女の友达 / Kanojo no Tomodachi][02][WebRip]…`
/// （用户 2026-10-12 真机报「什么都搜不到」的那条）。全删之后一个字都不剩，
/// 于是走 [_titleFromBrackets] 兜底：从括号里挑最像番名的那一段。
///
/// 第 1 步为什么用白名单：`Re Zero 2.0`、`Fate/stay night (2014)` 这类名字里的"点"
/// 不都是扩展名，按"最后一个点"切会吃掉真名。
///
/// 另外两种调用（第十四轮一起定下来）：
/// * [animeSearchName] = 上面三步 **再切掉集号**（`stripEpisodeMarker`）。用户例子里
///   的集号是 `[51]` 被括号步骤带走的，但真实命名里还有没包起来的 ——
///   `… JOJO的奇妙冒险 - 03 [NF WEB-DL 1080p…]` 清洗后剩 `… - 03`，
///   拿这个去 bangumi 搜是搜不到那一部的。bangumi 封面匹配与「已完成」页分组都用它。
/// * [animeGroupKey] = [animeSearchName] 的归一化键（大小写/标点无关），用来把
///   同一部番的不同集归到一张卡上。
library;

import 'package:path/path.dart' as p;

import 'episode_group.dart' show stripEpisodeMarker;
import 'series_search.dart' show kNoiseToken;
import 'title_match.dart' show normalizeTitleForMatch;

/// 认得出来的媒体 / 字幕 / 音频 / 图片扩展名（小写，不含点）。
const Set<String> _kMediaExts = <String>{
  // 视频
  'mkv', 'mp4', 'avi', 'rmvb', 'rm', 'mov', 'wmv', 'flv', 'ts', 'm2ts', 'webm',
  'mpg', 'mpeg', 'm4v', 'iso', '3gp',
  // 字幕
  'srt', 'ass', 'ssa', 'sub', 'vtt', 'sup', 'idx',
  // 音频
  'flac', 'aac', 'mp3', 'opus', 'm4a', 'wav', 'ape',
  // 图片（种子里常见的封面 / 预览图）
  'jpg', 'jpeg', 'png', 'webp', 'bmp',
};

/// 成对括号分组：`[...]` / `【...】` / `(...)` / `（...）`。
///
/// 字符类里排除了右括号本身，所以**嵌套**要靠循环多跑几趟（`([Group] x)` 第一趟
/// 只能先去掉里层）。跑几趟有上限，不会因为不配对死循环。
final RegExp _bracketed = RegExp(r'[\[【(（][^\[\]【】()（）]*[\]】)）]');

/// 尾部语言/字幕标记：`.CHS`、`.BIG5`、` 简体` 这类。
///
/// 只认**整段就是标记**的尾巴（前后有分隔符或字符串末端），不会把 `… Season 3` 里
/// 的字母吃掉。
const Set<String> _kTailTags = <String>{
  'chs', 'cht', 'chi', 'big5', 'gb', 'jpsc', 'jptc', 'jp', 'sc', 'tc', 'eng',
  'jpn', '简', '繁', '简繁', '简体', '繁体', '双语', '中日', '中日英', '中英',
};

/// 尾部标记匹配：可选分隔符 + 标记 + 字符串结束。
final RegExp _tailTag = RegExp(
  r'[\s._\-–—+]*(' + _kTailTags.map(RegExp.escape).join('|') + r')$',
  caseSensitive: false,
);

/// 首尾要剃掉的分隔符（切掉括号/集号之后经常会剩下一小截）。
final RegExp _edgeJunk = RegExp(r'^[\s._\-–—·,，、/\\|+~]+|[\s._\-–—·,，、/\\|+~]+$');

/// 第 1 步：去掉媒体扩展名（白名单命中才去；`Re Zero 2.0` 这种原样留着）。
String _stripMediaExtension(String name) {
  final int dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return name;
  final String ext = name.substring(dot + 1).toLowerCase();
  if (!_kMediaExts.contains(ext)) return name;
  return name.substring(0, dot);
}

/// 第 2 步：去掉所有成对括号分组（多跑两趟处理嵌套；不配对的不动）。
String _stripBrackets(String name) {
  String out = name;
  for (int i = 0; i < 3; i++) {
    final String next = out.replaceAll(_bracketed, ' ');
    if (next == out) break;
    out = next;
  }
  return out;
}

/// 第 3 步：反复剃掉尾部的语言标记（`x.CHS.CHT` 这种能连着来）。
String _stripTailTags(String name) {
  String out = name;
  for (int i = 0; i < 4; i++) {
    final RegExpMatch? m = _tailTag.firstMatch(out);
    if (m == null || m.start == 0) break;
    out = out.substring(0, m.start);
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// 兜底：番名自己也在括号里（`【字幕组】[番名][02][1080p]…`）
// ─────────────────────────────────────────────────────────────────────────────

/// 成对括号里的**内容**（保序）。嵌套时只拿到最里层那一段 —— 兜底用不着更聪明。
List<String> _bracketContents(String name) {
  final List<String> out = <String>[];
  for (final RegExpMatch m in _bracketed.allMatches(name)) {
    final String inner = name.substring(m.start + 1, m.end - 1).trim();
    if (inner.isNotEmpty) out.add(inner);
  }
  return out;
}

/// 字幕组名/压制标记里最常见的词 —— 出现在候选里就**不当番名**。
///
/// 为什么需要它：`[VCB-Studio]`、`[Skymoon-Raws]`、`[SubsPlease]` 这类只有一个
/// 拉丁词，靠"必须含中日文或至少两个词"就能挡住，但 `[NEST Group]` 这种两个词的
/// 也确实是组名。真正的番名混进这些词的概率极低，而**误挑一个组名去搜的代价**
/// （搜出一部不相干的番、还给整张卡配错封面）比"挑不出来就不搜"大得多。
const Set<String> _kGroupish = <String>{
  'raws', 'raw', 'sub', 'subs', 'fansub', 'fansubs', 'studio', 'group', 'team',
  'works', 'mux', 'encode', 'encoder', 'ripper', 'rip', 'anime', '字幕组',
  '压制组', '字幕', '压制', '汉化组', '搬运', '发布组',
};

/// 这一段括号内容"像不像番名"（兜底用，宁可漏也不误挑）。
///
/// 判据（顺序即优先级）：
/// 1. 至少 2 个码点、含至少一个"字"（`1080` / `02` / `--` 直接出局）；
/// 2. 去掉技术/语言标记（[kNoiseToken]：`1080P` / `AVC-8bit` / `WebRip` / `内嵌`…）
///    之后还得剩字 —— 整段都是标记的（`WebRip 1080P HEVC-10bit AAC`）不是名字；
/// 3. 不能**只**由 [_kGroupish] 里的词组成（`字幕组` 出局）；
/// 4. 不含中日文、却带组名词的（`VCB-Studio` / `Skymoon-Raws`）也不是名字；
/// 5. 最后：含中日韩文字，或者至少是**两个词**（`Re Zero kara Hajimeru Isekai Seikatsu`）。
///
/// 第 5 条为什么这么写：方括号里只有一个拉丁词的基本都是组名（`NEST` / `ANi` /
/// `x265` / `1080p`），而真番名要么是中日文，要么是多词。
bool _looksLikeTitle(String inner) {
  final String s = inner.replaceAll(_edgeJunk, '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.runes.length < 2 || !_hasWordChar.hasMatch(s)) return false;
  final List<String> words = _wordsOf(s.replaceAll(kNoiseToken, ' '));
  if (words.isEmpty) return false;
  if (words.every(_kGroupish.contains)) return false;
  if (!_kCjk.hasMatch(s) && words.any(_kGroupish.contains)) return false;
  if (_kCjk.hasMatch(s)) return true;
  return words.length >= 2;
}

/// 切成小写单词（字母/数字为界；`VCB-Studio` → `[vcb, studio]`）。
List<String> _wordsOf(String s) => s
    .toLowerCase()
    .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
    .where((String w) => w.isNotEmpty)
    .toList();

/// 中日韩文字（含假名）——兜底排序时，"有中日文的那一段"优先。
final RegExp _kCjk = RegExp(r'[\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]');

/// 从「番名自己也在括号里」的命名里挑出最像番名的那一段；挑不出来返回 null。
///
/// 排序（用户 2026-10-12 第十七轮选定：「删完什么都不剩时，从括号里挑最像番名的那一段」）：
/// 含中日文 > 不含；同为中日文（或同为多词拉丁）时**取字数最多的那一段** ——
/// 用户那条 `【今晚月色真美】[女友的朋友 / 彼女の友达 / Kanojo no Tomodachi]…`
/// 里，`女友的朋友 / 彼女の友达 / Kanojo no Tomodachi` 比字幕组名长得多，所以它胜出。
///
/// ⚠️ 残留歧义（登记在案）：`【A】【B】` 两个中日文候选、且组名比番名长时会挑错。
/// 这条兜底只在"一个字都没剩"时才走，挑错也只是卡片标题/搜索关键字不对，
/// 用户点开封面还能自己改（`completed_page.dart` 的换封面对话框）。
String? _titleFromBrackets(String name) {
  String? best;
  int bestScore = -1;
  for (final String inner in _bracketContents(name)) {
    if (!_looksLikeTitle(inner)) continue;
    final String candidate = inner
        .replaceAll(_edgeJunk, '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final int wordChars = _hasWordChar.allMatches(candidate).length;
    final int score = wordChars + (_kCjk.hasMatch(candidate) ? 1000 : 0);
    if (score > bestScore) {
      bestScore = score;
      best = candidate;
    }
  }
  return best;
}

/// 清洗出「番名」：去扩展名 → 去括号分组 → 去尾部语言标记 → 折叠空白。
///
/// 返回 null = 清洗之后什么都不剩（例如 `[VCB-Studio][x265].mp4`）——
/// 调用方**不要**拿原始名字去搜，那等于明知是垃圾还去问站点。
///
/// **例外（2026-10-12 第十七轮）**：有些中文命名把**番名自己也放在方括号里**：
/// `【今晚月色真美】[女友的朋友 / 彼女の友达 / Kanojo no Tomodachi][02][WebRip]…`
/// （`【】` 是字幕组，`[]` 里才是番名）。老规则把成对括号**一律删掉**，于是一个字
/// 都不剩 → 卡片拿整条原始文件名去搜 bangumi → 什么都搜不到。这种情况走
/// [_titleFromBrackets] 兜底：从括号里挑**最像番名**的那一段。
String? cleanAnimeNameFromFileName(String? raw) {
  if (raw == null) return null;
  String s = raw.trim();
  if (s.isEmpty) return null;

  // 传进来的可能是带目录的路径：先取文件名（Windows 的 `\` 与 URL 的 `/` 都认）。
  // ⚠️ 只有**看起来像路径**时才取 basename：种子里 `飙马野郎 JOJO / スティール…`
  // 这种名字中间就有一个斜杠，直接 basename 会把番名砍掉一半。
  if (s.contains('\\') || (s.contains('/') && !s.contains(' '))) {
    final String base = p.basename(s.replaceAll('\\', '/'));
    if (base.trim().isNotEmpty) s = base.trim();
  }

  s = _stripMediaExtension(s);
  // 括号还在的那一份：只有"删光括号后什么都不剩"时才会用到（见 [_titleFromBrackets]）。
  final String withBrackets = s;
  s = _stripBrackets(s);
  s = _stripTailTags(s);
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  s = s.replaceAll(_edgeJunk, '');
  if (!_hasWordChar.hasMatch(s)) s = _titleFromBrackets(withBrackets) ?? '';
  return s.isEmpty ? null : s;
}

/// 这些「名字」不是番名（清洗后整段就是标记/特典）：拿去搜只会搜出别的东西。
const Set<String> _kNotATitle = <String>{
  'sp', 'sps', 'ova', 'oad', 'ona', 'op', 'ed', 'pv', 'cm', 'nc', 'nced', 'ncop',
  'menu', 'preview', 'trailer', 'sample', 'bonus', 'special', 'cd', 'ost',
};

/// 「只搜名字」用的关键字：清洗 + 切掉集号。
///
/// null = 清洗后太短、只剩标记（`SP` / `OVA`）、或者压根没有「字」（纯数字/纯符号）——
/// `[Group] 01 [1080p].mp4` 清洗完只剩 `01`，拿它去搜只会搜出别的东西，
/// 宁可让 UI 显示「提取不出番名」。
///
/// 长度的判据是「至少 2 个码点 **且含至少一个字母/假名/汉字**」：
/// 不能要求 3 个 —— `冰菓` 这种两字番名是真名字；但 `01` 不是名字。
String? animeSearchName(String? raw) {
  final String? cleaned = cleanAnimeNameFromFileName(raw);
  if (cleaned == null) return null;
  // 集号在**清洗之后**切：`… 3rd Season [51][Ma10p…]` 里的集号已经被括号那步带走，
  // 而 `… - 03 [NF WEB-DL…]` 的 `- 03` 还留着，这里才切得到。
  // `minBareDigits: 2` —— 裸的单个数字是**季**（`K-ON! 2`）不是集，不能切。
  String name = stripEpisodeMarker(cleaned, minBareDigits: 2);
  name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
  name = name.replaceAll(_edgeJunk, '');
  if (name.runes.length < 2 || !_hasWordChar.hasMatch(name)) return null;
  if (_kNotATitle.contains(name.toLowerCase())) return null;
  return name;
}

/// 「有字的字符」：拉丁字母 / 汉字 / 日文假名 / 韩文。用来挡掉 `01`、`SP`、`--`。
final RegExp _hasWordChar = RegExp(
  r'[A-Za-z\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]',
);

/// 归组键：同一部番的不同集要落到同一个键上（大小写、标点、空白全不管）。
///
/// 拿不到名字时返回空串 —— 调用方据此把这一条单独放一张卡，而不是塞进别人的卡里。
String animeGroupKey(String? raw) {
  final String? name = animeSearchName(raw) ?? cleanAnimeNameFromFileName(raw);
  return normalizeTitleForMatch(name);
}
