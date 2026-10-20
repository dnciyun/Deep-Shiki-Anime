/// 「音效」页（2026-10-20，用户：「给插件里的…音频包都做独立页面，侧边栏进入，
/// 去除原本的设置位置」）。
///
/// 职责分界（spec §1）：**「扩展」只管装 / 卸 / 启停**，这一页只管**运行期配置**
/// （选档、总强度、对白压缩、音量均衡）。所以页头留一行「<包名> · 去扩展页管理」——
/// 用户想卸包时有一条明确的路，不用回去猜入口在哪儿。
///
/// 数据从哪儿来（刻意不读 `extensionsProvider`）：档位清单来自
/// `packAvailabilityProvider.audioPresets`，与侧栏判断「这一页该不该出现」用的是**同一份
/// 扫描结果**；自己再扫一遍就会出现"侧栏说有、页面说没有"这种自相矛盾。
///
/// 用词统一成「音效」（不叫"音频"）：代码、播放器右键菜单、插件包名（音效包）都叫音效，
/// 页面再叫"音频"就是同一个东西两个词。
///
/// 生效链路（方案 A：文件是唯一真相，spec §3）：
/// 改 → `audioFxSettingsProvider.update`（原子写 `audio-fx.json`）+ `sendAudioFx`（只带状态）。
/// 播放窗口没开时那条推送是空操作，改动不会丢：下次开窗随启动参数带过去。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shikiin/shikiin.dart' as shikiin;

import '../state/audio_fx_settings.dart';
import '../state/packs_available.dart';
import '../state/providers.dart'
    show ShellTab, navProvider, playerWindowServiceProvider, supportDirProvider;
import '../theme/tokens.dart';
import 'audio_fx_section.dart';
import 'widgets/ds_cards.dart';
import 'widgets/hues.dart';

/// 「去扩展页管理」那个链接（测试锚点）。
const Key dsAudioFxManageKey = ValueKey<String>('audio-fx-manage');

/// 没扫到任何音效档时的空态（侧栏按理已经藏了这一页，但深链/老配置仍能进来）。
const Key dsAudioFxEmptyKey = ValueKey<String>('audio-fx-empty');

class AudioFxPage extends ConsumerStatefulWidget {
  const AudioFxPage({super.key});

  @override
  ConsumerState<AudioFxPage> createState() => _AudioFxPageState();
}

class _AudioFxPageState extends ConsumerState<AudioFxPage> {
  @override
  void initState() {
    super.initState();
    // 读盘从扩展页搬到这一页（spec §5：扩展页不再替音效读盘）。
    // 不读盘的话页面显示的是 controller 的内存初值（原声 / 100%）——
    // 用户上次明明选了某档，进来却看到"原声"，再随便动一下就把设置覆盖掉了。
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_ensureLoaded()));
  }

  Future<void> _ensureLoaded() async {
    final Directory? dir = ref.read(supportDirProvider);
    // 没注入支持目录 = 装配问题（首启向导/设置页会明确报），这里静默：
    // 页面能显示、只是改动不落盘，比整棵树报错合理。
    if (dir == null) return;
    await ref.read(audioFxSettingsProvider.notifier).ensureLoaded(dir);
  }

  /// 页面上任何一处改动都走这里：**先落盘、再通知**（顺序不能反）。
  ///
  /// 反过来会出"播放窗口读到的还是旧文件、却收到新状态"的竞态；
  /// 而先落盘这一侧 `update` 只是 `await` 一次原子写，用户感知不到延迟。
  void _onChanged(shikiin.AudioFxState next) {
    unawaited(ref.read(audioFxSettingsProvider.notifier).update(next));
    // 播放窗口没开 = 空操作（下次开窗会带上最新那份），不报错、不弹横幅。
    unawaited(ref.read(playerWindowServiceProvider).sendAudioFx(next.toJson()));
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final DsHue hue = hueOfTab(ShellTab.audioFx);
    final List<shikiin.AudioFxPreset> presets =
        ref.watch(packAvailabilityProvider).audioPresets;
    final shikiin.AudioFxState state = ref.watch(audioFxSettingsProvider);

    return ListView(
      padding: EdgeInsets.fromLTRB(t.spacing, t.spacing, t.spacing, t.spacing * 2),
      children: <Widget>[
        DsSection(
          title: '音效',
          hue: hue,
          icon: Icons.graphic_eq,
          subtitle: '改动立刻生效：播放窗口开着时当场切换，没开就下次开播带上。'
              '播放窗口右键也能快速切档，两边说的是同一份设置。',
          trailing: DsChip(label: '${presets.length} 档', hue: hue),
          child: _manageRow(t, presets),
        ),
        if (presets.isEmpty)
          DsSection(
            title: '没有音效档',
            hue: hue,
            child: Text(
              '没扫到可用的音效档，所以这里没有可调的东西。'
              '确认音效包已经装上并启用（包的类型要是 audio-pack，清单里的面要写 player.audio）——'
              '上面那行「去扩展页管理」可以直达管理页。',
              key: dsAudioFxEmptyKey,
              style: TextStyle(color: t.text2, fontSize: DsTypeScale.body, height: 1.6),
            ),
          )
        else
          DsSection(
            title: '档位与强度',
            hue: hue,
            child: AudioFxSection(
              tokens: t,
              presets: presets,
              state: state,
              onChange: _onChanged,
            ),
          ),
      ],
    );
  }

  /// 页头那行「<包名> · 去扩展页管理」：包名是"这些档到底是谁给的"，
  /// 链接是"不用了去哪卸"。两件事写一行，是因为它们在用户脑里是同一个动作的两步。
  Widget _manageRow(DsTokens t, List<shikiin.AudioFxPreset> presets) {
    final List<String> names = <String>[];
    for (final shikiin.AudioFxPreset preset in presets) {
      final String name = preset.packName.trim().isEmpty ? '音效包' : preset.packName.trim();
      if (!names.contains(name)) names.add(name);
    }
    final String label = names.isEmpty ? '去扩展页管理' : '${names.join('、')} · 去扩展页管理';
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: dsAudioFxManageKey,
        onTap: () => ref.read(navProvider.notifier).select(ShellTab.extensions),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.extension_outlined, size: 14, color: t.accent),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: t.accent,
                  fontSize: DsTypeScale.caption,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
