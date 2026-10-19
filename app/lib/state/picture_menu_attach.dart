/// 把「画面调节」接进**已经在跑的**播放窗口。
///
/// 用户 2026-10-18 原话：「装完插件后播放器不会立马生效」。
///
/// 为什么需要单独一个入口：播放窗口是独立引擎，画面调节菜单只在**开窗**那一步
/// 扫扩展目录（`main.dart` 的 `_runPlayerWindow`）。用户在窗口已经开着的时候装了
/// 画面调节包，那次扫描当然没看到它；更麻烦的是 `pictureMenuProvider` 是个**只读
/// Provider**（`shikiinOverrides` 里 `overrideWith((ref) => runtime.pictureMenu)`）——
/// 第一次读到 null 就被缓存住，之后 `runtime.attachPictureMenu` 改了什么都不会
/// 再读回来。于是「装完插件 → 右键菜单里没有画面调节」只能靠**重启整个应用**才恢复：
/// 用户点播放窗口的 ✕ 只是把它**收起来**（hide，引擎留着），不会重新扫。
///
/// 这个函数就是那条"运行期补挂"的路径，语义与开窗那次扫描**完全一致**
/// （同一个 `loadPicturePacks` + 同一份 `extension-settings.json` +
/// 同一个 `PictureSettingsStore`），所以"重开窗口"与"扩展变了一声通知"得到的是
/// 同一份结果。
library;

import 'dart:io';

import 'package:shikiin/shikiin.dart';

import 'extension_settings.dart';
import 'picture_menu_adapter.dart';
import 'picture_pack.dart';
import 'picture_settings_io.dart';

/// 确保这扇窗口的右键菜单里有「画面调节」，返回当前挂着的菜单（没有包 → null）。
///
/// [current] = 现在挂着的菜单（没有就传 null）；[attach] = 挂载动作
/// （宿主传 `runtime.attachPictureMenu`，**不能**在这里直接摸 `AppRuntime`：
/// 这个文件要被单测拿临时目录 + 假播放器跑，不能拉进 `bootstrapPlayer`）。
///
/// **永不抛**：`loadPicturePacks` / `loadExtensionUserSettings` / `reload()` 都是
/// "坏文件只退化"的实现；这里再兜一层，画面调节装不上最多是少一项菜单，
/// 绝不能把正在播的播放窗口弄崩。
Future<PictureMenu?> ensurePictureMenuAttached({
  required Anime4kController player,
  required Directory supportDir,
  required PictureMenu? current,
  required void Function(PictureMenu?) attach,
}) async {
  try {
    // 已经有菜单：重扫就够。包被卸载/禁用、预设被关掉、包换了版本（同 id）都靠
    // 这一次 `reload()` 收口（见 `PictureMenuAdapter.reload` 的说明）。
    if (current != null) {
      await current.reload();
      return current;
    }

    final settings = await loadExtensionUserSettings(supportDir);
    final List<PicturePack> packs = await loadPicturePacks(
      supportDir,
      hiddenPresets: settings.hiddenPresets,
    );
    // 没包：不挂菜单（右键菜单里那一整项都不出现）。不动用户别的状态。
    if (packs.isEmpty) return null;

    // 与开窗那条路同一套装配：缓存目录、按 `<数据根>/dsanima/picture-settings.json`
    // 恢复上次的取值，并在每次真正下发之后写回。
    final PictureSettingsStore store = PictureSettingsStore(supportDir);
    final PictureController controller = PictureController(
      player: player,
      shaderCacheDir: pictureCacheDirOf(supportDir),
      packs: packs,
      settings: await store.load(),
      onChanged: store.save,
    );
    final PictureMenuAdapter menu = PictureMenuAdapter(
      source: controller,
      supportDir: supportDir,
    );
    attach(menu);
    // 上次调好的画面还留着：挂上就恢复（`apply()` 自己会清/挂、永不抛）。
    if (!controller.isOff) await controller.apply();
    return menu;
  } catch (error) {
    // 画面调节是"锦上添花"：装配失败只该让菜单少一项。
    return null;
  }
}
