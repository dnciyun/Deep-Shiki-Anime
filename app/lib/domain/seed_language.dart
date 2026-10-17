/// 种子块的「字幕语言过滤」（第四十八轮·补九）：这一行是简体还是繁体。
///
/// 用户原话（补九，紧跟补八的交付报告）：
/// > 「加入按钮，点一次只显示简体，再点一次只显示繁体，再点一次恢复」
///
/// 为什么按标题认：mikan / 动漫花园这些站的一行种子，字幕语言是**写在标题里**的 ——
/// `[简]` / `简体` / `简中` / `简日` / `GB` / `CHS`，`[繁]` / `繁体` / `繁中` / `BIG5` / `CHT`，
/// 以及两边都带的 `[简繁]` / `简繁内封` / `[GB_BIG5_JP]`。真标题作证
/// （`build/round48c/uw_titles_833.txt`、`sg_titles.txt`）：
/// 833 条里简体 263 / 繁体 282 / 简繁 177 / 没标 111。
///
/// 两条钉死的取舍：
/// * **没标语言的（生肉 / BDMV / 只写"双语"）在简 / 繁两档下都不显示** —— "只看简体"时
///   它不一定是简体，摆出来就是骗人；「全部」那一档当然照常显示；
/// * **两边都标的两种过滤都显示**（它确实两种都有）；单看「简繁」两个字不能算"另一种"。
library;

import 'models.dart' show SourceItemView;

/// 语言过滤的三档（界面那颗按钮按这个顺序循环：全部 → 简体 → 繁体 → 全部）。
enum SeedLanguage { all, simplified, traditional }

/// 点一下切到下一档。
SeedLanguage nextSeedLanguage(SeedLanguage current) => switch (current) {
  SeedLanguage.all => SeedLanguage.simplified,
  SeedLanguage.simplified => SeedLanguage.traditional,
  SeedLanguage.traditional => SeedLanguage.all,
};

/// 按钮上给人看的档名（`语言：全部` / `语言：简体` / `语言：繁体`）。
String seedLanguageLabel(SeedLanguage language) => switch (language) {
  SeedLanguage.all => '全部',
  SeedLanguage.simplified => '简体',
  SeedLanguage.traditional => '繁体',
};

/// 这条标题标了**简体**字幕吗。
bool seedTitleMarksSimplified(String title) =>
    _kSimplified.hasMatch(_halfWidth(title));

/// 这条标题标了**繁体**字幕吗。
bool seedTitleMarksTraditional(String title) =>
    _kTraditional.hasMatch(_halfWidth(title));

/// 这条标题在 [language] 这一档下要不要显示。
///
/// ⚠️ `unknown`（没标）只在 [SeedLanguage.all] 下显示，见文件头那条取舍。
bool seedTitleMatchesLanguage(String title, SeedLanguage language) =>
    switch (language) {
      SeedLanguage.all => true,
      SeedLanguage.simplified => seedTitleMarksSimplified(title),
      SeedLanguage.traditional => seedTitleMarksTraditional(title),
    };

/// 这一条种子在 [language] 这一档下要不要显示。
bool seedItemMatchesLanguage(SourceItemView item, SeedLanguage language) =>
    seedTitleMatchesLanguage(item.title ?? '', language);

/// 按语言过滤一池子条目（**顺序不变**，不合并、不重排）。
List<SourceItemView> filterSeedItemsByLanguage(
  Iterable<SourceItemView> items,
  SeedLanguage language,
) => language == SeedLanguage.all
    ? List<SourceItemView>.of(items)
    : <SourceItemView>[
        for (final SourceItemView item in items)
          if (seedItemMatchesLanguage(item, language)) item,
      ];

// ─────────────────────────────────────────────────────────────────────────────
// 词表（一条一条都有真实标题作证，见文件头与 `app/test/seed_language_test.dart`）
// ─────────────────────────────────────────────────────────────────────────────

/// 简体标记。
///
/// * 成对写法：`简体` / `簡體` / `简中` / `简日`，以及两边都带的 `简繁` / `繁简`；
/// * 英文标签：`GB`（国标）/ `CHS`（Simplified Chinese）—— 两侧不许挨着字母数字，
///   免得把 `1080GB` 这种尺寸、`GBK` 这种编码当成语言；
/// * 单独一个 `简`：只认"后面就是空白/右括号/分隔符"的（`【F宅】… 简 BD版`），
///   中文名里的「简」不会撞（后面跟着汉字）。
final RegExp _kSimplified = RegExp(
  r'简体|簡體|简中|簡中|简日|簡日|简繁|簡繁|繁简|繁簡'
  r'|(?<![A-Za-z0-9])(?:gb|chs)(?![A-Za-z0-9])'
  r'|(?<![简繁體体])简(?=$|[\s\]】\)、,，/])',
  caseSensitive: false,
);

/// 繁体标记（与简体那份对称；`简繁` / `繁简` 两边都算）。
final RegExp _kTraditional = RegExp(
  r'繁体|繁體|繁中|繁日|简繁|簡繁|繁简|繁簡'
  r'|(?<![A-Za-z0-9])(?:big5|cht)(?![A-Za-z0-9])'
  r'|(?<![简繁體体])繁(?=$|[\s\]】\)、,，/])',
  caseSensitive: false,
);

/// 全角 → 半角（ASCII 段 + 全角空格）。
///
/// ⚠️ 与 `library_seed.dart` / `seed_version.dart` 里那两份是同一件事的副本 ——
/// 刻意重复：那两处各自服务"标题归一化"与"版本签名"，这里只要统一书写宽度；
/// 抽成公共工具会把三个领域的意图绑在一起。
String _halfWidth(String text) {
  final StringBuffer out = StringBuffer();
  for (final int rune in text.runes) {
    if (rune == 0x3000) {
      out.write(' ');
    } else if (rune >= 0xFF01 && rune <= 0xFF5E) {
      out.writeCharCode(rune - 0xFEE0);
    } else {
      out.writeCharCode(rune);
    }
  }
  return out.toString();
}
