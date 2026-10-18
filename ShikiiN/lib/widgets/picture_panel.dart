/// 「画面调节」滑杆面板（右键菜单 →「画面调节」→「调节…」）。
///
/// 为什么是浮层而不是设置页：调的时候必须看得见画面。面板只做三件事：
/// 显示当前包的参数（按 `group` 分组）、拖动时**只改本地草稿**、松手/停止拖动后
/// 才回写宿主（`setValue` + 防抖 `applyValues`）。
///
/// 防抖不是优化而是正确性问题：一次拖动会触发几十次 `onChanged`，而每次 apply
/// 都要"渲染一份 .glsl + 重挂 glsl-shaders"，逐帧做等于把播放器卡住。
///
/// **面板浮层不画遮罩色**（2026-10-18 用户：「打开滑杆面板时画面有层透明白色」）：
/// 旧实现铺的是 `tokens.base.withValues(alpha: 0.28)` —— 那是**面板底色**（浅色主题下
/// 接近白的面色），盖在视频上就是一层白蒙蒙。而且这个面板的全部用途就是**看着画面调**，
/// 任何压暗/提亮的遮罩都会让亮度、对比、饱和的判断失真（用户调完关掉面板发现不一样）。
/// 所以遮罩只做"点击关闭"的命中面，不画任何颜色。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/picture_menu.dart';
import '../models/theme_tokens.dart';

/// 面板右上角「重置」按钮的文案（界面与测试共用一份，避免文案漂移）。
const String kPictureResetLabel = '重置';

/// 「重置」按钮的说明（鼠标悬停）—— 用户要能一眼看出"重置到哪儿"。
const String kPictureResetHint = '恢复这个包的默认取值，并立即生效';

/// 面板标题的前缀（面板第一行字）。
const String kPicturePanelTitle = '画面调节';

/// 面板标题：默认就是「画面调节」；**只有装了多个画面调节包**时才补「· 包名」。
///
/// 用户 2026-10-18：「调节滑杆面板里名字为什么叫画面调节 清晰」——
/// 两个错叠在一起：面板标题原本是 `'画面调节 · ${menu.packName}'`，而那个包的
/// `name` 当初被写成「画面调节 · 清晰」（第一版菜单里整个包只算一项，名字里带前缀
/// 还说得过去），于是渲染成「画面调节 · 画面调节 · 清晰」；而「清晰」其实是**预设**
/// 的名字，包里还有柔和/线条/暖色/去雾/极五档。包名已改成「清晰增强」，但这里更彻底：
/// 面板是这个 app 的画面调节面板，不是某个包的页面 —— 单包时**不拼包名**，
/// 包名去扩展页看（那边有「设置」和说明）。多包时才拼，否则滑杆分不清是谁的。
///
/// 判据用预设 id 的包前缀（`<包 id>/<预设 id>`），不额外往契约上挂字段。
String picturePanelTitle(PictureMenu menu) {
  final Set<String> packIds = <String>{
    for (final PicturePresetInfo p in menu.presets)
      if (p.id.indexOf('/') > 0) p.id.substring(0, p.id.indexOf('/')),
  };
  if (packIds.length <= 1) return kPicturePanelTitle;
  final String name = menu.packName.trim();
  if (name.isEmpty) return kPicturePanelTitle;
  if (name.startsWith(kPicturePanelTitle)) return name;
  return '$kPicturePanelTitle · $name';
}

/// 面板浮层离播放面上边缘的距离（[PicturePanelLayer] 定位用，面板自己也算高度）。
const double kPicturePanelTop = 60;

/// 面板离右/下边缘的最小留白（窄/矮窗口时面板要跟着收，别顶出画面）。
const double kPicturePanelMargin = 24;

class PicturePanel extends StatefulWidget {
  const PicturePanel({
    super.key,
    required this.menu,
    required this.tokens,
    required this.onClose,
  });

  final PictureMenu menu;
  final ThemeTokens tokens;
  final VoidCallback onClose;

  @override
  State<PicturePanel> createState() => _PicturePanelState();
}

