import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/autocomplete/prompt_token_parser.dart';
import '../../../../core/wiki/auto_tag_translation_controller.dart';
import 'prompt_reading_spacing.dart';

typedef PromptAnnotationRange = ({int start, int end, String tag});

/// Paints readings over the actual editable geometry. Source text, selection,
/// composing ranges, undo history and inline manual blocks stay editor-owned.
///
/// Readings hang just under the baseline, in the lower half of an evenly
/// distributed line. When the controller is a [PromptReadingSpacingHost], a
/// reading wider than its tag pushes the next word right, so readings are
/// never clipped to the width of short tags.
class PromptReadingLayer extends ConsumerStatefulWidget {
  const PromptReadingLayer({
    super.key,
    required this.controller,
    required this.enabled,
    required this.sourceStyle,
    required this.style,
    required this.child,
  });

  final TextEditingController controller;
  final bool enabled;
  final TextStyle sourceStyle;
  final TextStyle style;
  final Widget child;

  /// Source line height (with even leading) that leaves room for one reading
  /// line under every source line, without adding text or spans.
  static const lineHeight = 2.0;

  /// Readings never touch the next one on the same line.
  static const _readingGap = 4.0;

  @override
  ConsumerState<PromptReadingLayer> createState() => PromptReadingLayerState();
}

class PromptReadingLayerState extends ConsumerState<PromptReadingLayer> {
  late final String _surface = 'prompt-reading-${identityHashCode(this)}';
  AutoTagTranslationController? _readings;
  List<PromptAnnotationRange> _ranges = const [];
  String _text = '';
  TextRange _composing = TextRange.empty;
  Set<String> _visible = {};
  int _visibilityRevision = 0;
  int? _appliedSpacing;
  bool _spacingCheckScheduled = false;
  (TextStyle, TextStyle, TextScaler)? _insetKey;
  double _bottomInset = 0;

