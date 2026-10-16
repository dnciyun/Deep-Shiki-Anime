/// 搜索历史条（第三十三轮）：一行"最近搜过"的胶囊 + 每条一个 ×，右边一个「清空」。
///
/// 两处用同一份实现、各自一份数据（`SearchHistoryScope.torrents` / `.library`）：
/// 搜索页与动漫库的"最近搜过什么"不是一回事，用户明确要「动漫库的独立计算」。
///
/// 交互：
/// * 点某一条 = **填进输入框并立刻搜**（与用户手打一次回车等价）；
/// * 每条右上/右侧一个 × = 删这一条（不弹确认 —— 单条删除本身可逆性够高，重打一次就有）；
/// * 「清空」= 清空这一份（这一步**弹确认**：它一次抹掉 20 条）。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

class SearchHistoryBar extends StatelessWidget {
  const SearchHistoryBar({
    super.key,
    required this.history,
    required this.onPick,
    required this.onForget,
    required this.onClear,
    this.keyPrefix = 'search-history',
    this.showLabel = true,
  });

  final List<String> history;
  final ValueChanged<String> onPick;
  final ValueChanged<String> onForget;
  final VoidCallback onClear;

  /// 每组控件的 key 前缀（两个页面同时挂在 `IndexedStack` 里，key 必须区分）。
  final String keyPrefix;

  /// 要不要自带那半截「最近搜索」标签。
  ///
  /// 第四十四轮加：动漫库把搜索与筛选搬进**右栏**（248 宽），条里的标签 + 「清空」
  /// 会把胶囊挤成"每行一颗" —— 那儿由右栏自己出一行小标题（`_railLabel`），
  /// 于是这里只留胶囊与清空。搜索页是通栏的，照旧用默认的 `true`。
  final bool showLabel;

  Future<void> _confirmClear(BuildContext context) async {
    final bool ok = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('清空搜索历史'),
            content: Text('会删掉这 ${history.length} 条搜索历史，不能撤销。'),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                key: Key('$keyPrefix-clear-confirm'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('清空'),
              ),
            ],
          ),
        ) ??
        false;
    if (ok) onClear();
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return Row(
      key: Key('$keyPrefix-bar'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (showLabel)
          Padding(
            padding: const EdgeInsets.only(top: 3, right: 8),
            child: Text(
              '最近搜索',
              style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
            ),
          ),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              for (final String word in history)
                _HistoryChip(
                  key: Key('$keyPrefix-chip-$word'),
                  keyPrefix: keyPrefix,
                  word: word,
                  onPick: () => onPick(word),
                  onForget: () => onForget(word),
                ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        TextButton(
          key: Key('$keyPrefix-clear'),
          onPressed: history.isEmpty ? null : () => _confirmClear(context),
          child: const Text('清空'),
        ),
      ],
    );
  }
}

/// 一颗历史胶囊：主体可点（填入并搜），右侧小 × 删这一条。
class _HistoryChip extends StatelessWidget {
  const _HistoryChip({
    super.key,
    required this.keyPrefix,
    required this.word,
    required this.onPick,
    required this.onForget,
  });

  /// 与外面那一组控件同前缀（两个页面同时挂在 `IndexedStack` 里，key 必须区分）。
  final String keyPrefix;

  final String word;
  final VoidCallback onPick;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.sunken,
        borderRadius: BorderRadius.circular(t.radiusPill),
        border: Border.all(color: t.line, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onPick,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(9, 4, 4, 4),
                child: Text(
                  word,
                  style: TextStyle(color: t.text2, fontSize: DsTypeScale.caption),
                ),
              ),
            ),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: Key('$keyPrefix-forget-$word'),
              behavior: HitTestBehavior.opaque,
              onTap: onForget,
              child: Tooltip(
                message: '删掉这条历史',
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(2, 4, 7, 4),
                  child: Icon(Icons.close, size: 11, color: t.text3),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
