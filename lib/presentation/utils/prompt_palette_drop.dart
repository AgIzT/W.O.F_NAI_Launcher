import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/prompt_block_palette_provider.dart';
import '../widgets/prompt/blocks/prompt_block_drag_data.dart';

/// Add an existing library block to the palette without changing its content.
Future<void> acceptPaletteDrag(
  WidgetRef ref,
  PromptBlockDragData data, {
  int? index,
}) async {
  final palette = ref.read(promptBlockPaletteNotifierProvider.notifier);
  if (index == null) {
    await palette.addBlock(data.blockId);
  } else {
    await palette.insertBlock(data.blockId, index);
  }
}
