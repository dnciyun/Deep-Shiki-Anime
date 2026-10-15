/// 产品图标（用户 2026-10-10：「图标统一成播放器的图标」）。
///
/// **唯一真源**：`ShikiiN/assets/icon.png` —— 播放器自己画在标题栏/空态上的那张。
/// 宿主侧所有露脸的图标（侧栏品牌位、首启向导抬头）都用它，不再各写一个字形/图。
///
/// 为什么不复制一份到 `app/assets/`：带包前缀的 `packages/<pkg>/assets/...`
/// 由包依赖关系自动进宿主 bundle（见 `app/pubspec.yaml` 里那条规则），
/// 复制一份等于制造第二个真源，换图时必然漏一处。
///
/// Windows 那份 `.ico`（exe / 窗口类 / 托盘）也来自同一张 PNG：
/// `tool/make_app_icon.py` 负责从它生成，改图后跑一次即可全仓统一。
library;

import 'package:flutter/material.dart';
import '../../theme/tokens.dart';

/// 播放器图标在宿主 bundle 里的路径（shikiin 包声明，宿主无需再声明）。
const String kDsBrandAsset = 'packages/shikiin/assets/icon.png';

/// 一张产品图标；[size] 是边长（正方形，原图也是正方形）。
class DsBrandIcon extends StatelessWidget {
  const DsBrandIcon({super.key, this.size = 20, this.radius});

  final double size;

  /// 圆角；不传 = 不裁圆角（原图自带透明边，小尺寸下更干净）。
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final Widget image = Image.asset(
      kDsBrandAsset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      // 原图 1080²：交给引擎按设备像素比缩放，避免默认线性插值放大后发糊。
      filterQuality: FilterQuality.medium,
      // 图标缺失时不要弹红：退回一个中性方块（真机上只在资源没进包时发生）。
      errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
          SizedBox(
        width: size,
        height: size,
        child: ColoredBox(
          color: context.ds.sunken,
        ),
      ),
    );
    if (radius == null) return image;
    return ClipRRect(borderRadius: BorderRadius.circular(radius!), child: image);
  }
}
