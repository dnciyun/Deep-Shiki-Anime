/// 标识色相 → 语义的映射（第五十二轮「整个项目太素」引入，第五十三轮只作标识）。
///
/// 第五十三轮用户原话「默认还是按主题的色不要加其他颜色」之后，`theme/tokens.dart`
/// 的 `hue*` API 已经一律落回本套外观的主题强调色 —— 这个文件不再决定**颜色**，
/// 只保留「什么内容算哪个身份」的语义表（页面 / 源 / 标签 / 星期）。
///
/// 为什么保留：① 调用点不用改（第五十二轮的结构色条 / 色块 / 洗色全部还在，只是同色）；
/// ② 万一以后要恢复彩色标识，只改 `tokens.dart` 的取色实现，映射表不动。
///
/// 用法（页面侧）：
/// ```dart
/// final DsHue hue = hueOfTab(ShellTab.queue);
/// NeoSectionHeader(title: '队列', hue: hue);
/// DsChip(label: item.sourceLabel, hue: hueOfSource(item.sourceId));
/// ```
library;

import '../../state/providers.dart' show ShellTab;
import '../../theme/tokens.dart';

/// 每个导航目的地一个色相（侧栏图标、页面标题、内容区顶部洗色都用它）。
///
/// 排序刻意让相邻 tab 不同色：主页橙 / 动漫库紫 / 搜索青 / 追番粉 / 队列蓝 /
/// 已完成绿 / 本地青绿（2026-10-20 插在「已完成」后面：下完的和自己盘上的相邻，
/// 但用不同色相区分两套数据源）/ 扩展玫红（1.1.0 M3/T15：挑一个既不撞上面的绿、
/// 也不撞左下角「观看记录」金的色相；紫色系留给「动漫库」，不抢）/
/// 画面调节靛 / 音效琥珀（2026-10-20：两个"包页面"，此前没有 tab 用这两个色相，
/// 所以 12 个目的地仍是 12 个互不相同的标识）/ 观看记录金 / 设置灰。
DsHue hueOfTab(ShellTab tab) => switch (tab) {
      ShellTab.home => DsHue.orange,
      ShellTab.library => DsHue.violet,
      ShellTab.search => DsHue.cyan,
      ShellTab.following => DsHue.pink,
      ShellTab.queue => DsHue.blue,
      ShellTab.completed => DsHue.emerald,
      // 「本地」（2026-10-20）：青绿。与「已完成」的绿不同族（那是引擎下完的），
      // 也不撞「搜索」的青与「扩展」的玫红。
      ShellTab.local => DsHue.teal,
      ShellTab.extensions => DsHue.rose,
      ShellTab.picture => DsHue.indigo,
      ShellTab.audioFx => DsHue.amber,
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
