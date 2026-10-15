/// 标题解析（spec §4.4，必须单测）。
///
/// 从发布标题里提取：集数提示、分辨率、字幕组、字幕语言、是否合集。
/// 这些字段进 `SourceItem.extra`，供 UI 展示 + 规则排序 + 预取下一集使用。
library;

/// 解析结果。
class TitleParseResult {
  const TitleParseResult({
    this.episodeHints = const <String>[],
    this.resolution,
    this.group,
    this.subtitleLang,
    this.subtitleType,
    this.subtitleLangMatches = const <String>[],
    this.isBatch = false,
  });

  /// 归一化集数提示：`01`、`S01E02`、`S02E11` 等。
  ///
  /// 有序：主集数在前（范围形态时第二个是结束集数）。
  final List<String> episodeHints;

  /// `720` / `1080` / `2160`（spec 冻结取值范围），无法识别为 null。
  final int? resolution;

  /// 前导 `[组名]`（`【组名】` 亦可）。
  final String? group;

  /// spec §4.4 冻结词表：
  /// `简` / `繁` / `简繁` / `CHS` / `CHT` / `GB` / `BIG5` / `内封` / `内嵌` / `外挂`。
  ///
  /// 语言标记与封装方式同时出现时（例如 `[简繁内封]`），本字段取**语言标记**
  /// （`简繁`），封装方式进 [subtitleType]；原文命中串全部保留在
  /// [subtitleLangMatches] 里，UI 需要时可自行展示。
  final String? subtitleLang;

  /// `内封` / `内嵌` / `外挂`（同属 spec 词表，单独保留以免丢信息）。
  final String? subtitleType;

  /// 原文里命中的全部字幕相关标记（去重，按出现顺序）。
  final List<String> subtitleLangMatches;

  /// 合集/全集/整季（`合集`、`全集`、`Batch`、`01-12`、`Vol.`）。
  final bool isBatch;

  bool get hasEpisode => episodeHints.isNotEmpty;

  Map<String, dynamic> toExtra() => <String, dynamic>{
        'episodeHints': episodeHints,
        if (resolution != null) 'resolution': resolution,
        if (group != null) 'group': group,
        if (subtitleLang != null) 'subtitleLang': subtitleLang,
        if (subtitleType != null) 'subtitleType': subtitleType,
        if (subtitleLangMatches.isNotEmpty)
          'subtitleLangMatches': subtitleLangMatches,
        'isBatch': isBatch,
      };

  @override
  String toString() => 'TitleParseResult(hints=$episodeHints, '
      'resolution=$resolution, group=$group, lang=$subtitleLang, '
      'type=$subtitleType, isBatch=$isBatch)';
}

/// 标题解析器（纯函数，无状态）。
class TitleParser {
  const TitleParser._();

  /// 解析 [title]；[sourceId] 目前只用于将来做源特有规则，不影响通用结果。
  static TitleParseResult parse(String title, {String? sourceId}) {
    final t = title.trim();
    if (t.isEmpty) return const TitleParseResult();

    return TitleParseResult(
      episodeHints: extractEpisodeHints(t),
      resolution: extractResolution(t),
      group: extractGroup(t),
      subtitleLang: _subtitleLang(t).lang,
      subtitleType: _subtitleLang(t).type,
      subtitleLangMatches: _subtitleLang(t).matches,
      isBatch: detectBatch(t),
    );
  }

