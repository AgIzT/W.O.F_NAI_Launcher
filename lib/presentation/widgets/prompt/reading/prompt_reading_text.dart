import 'package:flutter/material.dart';

import '../../common/themed_input.dart';
import 'prompt_reading_layer.dart';
import 'prompt_reading_spacing.dart';

/// Plain source text whose spans can make room for readings.
class _ReadingTextController extends TextEditingController
    with PromptReadingSpacingHost {
  _ReadingTextController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    return TextSpan(
      style: base,
      children: applyReadingSpacing(
        [TextSpan(text: text, style: base)],
        base,
        MediaQuery.textScalerOf(context),
      ),
    );
  }
}

/// Selectable source and annotations for an explicitly opened detail view.
class PromptReadingText extends StatefulWidget {
  const PromptReadingText({super.key, required this.text, this.style});
  final String text;
  final TextStyle? style;

  @override
  State<PromptReadingText> createState() => _PromptReadingTextState();
}

class _PromptReadingTextState extends State<PromptReadingText> {
  late final _controller = _ReadingTextController(text: widget.text);

  @override
  void didUpdateWidget(PromptReadingText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _controller.text = widget.text;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style =
        widget.style ??
        Theme.of(context).textTheme.bodyMedium ??
        const TextStyle(fontSize: 14);
    return PromptReadingLayer(
      controller: _controller,
      enabled: true,
      style: style.copyWith(
        fontSize: (style.fontSize ?? 14) * .65,
        height: 1,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      child: ThemedInput(
        controller: _controller,
        readOnly: true,
        showCursor: false,
        embedded: true,
        maxLines: null,
        minLines: 1,
        contentPadding: EdgeInsets.zero,
        style: style.copyWith(
          height: PromptReadingLayer.lineHeight,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      ),
    );
  }
}
