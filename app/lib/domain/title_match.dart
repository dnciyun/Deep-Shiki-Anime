/// 番名归一化与匹配（纯函数，可单测）。
///
/// 两处用到，语义完全一致：
/// * 主页角标「已缓存」：判断引擎里已下完的 torrent 是否就是这部番（spec §7.5）；
/// * Bangumi 元数据匹配（spec §7.6）：拿到的中文名/原名能不能对上（**低置信度就不显示**）。
///
/// 这里是**保守匹配**：宁可不显示，也不要张冠李戴。
library;

/// 需要丢掉的字符：空白、中英文标点、括号、常见分隔符。
///
/// 用字符串 contains 而不是逐字符正则：标题很短，但主页一次要跑几十次，省掉正则开销。
const String _dropped = ' \t\r\n'
    '[]【】()（）<>《》{}「」'
    '-_—–·.,，。;；:：!！?？"\'’‘“”/\\|~+=*#'
    '&＆@';

/// 归一化番名：去掉标点/空白、全角转半角常见的几个、转小写。
///
/// 只做「能让两边对上」的最小处理：不删词、不猜别名、不做拼音。
String normalizeTitleForMatch(String? title) {
  if (title == null) return '';
  final StringBuffer out = StringBuffer();
  for (final int rune in title.toLowerCase().runes) {
    final String ch = String.fromCharCode(rune);
    if (_dropped.contains(ch)) continue;
    out.write(ch);
  }
  return out.toString();
}

/// 番名是否「像一个番名」：归一化后至少 3 个字符才允许参与包含匹配。
///
/// 太短的名字（`01`、`SP`、`OVA`）包含匹配几乎必然误命中。
const int minMatchableTitleLength = 3;

/// [haystack]（通常是 torrent 名 / Bangumi 条目的 name_cn）里是否**包含** [title]。
///
/// 只做单向包含：`haystack.contains(title)`。反向包含（番名包含 torrent 名）
/// 会把「葬送的芙莉莲」匹配到「葬送的芙莉莲 第二季」之外的任何东西，风险更高，不做。
bool titleContained(String? haystack, String? title) {
  final String needle = normalizeTitleForMatch(title);
  if (needle.length < minMatchableTitleLength) return false;
  final String hay = normalizeTitleForMatch(haystack);
  if (hay.isEmpty) return false;
  return hay.contains(needle);
}

/// 引擎里已下完的名字列表里，是否有哪一个就是这部番（spec §7.5「已缓存」角标）。
bool anyTitleContains(Iterable<String> haystacks, String? title) {
  final String needle = normalizeTitleForMatch(title);
  if (needle.length < minMatchableTitleLength) return false;
  for (final String haystack in haystacks) {
    if (normalizeTitleForMatch(haystack).contains(needle)) return true;
  }
  return false;
}

/// **双向**包含：两个名字任一方向包含即算同一部番。
///
/// 用在「正在追」页把追番记录对上三个数据源：
/// * mikan 追番表（`葬送的芙莉莲 第二季` vs 追番名 `葬送的芙莉莲`）；
/// * 引擎 torrent 名（`[ANi] 迷宫饭 - 01 [1080p]` vs `迷宫饭`）；
/// * 队列任务的条目标题。
///
/// 依然要求两边都 ≥ [minMatchableTitleLength] 个字，短名（`01`/`SP`/`OVA`）不参与。
bool titlesMatch(String? a, String? b) {
  final String na = normalizeTitleForMatch(a);
  final String nb = normalizeTitleForMatch(b);
  if (na.length < minMatchableTitleLength ||
      nb.length < minMatchableTitleLength) {
    return false;
  }
  return na.contains(nb) || nb.contains(na);
}