  /// 集数提示。按「季集标记 → 中文话数 → EP/E → 方括号数字 → `- 01`」优先级，
  /// 取**第一个命中的层级**，避免把 `1080p`、`x265`、`U-17` 之类误当集数。
  static List<String> extractEpisodeHints(String title) {
    final out = <String>[];

    // 1) S01E02 / S1E2 / S02E08-E11 / S02E08~11
    final season = RegExp(
      r'S(\d{1,2})\s*E(?:P)?\s*(\d{1,3})(?:\s*[-~～]\s*E?(\d{1,3}))?',
      caseSensitive: false,
    ).firstMatch(title);
    if (season != null) {
      final s = season.group(1)!.padLeft(2, '0');
      out.add('S${s}E${season.group(2)!.padLeft(2, '0')}');
      final end = season.group(3);
      if (end != null) out.add('S${s}E${end.padLeft(2, '0')}');
      return out;
    }

    // 2) 第3话 / 第 03 集 / 第3話
    final cn = RegExp(r'第\s*(\d{1,4})\s*[话話集]').firstMatch(title);
    if (cn != null) {
      out.add(cn.group(1)!.padLeft(2, '0'));
      return out;
    }

    // 3) EP03 / Ep.03 / E03 / EP 3
    final ep = RegExp(
      r'(?:^|[\s\[\(【（])(?:EP|Ep|ep|E)\.?\s*(\d{1,3})(v\d+)?(?=$|[\s\]\)】）\[]|v\d)',
    ).firstMatch(title);
    if (ep != null) {
      out.add(_numericHint(ep.group(1)!));
      return out;
    }

    // 4) [03] / (03) / 【03】 / [03v2]
    final bracket = RegExp(r'[\[\(【（]\s*(\d{1,3})(v\d+)?\s*[\]\)】）]')
        .firstMatch(title);
    if (bracket != null) {
      out.add(_numericHint(bracket.group(1)!));
      return out;
    }

    // 5) ` - 01`（前面必须是空白/括号，保证 `U-17`、`F-272`、`Nix-Raws` 不中）
    final dash = RegExp(
      r'(?:^|[\s\]\)】）])\s*[-–—]\s*(\d{1,3})(v\d+)?(?=$|[\s\[\(【（\]\)】）]|v\d)',
    ).firstMatch(title);
    if (dash != null) {
      out.add(_numericHint(dash.group(1)!));
    }

    return out;
  }

  /// `03` / `3` / `03v2` → 一律归一化为两位 `03`（spec §4.4 的归一化要求）。
  static String _numericHint(String digits) {
    final n = int.tryParse(digits) ?? 0;
    return n.toString().padLeft(2, '0');
  }

  /// 分辨率：取标题里出现的**最高**一档，输出限定在 `720 / 1080 / 2160`。
  static int? extractResolution(String title) {
    final found = <int>[];
    void probe(RegExp re, int value) {
      if (re.hasMatch(title)) found.add(value);
    }

    probe(RegExp(r'2160\s*p', caseSensitive: false), 2160);
    probe(RegExp(r'(?<![0-9A-Za-z])4K(?![0-9A-Za-z])', caseSensitive: false), 2160);
    probe(RegExp(r'3840\s*[x×]\s*2160'), 2160);
    probe(RegExp(r'1080\s*p', caseSensitive: false), 1080);
    probe(RegExp(r'1920\s*[x×]\s*1080'), 1080);
    probe(RegExp(r'720\s*p', caseSensitive: false), 720);
    probe(RegExp(r'1280\s*[x×]\s*720'), 720);

    if (found.isEmpty) return null;
    return found.reduce((int a, int b) => a > b ? a : b);
  }

  /// 前导 `[组名]`。跳过 `[1080p]`、`[WEB-DL]`、`[x265]` 这类技术标记。
  static String? extractGroup(String title) {
    final re = RegExp(r'^\s*[\[【]\s*([^\[\]【】]{1,48}?)\s*[\]】]');
    var rest = title;
    for (var i = 0; i < 3; i++) {
      final m = re.firstMatch(rest);
      if (m == null) return null;
      final candidate = m.group(1)!.trim();
      if (candidate.isNotEmpty && !_isTechToken(candidate)) return candidate;
      rest = rest.substring(m.end);
    }
    return null;
  }

  static final RegExp _techTokenRe = RegExp(
    r'^(\d{3,4}\s*p|\d{3,4}x\d{3,4}|4k|8bit|10bit|12bit|hevc|avc|x265|x264|h\.?264|h\.?265|aac|flac|opus|mkv|mp4|web-?dl|web-?rip|bd(?:rip)?|tv|bluray|multi-?sub|sub|raw|repack|v\d+)$',
    caseSensitive: false,
  );

  static bool _isTechToken(String s) => _techTokenRe.hasMatch(s.trim());