  /// Intermediate readings can use the next line's upper leading. The final
  /// reading needs that same room reserved after the editable instead.
  double _trailingInset(TextScaler scaler) {
    if (!widget.enabled) return 0;
    final key = (widget.sourceStyle, widget.style, scaler);
    if (_insetKey == key) return _bottomInset;
    final source = TextPainter(
      text: TextSpan(text: 'Hg', style: widget.sourceStyle),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final reading = TextPainter(
      text: TextSpan(text: 'Hg', style: widget.style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final descent = source.computeLineMetrics().first.descent;
    _bottomInset = math.max(
      0,
      scaler.scale(widget.sourceStyle.fontSize ?? 14) * .22 +
          reading.height -
          descent,
    );
    source.dispose();
    reading.dispose();
    _insetKey = key;
    return _bottomInset;
  }

  void requestMissingNames() =>
      _readings?.requestMissingNames(surface: _surface);

  @override
  void initState() {
    super.initState();
    _readText();
    widget.controller.addListener(_changed);
    _attachSpacing(widget.controller);
  }

  void _readText() {
    final value = widget.controller.value;
    if (_text != value.text || _ranges.isEmpty) {
      _text = value.text;
      _ranges = PromptTokenParser.annotationRanges(_text);
    }
    _composing = value.composing;
  }

  void _changed() {
    final value = widget.controller.value;
    if (value.text == _text && value.composing == _composing) return;
    setState(_readText);
  }

  void _attachSpacing(TextEditingController controller) {
    if (controller case final PromptReadingSpacingHost host) {
      host.readingSpacing = _spacing;
    }
  }

  void _detachSpacing(TextEditingController controller) {
    if (controller case final PromptReadingSpacingHost host) {
      host.readingSpacing = null;
    }
  }

  /// Tags and names that decide the spacing of [text]; equal signatures mean
  /// the spans already built for the editor are still right.
  int _spacingSignature(String text) {
    final readings = _readings;
    if (!widget.enabled || readings == null) return 0;
    final ranges = text == _text
        ? _ranges
        : PromptTokenParser.annotationRanges(text);
    return Object.hash(
      text,
      Object.hashAll([
        for (final range in ranges)
          if (readings.nameFor(range.tag) case final String name
              when name.isNotEmpty)
            (range.start, name),
      ]),
    );
  }

  Map<int, double> _spacing(String text, TextStyle style, TextScaler scaler) {
    _appliedSpacing = _spacingSignature(text);
    final readings = _readings;
    if (!widget.enabled || readings == null) return const {};
    final ranges = text == _text
        ? _ranges
        : PromptTokenParser.annotationRanges(text);
    final out = <int, double>{};
    for (final range in ranges) {
      final name = readings.nameFor(range.tag);
      if (name == null || name.isEmpty) continue;
      // Reserve room up to the separator, so closing weight syntax and the
      // budget stay one unbreakable run with the tag.
      var end = range.end;
      while (end < text.length && !_separator(text.codeUnitAt(end))) {
        end++;
      }
      while (end > range.end && _space(text.codeUnitAt(end - 1))) {
        end--;
      }
      final separator = _gapAfter(text, end);
      // Line ends need no push: the reading overhangs blank space there.
      if (separator == null) continue;
      // Widen the comma itself: it stays attached to the tag, the gap opens
      // after it, and the tag with its budget still breaks as one word.
      final comma = separator.indexOf(_comma);
      final at = comma < 0 ? end - 1 : end + comma;
      final unit = text.codeUnitAt(at);
      if (unit >= 0xD800 && unit <= 0xDFFF) continue;
      final extra =
          promptReadingTextWidth(name, widget.style, scaler) +
          PromptReadingLayer._readingGap -
          promptReadingTextWidth(
            text.substring(range.start, end),
            style,
            scaler,
          ) -
          promptReadingTextWidth(separator, style, scaler);
      if (extra > .5) out[at] = extra;
    }
    return out;
  }

  /// The separator text that already follows a tag, such as ", ", or null
  /// when nothing follows on the same line.
  static String? _gapAfter(String text, int end) {
    var i = end;
    while (i < text.length &&
        (_space(text.codeUnitAt(i)) ||
            text.codeUnitAt(i) == 0x2C ||
            text.codeUnitAt(i) == 0xFF0C)) {
      i++;
    }
    if (i == text.length || text.codeUnitAt(i) == 0x0A) return null;
    return text.substring(end, i);
  }

  static final _comma = RegExp('[,\uFF0C]');

  static bool _separator(int unit) =>
      unit == 0x2C || unit == 0xFF0C || unit == 0x0A || unit == 0x7C;

  static bool _space(int unit) => unit == 0x20 || unit == 0x09;

  /// Names arrive asynchronously; rebuild the editor spans once they differ
  /// from what the last span build reserved room for.
  void _scheduleSpacingCheck() {
    if (_spacingCheckScheduled) return;
    if (widget.controller is! PromptReadingSpacingHost) return;
    _spacingCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _spacingCheckScheduled = false;
      if (!mounted) return;
      final controller = widget.controller;
      if (controller is PromptReadingSpacingHost &&
          _spacingSignature(controller.text) != _appliedSpacing) {
        controller.refreshReadingSpacing();
      }
    });
  }

  @override
  void didUpdateWidget(PromptReadingLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      _detachSpacing(oldWidget.controller);
      widget.controller.addListener(_changed);
      _attachSpacing(widget.controller);
      _readText();
    }
    if (!widget.enabled && oldWidget.enabled) _updateVisible({});
  }

