import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/prompt_block_palette_provider.dart';
import '../widgets/prompt/blocks/prompt_block_drag_data.dart';

/// Store a library reference or an independent temporary block snapshot.
Future<void> acceptPaletteDrag(
  WidgetRef ref,
  PromptBlockDragData data, {
  int? index,
}) async {
  final palette = ref.read(promptBlockPaletteNotifierProvider.notifier);
  if (data.paletteIndex != null) return;
  if (data.temp case final temp?) {
    await palette.addTemporary(temp, index: index);
    return;
  }
  if (index == null) {
    await palette.addBlock(data.blockId);
  } else {
    await palette.insertBlock(data.blockId, index);
  }
}