  /// `合集` / `全集` / `Batch` / `01-12` / `Vol.`。
  ///
  /// 另外把「季集区间」（`S02E08-E11`、`E08~E11`）也算合集 —— spec 的 `01-12`
  /// 就是区间形态，多集打包不该被当成单集（预取会因此找不到「下一集」）。
  static bool detectBatch(String title) {
    if (RegExp(r'合集|全集|全\s*\d+\s*[话話集]', caseSensitive: false)
        .hasMatch(title)) {
      return true;
    }
    if (RegExp(r'(?<![0-9A-Za-z])batch(?![0-9A-Za-z])', caseSensitive: false)
        .hasMatch(title)) {
      return true;
    }
    if (RegExp(r'(?<![0-9A-Za-z])vol\.?\s*\d', caseSensitive: false)
        .hasMatch(title)) {
      return true;
    }
    // 季集区间：S02E08-E11 / S02E08~11
    final seasonRange = RegExp(
      r'[Ss](\d{1,2})\s*[Ee](\d{1,3})\s*[-~～]\s*[Ee]?(\d{1,3})(?![0-9])',
    ).firstMatch(title);
    if (seasonRange != null) {
      final start = int.tryParse(seasonRange.group(2)!);
      final end = int.tryParse(seasonRange.group(3)!);
      if (start != null && end != null && end > start) return true;
    }
    // 集数区间：`01-12`、`01~12`、`第01-12话`（排除日期/编号：两侧必须是 1..3 位且左<右）
    final range = RegExp(r'(?<![0-9A-Za-z])(\d{1,3})\s*[-~～]\s*(\d{1,3})(?![0-9A-Za-z])');
    for (final m in range.allMatches(title)) {
      final a = int.tryParse(m.group(1)!);
      final b = int.tryParse(m.group(2)!);
      if (a == null || b == null) continue;
      if (a >= 1 && b > a && b - a <= 200) return true;
    }
    return false;
  }

  /// 字幕语言/封装标记。
  static _SubtitleMarkers _subtitleLang(String title) {
    final matches = <String>[];
    void probe(RegExp re, String label) {
      if (re.hasMatch(title) && !matches.contains(label)) matches.add(label);
    }

    final hasSimplified = title.contains('简') || RegExp(r'(?<![0-9A-Za-z])chs(?![0-9A-Za-z])', caseSensitive: false).hasMatch(title);
    final hasTraditional = title.contains('繁') || RegExp(r'(?<![0-9A-Za-z])cht(?![0-9A-Za-z])', caseSensitive: false).hasMatch(title);
    final both = hasSimplified && hasTraditional;

    probe(RegExp(r'简繁|繁简|简日繁'), '简繁');
    probe(RegExp(r'(?<![0-9A-Za-z])(?:chs\s*[&+＋]\s*cht|cht\s*[&+＋]\s*chs)(?![0-9A-Za-z])', caseSensitive: false), 'CHS&CHT');
    probe(RegExp(r'(?<![0-9A-Za-z])chs(?![0-9A-Za-z])', caseSensitive: false), 'CHS');
    probe(RegExp(r'(?<![0-9A-Za-z])cht(?![0-9A-Za-z])', caseSensitive: false), 'CHT');
    probe(RegExp(r'(?<![0-9A-Za-z])big5(?![0-9A-Za-z])', caseSensitive: false), 'BIG5');
    probe(RegExp(r'(?<![0-9A-Za-z])gb(?![0-9A-Za-z])', caseSensitive: false), 'GB');
    probe(RegExp('简'), '简');
    probe(RegExp('繁'), '繁');

    String? lang;
    if (both) {
      lang = '简繁';
    } else if (matches.contains('CHS')) {
      lang = 'CHS';
    } else if (matches.contains('CHT')) {
      lang = 'CHT';
    } else if (matches.contains('BIG5')) {
      lang = 'BIG5';
    } else if (matches.contains('GB')) {
      lang = 'GB';
    } else if (matches.contains('简')) {
      lang = '简';
    } else if (matches.contains('繁')) {
      lang = '繁';
    }

    String? type;
    if (title.contains('内封')) {
      type = '内封';
    } else if (title.contains('内嵌')) {
      type = '内嵌';
    } else if (title.contains('外挂')) {
      type = '外挂';
    }

    return _SubtitleMarkers(lang: lang, type: type, matches: matches);
  }
}

class _SubtitleMarkers {
  const _SubtitleMarkers({this.lang, this.type, required this.matches});

  final String? lang;
  final String? type;
  final List<String> matches;
}