  void _updateVisible(Set<String> tags) {
    if (setEquals(tags, _visible)) return;
    _visible = tags;
    final revision = ++_visibilityRevision;
    // Render geometry is available during paint; never notify providers there.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _visibilityRevision) return;
      _readings?.observeNames(surface: _surface, tags: _visible);
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _detachSpacing(widget.controller);
    _readings?.clearSurface(_surface);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _readings = ref.watch(autoTagTranslationProvider);
    _scheduleSpacingCheck();
    final ancestorOffsets = <ViewportOffset>[];
    context.visitAncestorElements((element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        ancestorOffsets.add((element.state as ScrollableState).position);
      }
      return true;
    });
    final ranges = widget.enabled
        ? _ranges
              .where(
                (range) =>
                    !_composing.isValid ||
                    _composing.isCollapsed ||
                    range.end <= _composing.start ||
                    range.start >= _composing.end,
              )
              .toList()
        : const <PromptAnnotationRange>[];
    final scaler = MediaQuery.textScalerOf(context);
    final bottomInset = _trailingInset(scaler);
    return _ReadingPaint(
      ranges: ranges,
      names: {
        for (final range in ranges)
          if (_readings!.nameFor(range.tag) case final String name)
            range.tag: name,
      },
      style: widget.style,
      scaler: scaler,
      bottomInset: bottomInset,
      direction: Directionality.of(context),
      ancestorOffsets: ancestorOffsets,
      onVisible: _updateVisible,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: widget.child,
      ),
    );
  }
}

class _ReadingPaint extends SingleChildRenderObjectWidget {
  const _ReadingPaint({
    required this.ranges,
    required this.names,
    required this.style,
    required this.scaler,
    required this.bottomInset,
    required this.direction,
    required this.ancestorOffsets,
    required this.onVisible,
    required super.child,
  });

  final List<PromptAnnotationRange> ranges;
  final Map<String, String> names;
  final TextStyle style;
  final TextScaler scaler;
  final double bottomInset;
  final TextDirection direction;
  final List<ViewportOffset> ancestorOffsets;
  final ValueChanged<Set<String>> onVisible;

  @override
  _RenderReadings createRenderObject(BuildContext context) =>
      _RenderReadings(this);

  @override
  void updateRenderObject(BuildContext context, _RenderReadings renderObject) {
    renderObject.configuration = this;
  }
}

class _RenderReadings extends RenderProxyBox {
  _RenderReadings(this._configuration);
  _ReadingPaint _configuration;
  final _scrollOffsets = <ViewportOffset>{};
  int? _metricsKey;
  double _descent = 0;

  void _watchScroll(RenderEditable? editable) {
    final next = <ViewportOffset>{
      if (editable != null) ...[
        editable.offset,
        ..._configuration.ancestorOffsets,
      ],
    };
    for (final offset in _scrollOffsets.difference(next)) {
      offset.removeListener(markNeedsPaint);
    }
    for (final offset in next.difference(_scrollOffsets)) {
      offset.addListener(markNeedsPaint);
    }
    _scrollOffsets
      ..clear()
      ..addAll(next);
  }

  @override
  void detach() {
    _watchScroll(null);
    super.detach();
  }

  set configuration(_ReadingPaint value) {
    _configuration = value;
    markNeedsPaint();
  }

  RenderEditable? _findEditable(RenderObject object) {
    if (object is RenderEditable) return object;
    RenderEditable? found;
    object.visitChildren((child) => found ??= _findEditable(child));
    return found;
  }

