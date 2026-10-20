/// 拖入 `.torrent` 后的确认框：**先看清要下什么，再决定下不下、下哪些**。
///
/// 用户 2026-10-20：「拖入种子，则跳转到队列，并显示要下载的东西与内容参数，
/// 然后选择是否下载」+ 问答选定「弹窗体确认」「完整信息 + 可展开文件清单」
/// 「要勾选部分文件」。
///
/// 三件事刻意做成这样：
/// * **不在这个框里下任何东西**：解析全在本地（`domain/torrent_file.dart`），
///   用户点「开始下载」之前引擎完全不知道有这个种子；
/// * **默认只勾视频与字幕**：nfo / 图片 / 样片默认不下（用户要的是片子），
///   想全下就点「全选」；
/// * 返回的是**文件序号列表**（= 引擎 `onlyFiles` 的语义），空 = 用户取消了。
library;

import 'package:flutter/material.dart';

import '../domain/format.dart' show formatBytes;
import '../domain/torrent_file.dart';
import '../theme/tokens.dart';
import 'widgets/ds_cards.dart';

/// 确认框的返回值：null = 取消；否则 [onlyFiles]（null = 全部文件都下）。
typedef TorrentConfirmChoice = ({List<int>? onlyFiles});

/// 打开确认框（[sourceName] 是拖进来的文件名，用来对照种子里的名字）。
Future<TorrentConfirmChoice?> showTorrentConfirmDialog(
  BuildContext context, {
  required TorrentPreview preview,
  String? sourceName,
}) {
  return showDialog<TorrentConfirmChoice>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) => _TorrentConfirmDialog(
      preview: preview,
      sourceName: sourceName,
    ),
  );
}

const ValueKey<String> dsTorrentConfirmKey = ValueKey<String>('ds-torrent-confirm');
const ValueKey<String> dsTorrentExpandKey = ValueKey<String>('ds-torrent-expand');
const ValueKey<String> dsTorrentSelectAllKey = ValueKey<String>('ds-torrent-select-all');
const ValueKey<String> dsTorrentStartKey = ValueKey<String>('ds-torrent-start');

/// 某一条文件的勾选框 key（测试按序号点）。
ValueKey<String> dsTorrentFileKey(int index) => ValueKey<String>('ds-torrent-file-$index');

class _TorrentConfirmDialog extends StatefulWidget {
  const _TorrentConfirmDialog({required this.preview, this.sourceName});

  final TorrentPreview preview;
  final String? sourceName;

  @override
  State<_TorrentConfirmDialog> createState() => _TorrentConfirmDialogState();
}

class _TorrentConfirmDialogState extends State<_TorrentConfirmDialog> {
  late final Set<int> _selected = <int>{...widget.preview.defaultSelection};
  bool _expanded = false;

  /// 收起时先露几条（用户要的是"可展开"，不是"一上来刷一屏"）。
  static const int _collapsedRows = 3;

  /// 展开时最多列这么多行：几千个文件的合集种子（BD 全集）全画出来会卡住对话框，
  /// 列前 200 个 + 一行"还有 N 个"就够用户判断了（勾选仍然是按文件序号生效的）。
  static const int _maxExpandedRows = 200;

  TorrentPreview get _preview => widget.preview;

  void _toggle(int index, bool? on) {
    setState(() {
      if (on == true) {
        _selected.add(index);
      } else {
        _selected.remove(index);
      }
    });
  }

  void _selectAll() => setState(() => _selected.addAll(_preview.files.map((TorrentFileEntryView f) => f.index)));

