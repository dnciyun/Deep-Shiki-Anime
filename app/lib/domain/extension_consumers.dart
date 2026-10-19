/// 通用扩展包的**宿主消费接口**。
///
/// 一个「面」（core 的 `ExtensionSurface`）对应宿主里一个 consumer：拿共享扫描器给的
/// 包、翻译成运行时认识的东西、装卸时回退。加一个新数据面 = 写一个 consumer + 注册它，
/// 不再改安装器/账单/扩展页。首个实现见 `state/subtitle_presets.dart`。
///
/// 本文件**不 import Flutter**：consumer 只依赖 core 与扫描结果。
library;

import '../state/generic_packs.dart';

abstract class ExtensionConsumer {
  /// 消费哪个面（必须等于 core 注册的 surface id，如 `player.subtitle`）。
  String get surface;

  /// 清单变了（装/卸/启停/升级）：重新收下这个面的包并应用。
  ///
  /// 实现方只处理 `payload.surface == surface` 的包，别家包不碰；失败要回退并留说明，
  /// 不许半截生效。
  Future<void> setPacks(List<GenericPack> packs);

  /// 回到内置/默认（删掉当前面提供的一切）。
  Future<void> revert();

  /// 扩展页/日志用的一句话：这个包给这个面带来了什么。
  String describe(GenericPack pack);
}
