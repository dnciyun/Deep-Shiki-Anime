/// Bangumi 元数据匹配（spec §7.8，含两次实测踩坑）。
///
/// **必须做校验，宁缺毋滥**：实测过两次张冠李戴 ——
/// 1. 搜「蓝箱」第一条返回的是**短片**（`name_cn` 相关但话数极少），直接取首条就错了；
/// 2. 猜一个 id 查 `417545` 得到 `Ultimate Force Season 4`（**完全不相干**的另一部剧），
///    而它的 `name_cn` 是个正常中文名 —— 说明「有没有拿到数据」完全不足以判断对不对。
///
/// 规则：**归一化名字比对（含季/剧场版这类装饰后缀）+ 类型/话数/年份校验 + 置信度阈值**，
/// 达不到阈值就返回 null（UI 显示「未匹配到 Bangumi」，不显示错封面）。
library;

import 'bangumi.dart';
import 'title_match.dart';

/// 匹配置信度（0–1）。
enum BangumiMatchConfidence {
  /// 名字完全一致（归一化后）。
  exact(1.0),

  /// 一方包含另一方，且只差「季/剧场版」这类装饰后缀。
  contained(0.75);

  const BangumiMatchConfidence(this.score);
  final double score;
}

/// 匹配结果。
class BangumiMatch {
  const BangumiMatch(this.subject, this.confidence);

  final BangumiSubject subject;
  final BangumiMatchConfidence confidence;
}

/// 最低要求：只接受 `exact` 与 `contained`（都带额外校验），其余一律 null。
const double bangumiMinConfidence = 0.75;

/// 名字上的「装饰后缀」：季/期/剧场版/OVA… 这类可以忽略的差别。
final RegExp _decoration = RegExp(
  r'^(?:第[一二三四五六七八九十\d]+[季期部]|season\s*\d+|s\d+|part\s*\d+|cour\s*\d+|'
  r'ova|oad|movie|special|sp|剧场版|最终季|完结篇|新篇|续篇|篇|续|前篇|后篇)+$',
  caseSensitive: false,
);

/// [a] 包含 [b]，**且多出来的那部分只是装饰**（季/剧场版…）。
///
/// 这一条挡掉两类误配：
/// * 候选名更长但是**另一部作品**（「葬送的芙莉莲 迷你动画」≠「葬送的芙莉莲」）；
/// * 查询名更长但是另一部（找「XX 迷你动画」不能返回正片）。
bool containsAllowingDecoration(String a, String b) {
  if (b.length < minMatchableTitleLength) return false;
  final int at = a.indexOf(b);
  if (at < 0) return false;
  final String rest = a.substring(0, at) + a.substring(at + b.length, a.length);
  if (rest.isEmpty) return true;
  return _decoration.hasMatch(rest);
}

/// 「像不像同一部番」的额外校验：
/// * 年份给了就要求相差 ≤1 年（档期跨年很常见，放宽到 1）；
/// * 话数给了就要求候选话数不显著更少（挡短片/预告）；
/// * 候选必须真是动画（`type == 2`，缺省视为未知不拦）。
bool plausibleSubject(BangumiSubject subject, {int? year, int? episodes}) {
  if (subject.type != null && subject.type != 2) return false;
  final int? subjectYear = subject.year;
  if (year != null && subjectYear != null && (subjectYear - year).abs() > 1) {
    return false;
  }
  final int? subjectEps = subject.eps;
  if (episodes != null && episodes > 1 && subjectEps != null) {
    // 短片/单集条目只有 1 话，不足以承载「一季 12 集」的番。
    if (subjectEps <= 1 && episodes > 2) return false;
    if (subjectEps * 3 < episodes) return false;
  }
  return true;
}

/// 两个命中谁更好：置信度高者优先；同级时年份更近者优先；再不行取 id 大的（新条目）。
bool _better(BangumiMatch a, BangumiMatch b, {int? year}) {
  if (a.confidence.score != b.confidence.score) {
    return a.confidence.score > b.confidence.score;
  }
  if (year != null) {
    final int da =
        (a.subject.year ?? 0) == 0 ? 999 : (a.subject.year! - year).abs();
    final int db =
        (b.subject.year ?? 0) == 0 ? 999 : (b.subject.year! - year).abs();
    if (da != db) return da < db;
  }
  return a.subject.id > b.subject.id;
}

/// 从候选里挑出**最可能对应** [title] 的那一条；不确定就返回 null。
///
/// [year] 是已知的放送年份（可选）：给了就用来卡「同一年左右」，
/// 能挡掉「同名但差十年」的翻拍/短片。
/// [episodes] 是已知话数（可选）：用来挡 1 话短片顶替 12 话正片。
BangumiMatch? bestBangumiMatch(
  String? title,
  Iterable<BangumiSubject> candidates, {
  int? year,
  int? episodes,
}) {
  final String needle = normalizeTitleForMatch(title);
  if (needle.length < minMatchableTitleLength) return null;

  BangumiMatch? best;
  for (final BangumiSubject s in candidates) {
    // 类型/年份/话数校验对**所有**命中都生效：同名但不同年代、非动画条目
    // 正是实测里最容易张冠李戴的地方。
    if (!plausibleSubject(s, year: year, episodes: episodes)) continue;

    final String cn = normalizeTitleForMatch(s.nameCn);
    final String jp = normalizeTitleForMatch(s.name);

    BangumiMatchConfidence? confidence;
    if (cn == needle || jp == needle) {
      confidence = BangumiMatchConfidence.exact;
    } else if (containsAllowingDecoration(cn, needle) ||
        containsAllowingDecoration(jp, needle) ||
        containsAllowingDecoration(needle, cn) ||
        containsAllowingDecoration(needle, jp)) {
      confidence = BangumiMatchConfidence.contained;
    }
    if (confidence == null) continue;

    final BangumiMatch candidate = BangumiMatch(s, confidence);
    if (best == null || _better(candidate, best, year: year)) best = candidate;
  }
  if (best == null || best.confidence.score < bangumiMinConfidence) return null;
  return best;
}