  void _confirm() {
    final bool all = _selected.length >= _preview.files.length;
    Navigator.of(context).pop<TorrentConfirmChoice>((
      onlyFiles: all ? null : (_selected.toList()..sort()),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final List<TorrentFileEntryView> files = _preview.files;
    final int limit = _expanded ? _maxExpandedRows : _collapsedRows;
    final List<TorrentFileEntryView> shown = files.take(limit).toList(growable: false);
    final int hiddenFiles = files.length - shown.length;
    final int pickedBytes = _preview.bytesOf(_selected);

    return AlertDialog(
      key: dsTorrentConfirmKey,
      title: const Text('下载这个种子？'),
      // 内容整体可滚：文件一多（或测试/小窗口只有 600 高）时 Column 会直接溢出 ——
      // 真机上窗口 1100×680 也照样可能溢出，所以纵向滚动是必须的，不是"以防万一"。
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
            Text(
              _preview.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: t.text,
                fontSize: DsTypeScale.body,
                fontWeight: FontWeight.w600,
              ),
            ),
            if ((widget.sourceName ?? '').isNotEmpty &&
                widget.sourceName != '${_preview.name}.torrent')
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '来自：${widget.sourceName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
                ),
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                DsChip(label: formatBytes(_preview.totalBytes), icon: Icons.sd_storage_outlined),
                DsChip(label: '${files.length} 个文件', icon: Icons.description_outlined),
                if (_preview.videoCount > 0)
                  DsChip(label: '${_preview.videoCount} 个视频', icon: Icons.movie_outlined),
                DsChip(
                  label: '${_preview.trackers.length} 个 tracker',
                  icon: Icons.lan_outlined,
                ),
                DsChip(
                  label: '${_preview.infoHashHex.substring(0, 8)}…',
                  icon: Icons.fingerprint,
                  tooltip: _preview.infoHashHex,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '默认只勾视频与字幕（nfo / 图片 / 样片不下载）；不想下的取消勾选就行。',
              style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: t.sunken,
                borderRadius: BorderRadius.circular(t.radiusCard),
              ),
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (final TorrentFileEntryView file in shown)
                    InkWell(
                      key: dsTorrentFileKey(file.index),
                      onTap: () => _toggle(file.index, !_selected.contains(file.index)),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(6, 2, 10, 2),
                        child: Row(
                          children: <Widget>[
                            Checkbox(
                              value: _selected.contains(file.index),
                              onChanged: (bool? on) => _toggle(file.index, on),
                              visualDensity: VisualDensity.compact,
                            ),
                            Expanded(
                              child: Text(
                                file.path,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: t.text, fontSize: DsTypeScale.secondary),
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (file.kind == TorrentEntryKind.video)
                              const Padding(
                                padding: EdgeInsets.only(right: 6),
                                child: Icon(Icons.movie_outlined, size: 14),
                              )
                            else if (file.kind == TorrentEntryKind.subtitle)
                              const Padding(
                                padding: EdgeInsets.only(right: 6),
                                child: Icon(Icons.subtitles_outlined, size: 14),
                              ),
                            Text(
                              formatBytes(file.sizeBytes),
                              style: TextStyle(
                                color: t.text3,
                                fontSize: DsTypeScale.caption,
                                fontFeatures: DsTokens.tabular,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (_expanded && hiddenFiles > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '…还有 $hiddenFiles 个文件没列出来（这里只显示前 $_maxExpandedRows 个）',
                  style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
                ),
              ),
            if (files.length > _collapsedRows)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: dsTorrentExpandKey,
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(
                    _expanded ? '收起' : '展开全部 ${files.length} 个文件',
                    style: TextStyle(fontSize: DsTypeScale.caption),
                  ),
                ),
              ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                TextButton(
                  key: dsTorrentSelectAllKey,
                  onPressed: _selectAll,
                  child: Text('全选', style: TextStyle(fontSize: DsTypeScale.caption)),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '将下载 ${formatBytes(pickedBytes)} / 共 ${formatBytes(_preview.totalBytes)}'
                    '（已选 ${_selected.length}/${files.length} 个文件）',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: t.text2,
                      fontSize: DsTypeScale.caption,
                      fontFeatures: DsTokens.tabular,
                    ),
                  ),
                ),
              ],
            ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: dsTorrentStartKey,
          onPressed: _selected.isEmpty ? null : _confirm,
          child: const Text('开始下载'),
        ),
      ],
    );
  }
}