  /// Distance from a source line's box bottom up to its baseline. A tight
  /// selection box spans the run's height-scaled ascent and descent, so this
  /// holds even on lines that a taller manual block makes taller.
  double _lineDescent(RenderEditable editable) {
    final style = editable.text?.style;
    final scaler = editable.textScaler;
    final key = Object.hash(
      style,
      scaler.scale(100),
      editable.textHeightBehavior,
    );
    if (key == _metricsKey) return _descent;
    final painter = TextPainter(
      text: TextSpan(text: 'Hg', style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      textHeightBehavior: editable.textHeightBehavior,
      maxLines: 1,
    )..layout();
    final metrics = painter.computeLineMetrics();
    _descent = metrics.isEmpty ? 0 : metrics.first.descent;
    painter.dispose();
    _metricsKey = key;
    return _descent;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final config = _configuration;
    final editable = _findEditable(this);
    // EditableText repaints inside its own boundary while scrolling. The
    // annotation ancestor must repaint as well to track the same viewport.
    _watchScroll(editable);
    final visible = <String>{};
    if (editable == null || !editable.hasSize || config.ranges.isEmpty) {
      config.onVisible(visible);
      return;
    }
    final transform = editable.getTransformTo(this);
    var viewport = MatrixUtils.transformRect(
      transform,
      Offset.zero & editable.size,
    ).intersect(Offset.zero & size);
    var readingViewport = Rect.fromLTRB(
      viewport.left,
      viewport.top,
      viewport.right,
      viewport.bottom + config.bottomInset,
    ).intersect(Offset.zero & size);
    // Auto-growing prompt fields scroll in an outer viewport. Their own
    // RenderEditable is as tall as the entire document, so it cannot define
    // visibility by itself. Intersect every enclosing scrolling viewport.
    for (
      RenderObject? ancestor = parent;
      ancestor != null;
      ancestor = ancestor.parent
    ) {
      if (ancestor is! RenderAbstractViewport || ancestor is! RenderBox) {
        continue;
      }
      final inverse = Matrix4.tryInvert(getTransformTo(ancestor));
      if (inverse == null) continue;
      final ancestorViewport = MatrixUtils.transformRect(
        inverse,
        Offset.zero & (ancestor as RenderBox).size,
      );
      viewport = viewport.intersect(ancestorViewport);
      readingViewport = readingViewport.intersect(ancestorViewport);
    }
    if (viewport.isEmpty) {
      config.onVisible(visible);
      return;
    }
    final first = editable
        .getPositionForPoint(localToGlobal(viewport.topLeft))
        .offset;
    final last = editable
        .getPositionForPoint(localToGlobal(viewport.bottomRight))
        .offset;
    final descent = _lineDescent(editable);
    final sourceSize = config.scaler.scale(
      editable.text?.style?.fontSize ?? 14,
    );
    final canvas = context.canvas;
    canvas.save();
    // Include the reserved final-line room, but never extend an ancestor's
    // scrolling viewport into the next panel.
    canvas.clipRect(readingViewport.shift(offset));
    var lineTop = double.nan, lineRight = double.negativeInfinity;
    for (final range in config.ranges) {
      if (range.end < math.min(first, last) ||
          range.start > math.max(first, last)) {
        continue;
      }
      final rects = editable
          .getBoxesForSelection(
            TextSelection(baseOffset: range.start, extentOffset: range.end),
          )
          .map((box) => MatrixUtils.transformRect(transform, box.toRect()))
          .where((rect) => rect.overlaps(viewport) && rect.width > 1)
          .toList();
      if (rects.isEmpty) continue;
      visible.add(range.tag);
      final name = config.names[range.tag];
      if (name == null || name.isEmpty) continue;
      final painter = TextPainter(
        text: TextSpan(text: name, style: config.style),
        textDirection: config.direction,
        textScaler: config.scaler,
        maxLines: 1,
      )..layout();
      // A tag wrapped across lines reads from its first fragment when the
      // reading fits there, otherwise from the fragment that ends the tag.
      final rect =
          rects.length == 1 ||
              rects.first.left + painter.width <= viewport.right
          ? rects.first
          : rects.last;
      final top = rect.bottom - descent + sourceSize * .22;
      if (top != lineTop) {
        lineTop = top;
        lineRight = double.negativeInfinity;
      }
      // Spacing already reserves the room; this only guards the frame before
      // fresh spans arrive and controllers that cannot reserve room.
      var x = math.max(rect.left, lineRight + PromptReadingLayer._readingGap);
      if (x + painter.width > viewport.right) {
        x = math.max(
          math.max(viewport.left, viewport.right - painter.width),
          lineRight + PromptReadingLayer._readingGap,
        );
      }
      final room = viewport.right - x;
      if (painter.width > room) {
        // Only a reading wider than the remaining line is shortened.
        painter.dispose();
        if (room < config.scaler.scale(config.style.fontSize ?? 10)) continue;
        final short = TextPainter(
          text: TextSpan(text: name, style: config.style),
          textDirection: config.direction,
          textScaler: config.scaler,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: room);
        short.paint(canvas, offset + Offset(x, top));
        lineRight = x + short.width;
        short.dispose();
        continue;
      }
      painter.paint(canvas, offset + Offset(x, top));
      lineRight = x + painter.width;
      painter.dispose();
    }
    canvas.restore();
    config.onVisible(visible);
  }
}
