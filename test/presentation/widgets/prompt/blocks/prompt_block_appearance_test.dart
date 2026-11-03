import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/presentation/widgets/prompt/blocks/prompt_block_appearance.dart';

/// Records every canvas call the painter makes.
class _RecordingCanvas implements Canvas {
  final calls = <Symbol>[];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      calls.add(invocation.memberName);
}

List<Symbol> _paint(String appearance) {
  final canvas = _RecordingCanvas();
  PromptBlockPatternPainter(
    appearance: appearance,
    color: Colors.teal,
  ).paint(canvas, const Size(48, 20));
  return canvas.calls;
}

void main() {
  test('only stripes, dots and gradient paint a pattern', () {
    for (final appearance in PromptBlockAppearance.selectable) {
      final patterned = {
        PromptBlockAppearance.stripes,
        PromptBlockAppearance.dots,
        PromptBlockAppearance.gradient,
      }.contains(appearance);
      expect(_paint(appearance), patterned ? isNotEmpty : isEmpty);
    }
  });

  test('retired and unknown appearances render like classic', () {
    // Blocks saved with the retired translation appearance keep that value.
    for (final appearance in ['translation', 'unknown']) {
      expect(_paint(appearance), isEmpty);
      const color = Colors.teal;
      expect(
        PromptBlockAppearance.fill(appearance, color, dark: false),
        PromptBlockAppearance.fill(
          PromptBlockAppearance.classic,
          color,
          dark: false,
        ),
      );
    }
  });
}