class _PicturePanelState extends State<PicturePanel> {
  late final Map<String, double> _draft = <String, double>{
    for (final PictureParamInfo p in widget.menu.params)
      p.key: widget.menu.valueOf(p.key),
  };
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// 拖动中：只改草稿（不碰 mpv）。
  void _onChanged(PictureParamInfo param, double value) {
    setState(() => _draft[param.key] = value);
  }

  /// 松手：写回宿主 + 防抖后重新渲染挂载。
  void _onChangeEnd(PictureParamInfo param, double value) {
    widget.menu.setValue(param.key, value);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () {
      unawaited(widget.menu.applyValues());
    });
  }

  /// 一键重置：全部参数回**包的默认值**，立刻渲染挂载（不等防抖）。
  ///
  /// 三个细节都是有原因的：
  /// * 先 `cancel` 防抖：否则刚拖完滑杆就点重置，220 ms 后那次 apply 会把
  ///   "重置前的取值"再挂一遍（这时 `_settings` 已经是默认值了，等于白发一次 set，
  ///   画面会闪一下）。
  /// * 逐项 `setValue` 而不是"只改草稿"：重置必须在**宿主状态**里生效 ——
  ///   只改草稿的话画面不变，用户以为按钮没反应。
  /// * 即使当前是「关」也照做：`setValue` 会顺手把包选起来（与拖滑杆同一语义），
  ///   于是"关着 → 点重置 → 立刻看到默认画面"，不用先随便拖一下去激活。
  void _resetToDefaults() {
    final List<PictureParamInfo> params = widget.menu.params;
    if (params.isEmpty) return;
    _debounce?.cancel();
    for (final PictureParamInfo p in params) {
      widget.menu.setValue(p.key, p.defaultValue);
    }
    setState(() {
      for (final PictureParamInfo p in params) {
        _draft[p.key] = p.defaultValue;
      }
    });
    unawaited(widget.menu.applyValues());
  }

  /// 标题行右侧的小按钮（重置 / 关闭同一档文字尺寸）。
  Widget _headerAction(ThemeTokens t, String label, VoidCallback onTap) => Tooltip(
        message: kPictureResetHint,
        waitDuration: const Duration(milliseconds: 500),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Text(
              label,
              style: TextStyle(color: t.text2, fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final ThemeTokens t = widget.tokens;
    // 按 group 保序分组（空 group 归到最后一块，标题不显示）。
    final List<String> groups = <String>[];
    final Map<String, List<PictureParamInfo>> byGroup = <String, List<PictureParamInfo>>{};
    for (final PictureParamInfo p in widget.menu.params) {
      final String key = p.group.isEmpty ? '' : p.group;
      if (!byGroup.containsKey(key)) {
        byGroup[key] = <PictureParamInfo>[];
        groups.add(key);
      }
      byGroup[key]!.add(p);
    }

    // 窄/矮窗口的自适应：PiP 只有 480×270、用户也可能把播放窗口拖得很小。
    // 面板固定 320 宽 + 9 个滑杆约 570 高，直接摆出去会顶出画面（Stack 会裁掉，
    // 底部那几组参数就再也拖不到）。这里让宽度和高度都跟着窗口收，超高改滚动。
    final Size screen = MediaQuery.sizeOf(context);
    final double maxWidth = (screen.width - kPicturePanelMargin * 2).clamp(220.0, 320.0);
    final double maxHeight =
        (screen.height - kPicturePanelTop - kPicturePanelMargin).clamp(160.0, 2000.0);

    return Material(
      color: Colors.transparent,
      child: Container(
        width: maxWidth,
        constraints: BoxConstraints(maxHeight: maxHeight),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        decoration: BoxDecoration(
          color: t.base,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: t.line),
          boxShadow: <BoxShadow>[
            // 颜色一律从 token 来（契约 §4：播放器不许自带颜色字面量）。
            BoxShadow(color: t.shadowDark, blurRadius: 18, offset: const Offset(0, 6)),
          ],
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      picturePanelTitle(widget.menu),
                      style: TextStyle(color: t.text, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                  // 「重置」（用户 2026-10-18：「滑杆那没有重置键」）：一键把全部参数
                  // 退回包的默认值并立即生效 —— 手调成一堆奇怪数字之后，没有这条路
                  // 就只能一项一项滑回去（或者干脆关掉重来）。
                  if (widget.menu.params.isNotEmpty)
                    _headerAction(t, kPictureResetLabel, _resetToDefaults),
                  const SizedBox(width: 10),
                  InkWell(
                    onTap: widget.onClose,
                    child: Icon(Icons.close_rounded, size: 18, color: t.text2),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                widget.menu.isOff ? '当前未启用（拖一下滑杆即生效）' : '拖动松手后生效',
                style: TextStyle(color: t.text3, fontSize: 11),
              ),
              for (final String group in groups) ...<Widget>[
                const SizedBox(height: 10),
                if (group.isNotEmpty)
                  Text(
                    group,
                    style: TextStyle(color: t.text2, fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                for (final PictureParamInfo p in byGroup[group]!) _slider(t, p),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _slider(ThemeTokens t, PictureParamInfo p) {
    final double value = _draft[p.key] ?? p.defaultValue;
    final String shown = value.toStringAsFixed(_decimalsOf(p.step));
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 74,
            child: Text(p.label, style: TextStyle(color: t.text2, fontSize: 12)),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                value: value.clamp(p.min, p.max),
                min: p.min,
                max: p.max,
                divisions: _divisionsOf(p),
                onChanged: (double v) => _onChanged(p, v),
                onChangeEnd: (double v) => _onChangeEnd(p, v),
              ),
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              '$shown${p.unit}',
              textAlign: TextAlign.right,
              style: TextStyle(color: t.text3, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  /// 滑块的分段数：按 step 算，但夹到 [1, 400]（divisions 太大 Slider 会卡）。
  int? _divisionsOf(PictureParamInfo p) {
    if (p.step <= 0) return null;
    final int n = ((p.max - p.min) / p.step).round();
    if (n <= 0) return null;
    return n.clamp(1, 400);
  }

  int _decimalsOf(double step) {
    final String text = step.toString();
    final int dot = text.indexOf('.');
    if (dot < 0) return 0;
    final String frac = text.substring(dot + 1);
    return frac == '0' ? 0 : frac.length;
  }
}

/// 「画面调节」浮层本体：一层**透明**的点击命中面 + 右上角的面板。
///
/// 单独成 widget 而不是内联在 `PlayerSurface._openPicturePanel` 的 OverlayEntry 里，
/// 是因为 `PlayerSurface` 在本仓测试里挂不起来（一 build 到 `VideoStage` 就要
/// media_kit 的原生纹理）。抽出来之后「遮罩不许给画面盖颜色」这条**能在测试里钉住**
/// （`test/widgets/picture_panel_test.dart`）—— 这正是用户 2026-10-18 报的那个缺陷：
/// 遮罩原本铺 `tokens.base.withValues(alpha: 0.28)`，浅色主题下视频上多了一层白雾。
///
/// 为什么干脆不压暗（连黑色遮罩也不要）：这个面板的唯一用途是**看着画面调参数**，
/// 遮罩会同时改变感知的亮度/对比/饱和 —— 用户在这层遮罩下调出来的值，关掉面板再看
/// 就是另一个样子。点击面板外关闭交给命中面（不画颜色），Esc / ✕ 也都能关。
class PicturePanelLayer extends StatelessWidget {
  const PicturePanelLayer({
    super.key,
    required this.menu,
    required this.tokens,
    required this.onClose,
  });

  final PictureMenu menu;
  final ThemeTokens tokens;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Stack(
        children: <Widget>[
          // 命中面：铺满全屏但**不画任何颜色**（点击面板外 = 关闭）。
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: const SizedBox.expand(),
          ),
          Positioned(
            top: kPicturePanelTop,
            right: kPicturePanelMargin,
            child: PicturePanel(menu: menu, tokens: tokens, onClose: onClose),
          ),
        ],
      ),
    );
  }
}
