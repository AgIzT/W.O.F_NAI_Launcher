import 'package:nai_launcher/presentation/widgets/common/studio_material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/utils/localization_extension.dart';
import '../../../prompt/reading/prompt_reading_text.dart';
import '../../app_toast.dart';
import '../../translation_icon.dart';
import '../../studio_icons.dart';

/// Read-only prompt text with explicitly opened tag readings.
class PromptSection extends ConsumerStatefulWidget {
  const PromptSection({
    super.key,
    required this.title,
    required this.icon,
    required this.content,
    this.initiallyExpanded = false,
    this.contentColor,
    this.borderColor,
    this.customContent,
    this.inspectorStyle = false,
    this.contentStyle,
    this.previewLines,
    this.onCopy,
    this.sectionBuilder,
  });

  final String title;
  final IconData icon;
  final String content;
  final bool initiallyExpanded;
  final Color? contentColor;
  final Color? borderColor;
  final Widget? customContent;
  final bool inspectorStyle;
  final TextStyle? contentStyle;
  final int? previewLines;
  final VoidCallback? onCopy;

  /// Alternate layout; a null reading widget means the original is visible.
  final Widget Function(BuildContext, Widget action, Widget? translated)?
  sectionBuilder;

  @override
  ConsumerState<PromptSection> createState() => _PromptSectionState();
}

class _PromptSectionState extends ConsumerState<PromptSection> {
  late bool _expanded;
  bool _readingVisible = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  void didUpdateWidget(covariant PromptSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content) {
      _readingVisible = false;
    }
  }

  void _toggleReadings() => setState(() {
    _readingVisible = !_readingVisible;
    _expanded = true;
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final hasContent = widget.content.isNotEmpty;
    if (widget.sectionBuilder case final builder?) {
      return builder(
        context,
        IconButton(
          key: const Key('detail-prompt-translate'),
          style: IconButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: const Size(20, 16),
            maximumSize: const Size(20, 16),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            overlayColor: Colors.transparent,
            splashFactory: NoSplash.splashFactory,
          ),
          tooltip: _readingVisible
              ? context.l10n.promptReading_hideReadings
              : context.l10n.promptReading_showReadings,
          onPressed: _toggleReadings,
          icon: TranslationIcon(
            size: 13,
            color: _readingVisible ? colors.primary : colors.onSurfaceVariant,
          ),
        ),
        _readingVisible ? _readingInput() : null,
      );
    }
    if (widget.inspectorStyle) return _buildInspector(context);
    final buttonStyle = IconButton.styleFrom(
      padding: const EdgeInsets.all(4),
      minimumSize: const Size(28, 28),
      overlayColor: Colors.transparent,
      splashFactory: NoSplash.splashFactory,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              widget.icon,
              size: 16,
              color: widget.contentColor ?? colors.primary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (hasContent && widget.customContent == null)
              IconButton(
                key: const Key('detail-prompt-translate'),
                tooltip: _readingVisible
                    ? context.l10n.promptReading_hideReadings
                    : context.l10n.promptReading_showReadings,
                onPressed: _toggleReadings,
                style: buttonStyle,
                icon: TranslationIcon(
                  size: 17,
                  color: _readingVisible
                      ? colors.primary
                      : colors.onSurfaceVariant,
                ),
              ),
            if (hasContent) ...[
              IconButton(
                tooltip: _expanded
                    ? context.l10n.common_collapse
                    : context.l10n.common_expand,
                style: buttonStyle,
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                ),
              ),
              IconButton(
                tooltip: context.l10n.detail_copyLabel(widget.title),
                style: buttonStyle,
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: widget.content));
                  AppToast.success(
                    context,
                    context.l10n.toast_copiedTitle(widget.title),
                  );
                },
                icon: const Icon(Icons.copy, size: 16),
              ),
            ],
          ],
        ),
        if (_expanded && hasContent) ...[
          const SizedBox(height: 8),
          widget.customContent ??
              (_readingVisible
                  ? _readingInput()
                  : SelectableText(widget.content, style: widget.contentStyle)),
        ],
      ],
    );
  }

  Widget _buildInspector(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final buttonStyle = IconButton.styleFrom(
      padding: EdgeInsets.zero,
      minimumSize: const Size(24, 24),
      maximumSize: const Size(24, 24),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      overlayColor: Colors.transparent,
      splashFactory: NoSplash.splashFactory,
    );
    final textStyle = widget.contentStyle?.copyWith(fontSize: 12, height: 1.6);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 6),
            child: SizedBox(
              height: 24,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Visibility(
                    visible: _hovered,
                    maintainSize: true,
                    maintainAnimation: true,
                    maintainState: true,
                    child: IconButton(
                      key: const Key('detail-prompt-translate'),
                      style: buttonStyle,
                      tooltip: _readingVisible
                          ? context.l10n.promptReading_hideReadings
                          : context.l10n.promptReading_showReadings,
                      onPressed: _toggleReadings,
                      icon: TranslationIcon(
                        size: 15,
                        color: _readingVisible
                            ? colors.primary
                            : colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    style: buttonStyle,
                    tooltip: context.l10n.common_copy,
                    icon: const Icon(StudioIcons.galleryCopy, size: 14),
                    onPressed:
                        widget.onCopy ??
                        () => Clipboard.setData(
                          ClipboardData(text: widget.content),
                        ),
                  ),
                ],
              ),
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: colors.surfaceContainer,
              border: Border.all(color: theme.dividerColor),
              borderRadius: BorderRadius.circular(6),
            ),
            child: _readingVisible
                ? _readingInput()
                : widget.previewLines == null
                ? SelectableText(widget.content, style: textStyle)
                : Text(
                    widget.content,
                    style: textStyle,
                    maxLines: widget.previewLines,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _readingInput() => PromptReadingText(
    key: const Key('detail-prompt-reading'),
    text: widget.content,
    style: widget.contentStyle,
  );
}
