import 'package:nai_launcher/presentation/widgets/common/studio_material.dart';

import '../../../../data/models/prompt_block/prompt_block.dart';
import 'prompt_block_colors.dart';
import 'prompt_block_icons.dart';
import '../pills/prompt_pill.dart';
import '../../common/uiux_prototype_icon.dart';

class PromptBlockPill extends StatelessWidget {
  const PromptBlockPill({
    super.key,
    required this.block,
    required this.displayTitle,
    required this.maxWidth,
    required this.onTap,
    this.selected = false,
    this.multiSelected = false,
    this.onSecondaryTap,
  });

  final PromptBlock block;
  final String displayTitle;
  final double maxWidth;
  final VoidCallback onTap;
  final bool selected;

  /// 多选模式下属于选中集合（叠加勾选角标；描边复用 [selected]）。
  final bool multiSelected;

  /// 右键菜单入口（secondary tap）。
  final void Function(TapUpDetails details)? onSecondaryTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blockColor = promptBlockColorFromString(block.color);
    return GestureDetector(
      onSecondaryTapUp: onSecondaryTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: ValueKey('prompt-block-pill-body-${block.id}'),
            onTap: onTap,
            borderRadius: BorderRadius.circular(PromptPillSize.regular.radius),
            child: PromptPill(
              title: displayTitle,
              color: blockColor,
              appearance: block.appearance,
              icon: promptBlockIconFromName(block.iconName),
              focused: selected,
              trailing: multiSelected
                  ? UiuxPrototypeIcon(
                      Icons.check_circle,
                      size: 12,
                      color: theme.colorScheme.primary,
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
