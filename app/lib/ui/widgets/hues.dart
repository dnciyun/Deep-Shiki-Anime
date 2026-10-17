/// 标识色相 → 语义的映射（第五十二轮：用户 2026-10-17「整个项目太素」）。
///
/// 颜色本身在 `theme/tokens.dart` 的 [DsHue]（唯一允许写 `Color(0x…)` 的地方）；
/// 这个文件只放「什么内容用哪个色相」的**语义表**，不含任何颜色字面量。
///
/// 用法（页面侧）：
/// ```dart
/// final DsHue hue = hueOfTab(ShellTab.queue);
/// NeoSectionHeader(title: '队列', hue: hue);
/// DsChip(label: item.sourceLabel, hue: hueOfSource(item.sourceId));
/// ```
///
/// 规则：**颜色是信息**，不是装饰 —— 同一个色相在侧栏、页头、区块头、徽标里指同一个
/// 东西（页面 / 源 / 标签）；不要给随机的地方挑随机色。
library;

import '../../state/providers.dart' show ShellTab;
import '../../theme/tokens.dart';

/// 每个导航目的地一个色相（侧栏图标、页面标题、内容区顶部洗色都用它）。
///
/// 排序刻意让相邻 tab 不同色：主页橙 / 动漫库紫 / 搜索青 / 追番粉 / 队列蓝 /
/// 已完成绿 / 观看记录金 / 设置灰。
DsHue hueOfTab(ShellTab tab) => switch (tab) {
      ShellTab.home => DsHue.orange,
      ShellTab.library => DsHue.violet,
      ShellTab.search => DsHue.cyan,
      ShellTab.following => DsHue.pink,
      ShellTab.queue => DsHue.blue,
      ShellTab.completed => DsHue.emerald,
      ShellTab.history => DsHue.gold,
      ShellTab.settings => DsHue.slate,
    };

/// 种子源 id → 色相（搜索页分区头、种子块、来源徽标）。
///
/// 按前缀匹配：`dmhy` 与 `dmhy-batch` 同色（同一个站的两个分区），
/// `acgnx` 与 `acgnx-batch` 同理。
DsHue hueOfSource(String? sourceId) {
  final String id = (sourceId ?? '').toLowerCase();
  if (id.startsWith('mikan')) return DsHue.orange;
  if (id.startsWith('dmhy')) return DsHue.blue;
  if (id.startsWith('nyaa')) return DsHue.violet;
  if (id.startsWith('acgnx')) return DsHue.rose;
  if (id.startsWith('acgrip')) return DsHue.indigo;
  if (id.startsWith('bangumi')) return DsHue.pink;
  if (id.startsWith('rss')) return DsHue.teal;
  return DsHue.slate;
}

/// 番剧标签 → 色相（动漫库右栏类型胶囊、详情页标签）。
///
/// 按"族"分色，不逐个随机：奇幻/魔法/异世界一族的紫、恋爱一族的粉、
/// 战斗/热血一族的玫红、日常/搞笑一族的琥珀…… 同一屏里相邻标签因此不撞色。
/// 没收录的标签用稳定哈希落进 12 色，保证同一条目每次渲染同色。
DsHue hueOfTag(String tag) {
  final DsHue? fixed = _tagHues[tag];
  if (fixed != null) return fixed;
  final int code = tag.codeUnits.fold<int>(17, (int a, int b) => (a * 31 + b) & 0x7fffffff);
  return DsHue.values[code % DsHue.values.length];
}

/// 星期 → 色相（主页「今日更新」的周一到周日）。索引 0 = 周一。
///
/// 一周走一圈色环：蓝 → 青 → 水绿 → 绿 → 金 → 橙 → 粉。当天那格用实色，
/// 其余用淡底，扫一眼就知道"今天"在哪。
DsHue hueOfWeekday(int index) {
  const List<DsHue> ring = <DsHue>[
    DsHue.blue,
    DsHue.cyan,
    DsHue.teal,
    DsHue.emerald,
    DsHue.gold,
    DsHue.orange,
    DsHue.pink,
  ];
  return ring[index % ring.length];
}

/// 常用标签的固定色相表（未收录的走 [hueOfTag] 的哈希兜底）。
const Map<String, DsHue> _tagHues = <String, DsHue>{
  // 幻想族：紫 / 靛
  '奇幻': DsHue.violet,
  '魔法': DsHue.violet,
  '异世界': DsHue.indigo,
  '超能力': DsHue.indigo,
  '科幻': DsHue.cyan,
  // 战斗族：玫红 / 蓝
  '战斗': DsHue.rose,
  '热血': DsHue.rose,
  '机战': DsHue.blue,
  '战争': DsHue.slate,
  '冒险': DsHue.teal,
  // 恋爱族：粉
  '恋爱': DsHue.pink,
  '后宫': DsHue.pink,
  '百合': DsHue.rose,
  '女性向': DsHue.rose,
  '青春': DsHue.pink,
  // 日常族：琥珀 / 金
  '日常': DsHue.amber,
  '搞笑': DsHue.amber,
  '治愈': DsHue.emerald,
  '催泪': DsHue.teal,
  '泡面番': DsHue.gold,
  '子供向': DsHue.teal,
  // 校园 / 音乐 / 偶像
  '校园': DsHue.pink,
  '音乐': DsHue.teal,
  '偶像': DsHue.pink,
  // 悬疑族：石板灰 / 玫红
  '悬疑': DsHue.slate,
  '推理': DsHue.slate,
  '恐怖': DsHue.rose,
  '猎奇': DsHue.rose,
  // 运动 / 竞技
  '运动': DsHue.emerald,
  '竞技': DsHue.blue,
  // 历史 / 武侠
  '历史': DsHue.gold,
  '武侠': DsHue.gold,
  // 放送形态
  'TV': DsHue.cyan,
  '剧场版': DsHue.violet,
  'OVA': DsHue.indigo,
};
