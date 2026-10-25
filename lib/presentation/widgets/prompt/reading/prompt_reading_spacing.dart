import 'package:flutter/widgets.dart';

/// Extra advance after selected UTF-16 offsets of [text], measured with the
/// exact [style] the editor renders. Computed from the current text on every
/// span build, so offsets can never lag behind an edit.
typedef PromptReadingSpacingResolver =
    Map<int, double> Function(String text, TextStyle style, TextScaler scaler);

/// A controller whose spans can reserve room for readings: a reading wider
/// than its tag pushes the next word right instead of being clipped. This is
/// letter spacing only — text, selection offsets, undo and generation input
/// stay the same.
mixin PromptReadingSpacingHost on TextEditingController {
  PromptReadingSpacingResolver? _resolver;
  int _readingRevision = 0;

  /// Bumped whenever previously built spans no longer match the readings.
  int get readingRevision => _readingRevision;

  set readingSpacing(PromptReadingSpacingResolver? resolver) {
    if (identical(_resolver, resolver)) return;
    _resolver = resolver;
    _readingRevision++;
    onReadingSpacingChanged();
  }

  /// Readings changed while the text did not: rebuild spans in the editor.
  void refreshReadingSpacing() {
    _readingRevision++;
    onReadingSpacingChanged();
    notifyListeners();
  }

  /// Hook for controllers that cache spans.
  @protected
  void onReadingSpacingChanged() {}

  /// Splits flat [spans] at the resolved offsets and widens those characters.
  @protected
  List<TextSpan> applyReadingSpacing(
    List<TextSpan> spans,
    TextStyle style,
    TextScaler scaler,
  ) {
    final spacing = _resolver?.call(text, style, scaler) ?? const {};
    if (spacing.isEmpty) return spans;
    final out = <TextSpan>[];
    var offset = 0;
    for (final span in spans) {
      final value = span.text;
      if (value == null || value.isEmpty) {
        out.add(span);
        continue;
      }
      var start = 0;
      for (var i = 0; i < value.length; i++) {
        final extra = spacing[offset + i];
        if (extra == null) continue;
        if (i > start) {
          out.add(TextSpan(text: value.substring(start, i), style: span.style));
        }
        final own = span.style ?? style;
        out.add(
          TextSpan(
            text: value[i],
            style: own.copyWith(
              letterSpacing:
                  (own.letterSpacing ?? style.letterSpacing ?? 0) + extra,
            ),
          ),
        );
        start = i + 1;
      }
      if (start == 0) {
        out.add(span);
      } else if (start < value.length) {
        out.add(TextSpan(text: value.substring(start), style: span.style));
      }
      offset += value.length;
    }
    return out;
  }
}

final _widths = <(String, TextStyle, double), double>{};

/// Single-line advance width, memoized per text, style and scale.
double promptReadingTextWidth(String text, TextStyle style, TextScaler scaler) {
  final key = (text, style, scaler.scale(100));
  if (_widths[key] case final width?) return width;
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  if (_widths.length > 4000) _widths.clear();
  return _widths[key] = width;
}
