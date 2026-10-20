/// 「画面调节 / 音效」这两个侧栏目的地**现在存在吗**（= 装上对应的包了吗）。
///
/// 为什么不能直接读 `extensionsProvider`：那个 provider 是**懒加载**的（没进过扩展页
/// 就一次盘都没扫过，见 `ExtensionsController.ensureLoaded`）。侧栏在启动第一帧就要决定
/// 那两行显示不显示，用户完全可能一次都不进扩展页，所以判据必须自己扫一遍扩展目录。
///
/// 为什么单独一个 provider 而不是在 `ui/shell.dart` 里现扫：扫描结果是两个新页面
/// **和**侧栏共用的同一份数据（包的清单 / 音效档清单），各扫一份必然漂移——扩展页刚
/// 关掉某个预设、侧栏还按老清单显示，就是这种漂移的典型表现。
///
/// 判据与播放窗口开窗那次扫描**完全同一个函数**（`loadPicturePacks` /
/// `AudioPresetConsumer`）：这里说"有"，播放窗口就一定挂得上菜单。
///
/// 失败口径：扫不出来 = 当作没有（侧栏少两行、页面进不去），只记日志 ——
/// 一个坏清单绝不能把主窗口拖崩。
library;

import 'dart:async';
import 'dart:io';

import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shikiin/shikiin.dart' as shikiin;

import 'audio_presets.dart';
import 'extension_settings.dart';
import 'extensions.dart' show extensionsRevisionProvider;
import 'generic_packs.dart';
import 'infra.dart' show supportDirProvider;
import 'picture_pack.dart';

/// 当前可用的「画面调节包」与「音效档」。
@immutable
class PackAvailability {
  const PackAvailability({
    this.picturePacks = const <PicturePack>[],
    this.audioPresets = const <shikiin.AudioFxPreset>[],
  });

  /// 能用的画面调节包（清单解析通过 + 模板在盘上 + 模板能渲染，且按
  /// `extension-settings.json` 的 `hiddenPresets` 过滤过）。
  final List<PicturePack> picturePacks;

  /// 能用的音效档（`audio-pack` 且面是 `player.audio`）。
  final List<shikiin.AudioFxPreset> audioPresets;

  bool get hasPicture => picturePacks.isNotEmpty;
  bool get hasAudioFx => audioPresets.isNotEmpty;

  /// 一个包都没有（启动初值 / 探测失败 / 没注入数据根）。
  static const PackAvailability none = PackAvailability();
}

class PackAvailabilityController extends Notifier<PackAvailability> {
  bool _loaded = false;
  bool _scanning = false;

  @override
  PackAvailability build() {
    // 装 / 卸 / 启停 / 改预设可见性都会 bump 版本号：跟着重扫，侧栏那两行立刻跟上
    // （否则用户装完包得重启才看得到入口 —— 那正是这一轮要消灭的体验）。
    ref.listen<int>(extensionsRevisionProvider, (int? previous, int next) {
      unawaited(refresh());
    });
    return PackAvailability.none;
  }

  /// 启动时调一次；已扫过就什么都不做。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    await refresh();
  }

  /// 强制重扫（扩展变更之后）。
  Future<void> refresh() async {
    // 连续 bump（一次安装会 bump 两次）不该排成一串扫描：前一次还没结束就跳过，
    // 它结束时会读到最新状态。
    if (_scanning) return;
    _loaded = true;
    _scanning = true;
    try {
      final Directory? dir = ref.read(supportDirProvider);
      if (dir == null) {
        // 装配问题（测试/未注入）：按"没有包"处理，页面与侧栏都当没装。
        state = PackAvailability.none;
        return;
      }
      final core.ExtensionUserSettings settings = await loadExtensionUserSettings(dir);
      final List<PicturePack> packs = await loadPicturePacks(
        dir,
        hiddenPresets: settings.hiddenPresets,
      );
      final List<shikiin.AudioFxPreset> audio = <shikiin.AudioFxPreset>[];
      try {
        final AudioPresetConsumer consumer = AudioPresetConsumer(
          onChanged: (List<shikiin.AudioFxPreset> presets) => audio.addAll(presets),
        );
        await consumer.setPacks(await scanGenericPacks(dir));
      } catch (error) {
        // 音效扫不出来只影响音效那一行/那一页，画面照常。
        debugPrint('[packs] 音效包探测失败（音效页先不出现）：$error');
        audio.clear();
      }
      state = PackAvailability(
        picturePacks: packs,
        audioPresets: List<shikiin.AudioFxPreset>.unmodifiable(audio),
      );
    } catch (error) {
      debugPrint('[packs] 探测可用包失败（侧栏那两个入口先不出现）：$error');
      state = PackAvailability.none;
    } finally {
      _scanning = false;
    }
  }
}

final NotifierProvider<PackAvailabilityController, PackAvailability> packAvailabilityProvider =
    NotifierProvider<PackAvailabilityController, PackAvailability>(
  PackAvailabilityController.new,
);
