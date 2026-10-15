/// 链接识别（spec §7.3 Q19①）：粘贴 mikan 番剧页/单集页/RSS 或任意 RSS/Atom 链接，
/// 自动判断该建什么订阅。
///
/// ⚠️ **当前没有任何 UI 调用它**（第二十七轮：「订阅」页整页删掉、订阅改成在字幕组旁边
/// 点一下）。它连同 `widget_test.dart` 的用例一起**刻意留着**：这是"将来要加回
/// 『任意 RSS 订阅』入口时该走的那条路"（`parseSubscriptionLink` → `SubscriptionDraft`
/// → `SubsPort.upsert`）。接手的人如果要加那个入口，从这里接，不要再写一套识别。
///
/// 纯函数、可单测；不联网、不猜内容。
library;

import 'package:flutter/foundation.dart';

/// 识别出的订阅草稿。
@immutable
class SubscriptionDraft {
  /// 'mikan' | 'nyaa' | 'rss'。
  final String sourceKind;

  /// 订阅要抓的地址（RSS/Atom；mikan 番剧页会转成它的 RSS 地址）。
  final String feedUrl;

  /// 建议名称。
  final String name;

  /// 备注：给用户看的说明（例如「已把番剧页转成 RSS 地址」）。
  final String note;

  const SubscriptionDraft({
    required this.sourceKind,
    required this.feedUrl,
    required this.name,
    this.note = '',
  });
}

final RegExp _mikanBangumi = RegExp(r'mikanani\.me/Home/Bangumi/(\d+)', caseSensitive: false);
final RegExp _mikanEpisode = RegExp(r'mikanani\.me/Home/Episode/([A-Za-z0-9]+)', caseSensitive: false);
final RegExp _nyaaView = RegExp(r'nyaa\.si/(?:view|download)/(\d+)', caseSensitive: false);

/// 从用户粘贴的一串文本里识别出订阅草稿；识别不了返回 null。
///
/// 支持：
/// * `https://mikanani.me/Home/Bangumi/4094` → mikan 番剧 RSS（`/RSS/Bangumi?bangumiId=4094`）；
/// * `https://mikanani.me/Home/Episode/<hash>` → 该集的番剧 RSS 无法从单集页推出，
///   所以给「mikan 搜索」兜底地址并说明原因（**不假装知道番剧**）；
/// * `https://mikanani.me/RSS/Classic` / `/RSS/Search?searchstr=…` → mikan RSS；
/// * `https://nyaa.si/?page=rss…` → nyaa；
/// * 其它 http(s) 链接 → 通用 RSS。
SubscriptionDraft? parseSubscriptionLink(String input) {
  final String text = input.trim();
  if (text.isEmpty) return null;
  final RegExpMatch? url = RegExp(r'https?://[^\s]+').firstMatch(text);
  final String raw = url?.group(0) ?? text;
  final Uri? uri = Uri.tryParse(raw);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  final String host = uri.host.toLowerCase();

  if (host.endsWith('mikanani.me')) {
    final RegExpMatch? bangumi = _mikanBangumi.firstMatch(raw);
    if (bangumi != null) {
      final String id = bangumi.group(1)!;
      return SubscriptionDraft(
        sourceKind: 'mikan',
        feedUrl: 'https://mikanani.me/RSS/Bangumi?bangumiId=$id',
        name: 'mikan 番剧 $id',
        note: '已把番剧页（/Home/Bangumi/$id）转成 mikan 的番剧 RSS 地址。',
      );
    }
    if (_mikanEpisode.hasMatch(raw)) {
      return SubscriptionDraft(
        sourceKind: 'mikan',
        feedUrl: 'https://mikanani.me/RSS/Classic',
        name: 'mikan 最新',
        note: '这是「单集页」，页面里没有番剧 id，无法直接推出该番的订阅；'
            '先订阅 mikan 最新，再在订阅里用关键字规则过滤这一部。',
      );
    }
    return SubscriptionDraft(
      sourceKind: 'mikan',
      feedUrl: raw,
      name: 'mikan 订阅',
      note: '按你给的 mikan RSS 地址订阅。',
    );
  }

  if (host.endsWith('nyaa.si') || host.endsWith('sukebei.nyaa.si')) {
    if (_nyaaView.hasMatch(raw)) {
      return const SubscriptionDraft(
        sourceKind: 'nyaa',
        feedUrl: 'https://nyaa.si/?page=rss&c=1_2',
        name: 'nyaa 动漫区',
        note: 'nyaa 的详情页/下载页不能当订阅源；这里改成 nyaa 动漫区 RSS，'
            '再用关键字规则过滤这一部。',
      );
    }
    return SubscriptionDraft(
      sourceKind: 'nyaa',
      feedUrl: raw.contains('page=rss') ? raw : 'https://nyaa.si/?page=rss&c=1_2',
      name: 'nyaa 订阅',
      note: '按你给的 nyaa 地址订阅。',
    );
  }

  return SubscriptionDraft(
    sourceKind: 'rss',
    feedUrl: raw,
    name: uri.host,
    note: '当作通用 RSS / Atom 订阅抓取。',
  );
}
