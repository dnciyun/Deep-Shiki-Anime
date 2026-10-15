// 极简内核守卫测试（契约 §4 + 冻结 API）。
//
// 钉住三件事，防止后续改动悄悄回退：
// 1. 播放器不再有自己的主题系统：lib/ 里除 `models/theme_tokens.dart`（token 源本身）
//    外，**任何** `Color(0x…)` 字面量都会让这条测试红。
// 2. 续播键格式逐字未变（`resume:<md5(path|size)>`）——改了会让用户既有续播记录失效。
// 3. 契约保留清单：PlayerAction / Anime4kPreset / EpisodeGroup / ThemeTokens 的形态。
import 'dart:io';

import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/controllers/playlist_controller.dart';
import 'package:shikiin/controllers/settings_controller.dart';
import 'package:shikiin/models/anime4k_preset.dart';
import 'package:shikiin/models/media_item.dart';
import 'package:shikiin/models/player_action.dart';
import 'package:shikiin/models/theme_tokens.dart';

void main() {
  test('lib/ 里除 models/theme_tokens.dart 外没有 Color(0x…) 字面量', () {
    final lib = Directory('lib');
    expect(lib.existsSync(), isTrue, reason: '本测试需在 ShikiiN/ 包根目录运行');

    final offenders = <String>[];
    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll('\\', '/');
      // token 源本身：颜色字面量只允许集中在这一个文件里（等价宿主的 theme/tokens.dart）。
      if (path.endsWith('lib/models/theme_tokens.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('Color(0x')) offenders.add('$path:${i + 1}');
      }
    }
    expect(offenders, isEmpty, reason: '播放器禁止自带颜色：一律从 ThemeTokens 读（契约 §4）。违规处：$offenders');
  });

  test('画面区底色恒为纯黑，且不得用主题色铺（否则标题栏/控制栏看起来变粗）', () {
    // 用户 2026-10-10：「视频的边边改为全黑色，不要和标题栏控制栏同色，
    // 会显得这两个变粗了」。`tokens.base` 正好是标题栏底色，画面留黑边时
    // 两条栏会和黑边糊成一片 ⇒ 这里钉住"画面区不许用 tokens.* 当底色"。
    expect(ThemeTokens.videoLetterbox, const Color(0xFF000000));
    expect(
      ThemeTokens.fallback.base,
      isNot(ThemeTokens.videoLetterbox),
      reason: '主题底色不能等于画面区黑边，否则两者看不出边界',
    );

    final source = File('lib/widgets/player_surface.dart').readAsStringSync();
    final offenders = <String>[];
    for (final line in source.split('\n')) {
      final t = line.trim();
      if (t.startsWith('//')) continue;
      // 只查 VideoStage 的 background 实参。
      if (!t.contains('background:')) continue;
      if (t.contains('ThemeTokens.videoLetterbox')) continue;
      offenders.add(t);
    }
    expect(
      offenders,
      isEmpty,
      reason: 'VideoStage 的 background 必须是 ThemeTokens.videoLetterbox。违规处：$offenders',
    );
  });

  test('续播键格式逐字未变：resume:<md5(path|size)>', () {
    // 两个都不存在的「路径」→ size 落 0，哈希可离线复算（md5 of "path|0"）。
    expect(
      SettingsController.resumeKey(r'D:\media\ep01.mkv'),
      'resume:45c052ea9dc4b5550dade4b43ed37149',
    );
    expect(
      SettingsController.resumeKey('http://127.0.0.1:4321/torrents/abc/stream?file=1&token=x'),
      'resume:859c68e624a094426b2886455291f50a',
    );
  });

  test('PlayerAction 只剩契约保留的 19 个动作', () {
    expect(PlayerAction.values.map((a) => a.name).toList(), const [
      'playPause',
      'seekForward',
      'seekBackward',
      'volumeUp',
      'volumeDown',
      'toggleMute',
      'toggleFullscreen',
      'exitFullscreen',
      'nextItem',
      'previousItem',
      'cycleAudioTrack',
      'cycleSubtitleTrack',
      'openSettings',
      'closeVideo',
      'togglePip',
      'toggleAlwaysOnTop',
      'toggleStats',
      'openSubtitleFile',
      'toggleAnime4k',
    ]);
    // 被砍掉的动作一个都不能复活。
    for (final gone in const [
      'openFile',
      'openFolder',
      'toggleTrackPanel',
      'togglePlaylist',
      'togglePicturePanel',
      'cyclePlayOrder',
      'cycleAbLoop',
      'subtitleDelayUp',
      'subtitleDelayDown',
      'previousChapter',
      'nextChapter',
      'screenshot',
      'gifMarkStart',
      'gifMarkEnd',
      'exportGifClip',
      'markOpEnd',
      'markEdStart',
      'skipIntroOutro',
      'clearSkipRange',
      'toggleVolumeBoost',
      'openEqualizer',
    ]) {
      expect(PlayerAction.values.asNameMap().containsKey(gone), isFalse, reason: gone);
    }
  });

  test('EpisodeGroup：单集/边界不提供上一集下一集（契约 §9 隐藏而非禁用）', () {
    const a = MediaItem(path: 'a', title: 'A');
    const b = MediaItem(path: 'b', title: 'B', streamUrl: null);
    const c = MediaItem(path: 'c', title: 'C');

    const single = EpisodeGroup(items: [a]);
    expect(single.hasPrevious, isFalse);
    expect(single.hasNext, isFalse);

    const first = EpisodeGroup(items: [a, b, c]);
    expect(first.hasPrevious, isFalse);
    expect(first.hasNext, isTrue);
    expect(first.next?.path, 'b');

    const last = EpisodeGroup(items: [a, b, c], currentIndex: 2);
    expect(last.hasPrevious, isTrue);
    expect(last.hasNext, isFalse);
    expect(last.previous?.path, 'b');

    const mid = EpisodeGroup(items: [a, b, c], currentIndex: 1);
    expect(mid.previous?.path, 'a');
    expect(mid.next?.path, 'c');

    // 越界索引不崩，也不给出相邻项。
    const bad = EpisodeGroup(items: [a], currentIndex: 5);
    expect(bad.hasPrevious, isFalse);
    expect(bad.hasNext, isFalse);
  });

  test('MediaItem.streamUrl 只作传递用，== 仍只按 path（既有语义）', () {
    final withUrl = MediaItem(
      path: 'x',
      title: 'X',
      streamUrl: Uri.parse('http://127.0.0.1:1/s?token=t'),
    );
    const withoutUrl = MediaItem(path: 'x', title: 'X');
    expect(withUrl, withoutUrl);
    expect(withUrl.hashCode, withoutUrl.hashCode);
  });

  test('超分：只剩 3 档 + 关，shader 清单仍是 12 个文件', () {
    expect(Anime4kPreset.values.map((p) => p.name).toList(), const [
      'off',
      'light',
      'standard',
      'ultra',
    ]);
    expect(Anime4kPreset.simpleTiers, const [
      Anime4kPreset.light,
      Anime4kPreset.standard,
      Anime4kPreset.ultra,
    ]);
    // 解包逻辑与 app/test/anime4k_assets_test.dart 依赖这份清单。
    expect(kAnime4kShaderFiles.length, 12);
    expect(anime4kShaderChain(Anime4kPreset.off), isEmpty);
    for (final p in Anime4kPreset.simpleTiers) {
      expect(anime4kShaderChain(p), isNotEmpty, reason: p.name);
    }
    // 控制栏胶囊的循环顺序：关→轻→标→极→关。
    expect(Anime4kPreset.off.cycled, Anime4kPreset.light);
    expect(Anime4kPreset.light.cycled, Anime4kPreset.standard);
    expect(Anime4kPreset.standard.cycled, Anime4kPreset.ultra);
    expect(Anime4kPreset.ultra.cycled, Anime4kPreset.off);
  });

  test('ThemeTokens 是只读值对象：== / copyWith / fallback', () {
    expect(ThemeTokens.fallback, ThemeTokens.fallback);
    expect(ThemeTokens.fallback.hashCode, ThemeTokens.fallback.hashCode);

    final changed = ThemeTokens.fallback.copyWith(accent: const Color(0xFF112233));
    expect(changed.accent, const Color(0xFF112233));
    expect(changed, isNot(ThemeTokens.fallback));
    expect(changed.copyWith(accent: ThemeTokens.fallback.accent), ThemeTokens.fallback);

    // 宿主同一套值注入两次必须相等（widget 才能靠 == 短路重建）。
    final same = ThemeTokens.fallback.copyWith();
    expect(same, ThemeTokens.fallback);
  });

  test('shikiinOverrides 不许提前把播放器建出来（"主窗口不建 mpv"必须真的懒）', () {
    // `overrideWithValue(runtime.player)` 会**先求值实参** ⇒ 懒 getter 当场被调，
    // 主窗口照样在启动时建一份 mpv/ANGLE 渲染面（真机日志：Failed to create EGL
    // surface + 启动期偶发 0xC0000005）。只允许惰性 `overrideWith(...)`。
    final source = File('lib/infra/bootstrap.dart').readAsStringSync();
    final code = source
        .split('\n')
        .where((line) {
          final t = line.trimLeft();
          return !t.startsWith('//') && !t.startsWith('///') && !t.startsWith('*');
        })
        .join('\n');
    expect(
      code.contains('playerProvider.overrideWithValue(runtime.player)'),
      isFalse,
      reason: '这一行会让 lazyPlayer 失效：主窗口启动即建 mpv',
    );
    expect(
      code.contains('playerProvider.overrideWith('),
      isTrue,
      reason: '播放器 provider 必须惰性 override',
    );
  });
}
