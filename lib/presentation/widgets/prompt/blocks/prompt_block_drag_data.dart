import '../../../../data/models/prompt_block/pill_document.dart';

/// 拖入生成页时使用的最小块引用。
///
/// 库块使用当前库中的正文，临时块携带独立快照。
class PromptBlockDragData {
  const PromptBlockDragData({
    required this.blockId,
    this.temp,
    this.instanceMarker,
    this.paletteIndex,
    this.blockIds,
    this.sourceCollectionId,
    this.sourceFavorites = false,
  });

  final String blockId;

  final PillTempContent? temp;

  /// 管理页批量拖动使用；生成提示词的落点仍只取 blockId。
  final List<String>? blockIds;
  final String? sourceCollectionId;
  final bool sourceFavorites;

  List<String> get transferIds => blockIds ?? [blockId];

  /// 药丸编辑器专用：文内拖动时已存在实例的定位信息。
  /// null 表示从块库拖入的新块。
  final PillInstanceDragRef? instanceMarker;

  /// 颜料版内部拖序用：该块在板上的当前下标；null = 非颜料版来源。
  /// 药丸编辑器不读此字段。
  final int? paletteIndex;
}

/// 文内拖动药丸的定位信息：标记字符 + 第几次出现
/// （粘贴会产生同一字符的多处出现，仅靠字符无法区分拖的是哪一份）。
class PillInstanceDragRef {
  const PillInstanceDragRef({
    required this.marker,
    required this.occurrence,
    this.scope,
  });

  final String marker;
  final int occurrence;
  final String? scope;
}
