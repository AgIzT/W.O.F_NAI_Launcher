import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/autocomplete/completion_models.dart';
import '../../../../core/tag_expansion/tag_expansion_providers.dart';
import '../../../../core/wiki/auto_tag_translation_controller.dart';
import 'prompt_completion_controller.dart';
import 'prompt_completion_strip.dart';

final promptCompletionSearchProvider = Provider<PromptCompletionSearch>(
  (ref) =>
      (query) => ref
          .read(localTagExpansionServiceProvider)
          .search(
            query.token,
            locale: query.locale,
            existingTags: query.existingTags,
            limit: query.limit,
            categoryFilter: query.categoryFilter,
          ),
);

typedef _Placement = ({
  Alignment target,
  Alignment follower,
  Offset offset,
  double width,
  double maxHeight,
});

/// Optional input completion for prompt editors. The child remains the native
/// editable field; this wrapper docks a candidate strip to the editor's edge
/// and opens the full list or Wiki preview only on request.
class PromptCompletionWrapper extends ConsumerStatefulWidget {
  const PromptCompletionWrapper({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.scope,
    required this.child,
    this.onApplied,
    this.enabled = true,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final String scope;
  final Widget child;
  final ValueChanged<String>? onApplied;
  final bool enabled;

  @override
  ConsumerState<PromptCompletionWrapper> createState() =>
      _PromptCompletionWrapperState();
}

class _PromptCompletionWrapperState
    extends ConsumerState<PromptCompletionWrapper>
    with WidgetsBindingObserver {
  static const _gap = 3.0, _margin = 8.0, _panelHeight = 360.0;

  final _anchor = GlobalKey();
  final _link = LayerLink();
  final _scroll = ScrollController();
  final _rowKeys = <String, GlobalKey>{};
  final _editorScrollPositions = <ScrollPosition>{};
  late PromptCompletionController _session;
  KeyEventResult Function(FocusNode, KeyEvent)? _previousKeyHandler;
  late final KeyEventResult Function(FocusNode, KeyEvent) _keyHandler = _onKey;
  AutoTagTranslationController? _translations;
  OverlayEntry? _overlay;
  CompletionCandidate? _preview;
  _Placement? _placement;
  bool _expandedShown = false;
  bool _visibleScheduled = false, _placementScheduled = false;
  late String _surface;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_scheduleVisible);
    _createSession();
  }

  void _createSession() {
    _surface = 'prompt-completion:${widget.scope}:${identityHashCode(this)}';
    _session = PromptCompletionController(
      editor: widget.controller,
      focusNode: widget.focusNode,
      scope: widget.scope,
      locale: 'en',
      enabled: widget.enabled,
      search: (query) => ref.read(promptCompletionSearchProvider)(query),
      onApplied: (text) => widget.onApplied?.call(text),
    )..addListener(_changed);
    _previousKeyHandler = widget.focusNode.onKeyEvent;
    widget.focusNode.onKeyEvent = _keyHandler;
  }

  void _releaseSession(FocusNode focusNode) {
    if (focusNode.onKeyEvent == _keyHandler) {
      focusNode.onKeyEvent = _previousKeyHandler;
    }
    _session.removeListener(_changed);
    _session.dispose();
    for (final position in _editorScrollPositions) {
      position.removeListener(_schedulePlacement);
    }
    _editorScrollPositions.clear();
    _removeOverlay();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _session.configure(
      enabled: widget.enabled,
      locale: Localizations.localeOf(context).toLanguageTag(),
    );
  }

  @override
  void didUpdateWidget(covariant PromptCompletionWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.focusNode != widget.focusNode ||
        oldWidget.scope != widget.scope) {
      _releaseSession(oldWidget.focusNode);
      _createSession();
    }
    _session.configure(
      enabled: widget.enabled,
      locale: Localizations.localeOf(context).toLanguageTag(),
    );
  }

  @override
  void didChangeMetrics() => _session.dismiss();

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // Keys belong to the editor unless the user can actually see the rows.
    if (_session.isOpen &&
        _placement != null &&
        widget.focusNode.hasFocus &&
        widget.controller.value.composing.isCollapsed &&
        (event is KeyDownEvent || event is KeyRepeatEvent)) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.escape) {
        if (_preview != null) {
          _closePreview();
        } else if (_session.expanded) {
          _session.setExpanded(false);
        } else {
          _session.dismiss();
        }
        return KeyEventResult.handled;
      }
      if (!HardwareKeyboard.instance.isControlPressed &&
          !HardwareKeyboard.instance.isMetaPressed &&
          !HardwareKeyboard.instance.isAltPressed &&
          !HardwareKeyboard.instance.isShiftPressed) {
        if (_preview == null &&
            (key == LogicalKeyboardKey.arrowDown ||
                key == LogicalKeyboardKey.arrowUp)) {
          _session.move(key == LogicalKeyboardKey.arrowDown ? 1 : -1);
          _ensureSelectedVisible();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.tab) {
          if (_session.pending) {
            if (event is KeyDownEvent) _session.acceptWhenReady();
            return KeyEventResult.handled;
          }
          if (_session.selected != null) {
            if (event is KeyDownEvent) _session.apply(_preview);
            return KeyEventResult.handled;
          }
        }
      }
    }
    return _previousKeyHandler?.call(node, event) ?? KeyEventResult.ignored;
  }

  void _changed() {
    if (!_session.isOpen) {
      _removeOverlay();
      return;
    }
    if (_expandedShown != _session.expanded) {
      // Strip chips and list rows are different widgets; never share keys.
      _expandedShown = _session.expanded;
      _rowKeys.clear();
      _preview = null;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
    final tags = _session.candidates.map((c) => c.stableId).toSet();
    // A preview belongs to the completed query, even while its old rows are
    // retained during typing. Do not let it accept a stale tag for new text.
    if (_preview != null &&
        (_session.pending || !tags.contains(_preview!.stableId))) {
      _preview = null;
    }
    if (_translations == null) {
      final translations = ref.read(autoTagTranslationProvider);
      _translations = translations;
      translations.addListener(_translationChanged);
    }
    if (_overlay == null) {
      _overlay = OverlayEntry(builder: _buildOverlay);
      Overlay.of(context).insert(_overlay!);
    } else {
      _overlay!.markNeedsBuild();
    }
    _scheduleVisible();
    _trackEditorScroll();
  }

  void _trackEditorScroll() {
    final anchor = _anchor.currentContext;
    if (anchor is! Element) return;
    final positions = <ScrollPosition>{};
    void inspect(Element element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        positions.add((element.state as ScrollableState).position);
      }
    }

    anchor.visitAncestorElements((element) {
      inspect(element);
      return true;
    });
    void visit(Element element) {
      inspect(element);
      element.visitChildren(visit);
    }

    visit(anchor);
    for (final prior in _editorScrollPositions.difference(positions)) {
      prior.removeListener(_schedulePlacement);
    }
    for (final position in positions.difference(_editorScrollPositions)) {
      position.addListener(_schedulePlacement);
    }
    _editorScrollPositions
      ..clear()
      ..addAll(positions);
  }

  void _translationChanged() => _overlay?.markNeedsBuild();

  void _removeOverlay() {
    _overlay?.remove();
    _overlay?.dispose();
    _overlay = null;
    _placement = null;
    _preview = null;
    _expandedShown = false;
    _rowKeys.clear();
    _translations?.clearSurface(_surface);
  }

  void _openPreview(CompletionCandidate candidate) {
    _session.setExpanded(true);
    _preview = candidate;
    _translations?.clearSurface(_surface);
    _overlay?.markNeedsBuild();
  }

  void _closePreview() {
    _preview = null;
    _overlay?.markNeedsBuild();
    _scheduleVisible();
  }

  void _scheduleVisible() {
    if (_visibleScheduled || _overlay == null) return;
    _visibleScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibleScheduled = false;
      if (!mounted || _overlay == null || _preview != null) return;
      final visible = <String>[];
      for (final candidate in _session.candidates) {
        final box = _rowKeys[candidate.stableId]?.currentContext
            ?.findRenderObject();
        if (box is! RenderBox || !box.attached || !box.hasSize) continue;
        // The strip scrolls sideways and the list vertically; test both axes.
        if (RenderAbstractViewport.maybeOf(box) case final RenderBox port) {
          final rect = MatrixUtils.transformRect(
            box.getTransformTo(port),
            Offset.zero & box.size,
          );
          if (rect.overlaps(Offset.zero & port.size)) {
            visible.add(candidate.canonicalTag);
          }
        }
      }
      _translations?.observeNames(surface: _surface, tags: visible);
      final visibleTags = visible.toSet();
      for (final candidate in _session.candidates) {
        if (!visibleTags.contains(candidate.canonicalTag)) continue;
        _translations?.observe(
          surface: _surface,
          tag: candidate.canonicalTag,
          visible: true,
          existingNameZh: candidate.translation,
          intent: TagReadingIntent.nameOnly,
          tagContext: AutoTagTranslationContext(
            category: candidate.category.name,
            aliases: candidate.aliases,
            postCount: candidate.postCount,
          ),
        );
      }
    });
  }

  void _ensureSelectedVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _rowKeys[_session.selected?.stableId]?.currentContext;
      if (target != null) Scrollable.ensureVisible(target, alignment: .5);
    });
  }

  /// The follower layer tracks the editor while it scrolls or grows. Which
  /// edge it docks to depends on clipping, so re-check after each layout.
  void _schedulePlacement() {
    if (_placementScheduled || _overlay == null) return;
    _placementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _placementScheduled = false;
      if (!mounted || _overlay == null) return;
      final box = Overlay.maybeOf(context)?.context.findRenderObject();
      if (box is RenderBox && box.hasSize && _place(box) != _placement) {
        _overlay!.markNeedsBuild();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  RenderEditable? _editable() {
    RenderEditable? editable;
    void visit(Element element) {
      if (editable != null) return;
      if (element.renderObject case final RenderEditable render) {
        editable = render;
      } else {
        element.visitChildren(visit);
      }
    }

    if (_anchor.currentContext case final Element anchor) visit(anchor);
    return editable != null && editable!.attached ? editable : null;
  }

  Rect? _caret(RenderBox overlayBox, int offset) {
    final field = _editable();
    if (field == null || offset < 0) return null;
    return MatrixUtils.transformRect(
      field.getTransformTo(overlayBox),
      field.getLocalRectForCaret(TextPosition(offset: offset)),
    );
  }

  /// Bottom of the last text line, including the reading reserved under it.
  double? _textBottom(RenderBox overlayBox) {
    final field = _editable();
    final length = widget.controller.text.length;
    if (field == null || length == 0) return null;
    final boxes = field.getBoxesForSelection(
      TextSelection(baseOffset: length - 1, extentOffset: length),
    );
    final local = boxes.isEmpty
        ? field.getLocalRectForCaret(TextPosition(offset: length))
        : boxes.last.toRect();
    return MatrixUtils.transformRect(
      field.getTransformTo(overlayBox),
      local,
    ).bottom;
  }

  /// Docks to the editor's bottom edge: inside it when the text leaves blank
  /// lines there (prompt cards reserve several), otherwise just below it.
  /// Flips above when there is no room, and only overlaps text when the
  /// editor fills the whole view — then on the edge away from the caret.
  _Placement? _place(RenderBox overlayBox) {
    final anchor = _anchor.currentContext?.findRenderObject();
    if (anchor is! RenderBox || !anchor.attached || !anchor.hasSize) {
      return null;
    }
    final size = overlayBox.size;
    final rect = MatrixUtils.transformRect(
      anchor.getTransformTo(overlayBox),
      Offset.zero & anchor.size,
    );
    var visible = rect.intersect(Offset.zero & size);
    for (
      RenderObject? node = anchor.parent;
      node != null && node != overlayBox;
      node = node.parent
    ) {
      if (node is RenderBox && node is RenderAbstractViewport) {
        visible = visible.intersect(
          MatrixUtils.transformRect(
            node.getTransformTo(overlayBox),
            Offset.zero & node.size,
          ),
        );
      }
    }
    if (visible.width <= 0 || visible.height <= 0) return null;
    final expanded = _session.expanded;
    final width = math.max(
      0.0,
      math.min(
        size.width - 2 * _margin,
        expanded
            ? visible.width.clamp(360.0, 520.0)
            : math.max(visible.width, 320.0),
      ),
    );
    final left = visible.left.clamp(
      _margin,
      math.max(_margin, size.width - width - _margin),
    );
    final dx = left - rect.left;
    const strip = PromptCompletionStrip.height;
    final need = expanded
        ? PromptCompletionPanel.minimumHeight(context)
        : strip;
    final below = size.height - _margin - visible.bottom - _gap;
    final above = visible.top - _margin - _gap;
    final bottomShown = rect.bottom <= visible.bottom + .5;
    final topShown = rect.top >= visible.top - .5;
    _Placement dockBelow() => (
      target: Alignment.bottomLeft,
      follower: Alignment.topLeft,
      offset: Offset(dx, _gap),
      width: width,
      maxHeight: math.min(_panelHeight, below),
    );
    _Placement dockAbove() => (
      target: Alignment.topLeft,
      follower: Alignment.bottomLeft,
      offset: Offset(dx, -_gap),
      width: width,
      maxHeight: math.min(_panelHeight, above),
    );
    final textEnd = _textBottom(overlayBox);
    if (!expanded &&
        bottomShown &&
        width <= visible.width &&
        textEnd != null &&
        textEnd + strip + 2 * _gap <= rect.bottom) {
      return (
        target: Alignment.bottomLeft,
        follower: Alignment.bottomLeft,
        offset: Offset(dx, -_gap),
        width: width,
        maxHeight: strip,
      );
    }
    if (bottomShown && below >= need) return dockBelow();
    if (topShown && above >= need) return dockAbove();
    final room = visible.height - 2 * _gap;
    // Expanded content needs more than a strip's height. Prefer the editor's
    // interior over a narrow external slot, then the largest remaining area.
    if (!expanded || room < need) {
      if (bottomShown &&
          below >= strip &&
          (!topShown || below >= above) &&
          (!expanded || below >= room)) {
        return dockBelow();
      }
      if (topShown && above >= strip && (!expanded || above >= room)) {
        return dockAbove();
      }
    }
    if (room < strip) return null;
    final selection = widget.controller.selection;
    final caret = selection.isValid
        ? _caret(overlayBox, selection.extentOffset)
        : null;
    final atTop = caret != null && caret.center.dy > visible.center.dy;
    return (
      target: Alignment.topLeft,
      follower: atTop ? Alignment.topLeft : Alignment.bottomLeft,
      offset: Offset(
        dx,
        (atTop ? visible.top + _gap : visible.bottom - _gap) - rect.top,
      ),
      width: width,
      maxHeight: math.min(_panelHeight, room),
    );
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final box = Overlay.of(context).context.findRenderObject();
    final placement = _placement = box is RenderBox && box.hasSize
        ? _place(box)
        : null;
    _schedulePlacement();
    if (placement == null) return const SizedBox.shrink();
    String? nameFor(String tag) => _translations?.nameFor(tag);
    GlobalKey rowKey(String id) => _rowKeys.putIfAbsent(id, GlobalKey.new);
    return Positioned(
      left: 0,
      top: 0,
      width: placement.width,
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        targetAnchor: placement.target,
        followerAnchor: placement.follower,
        offset: placement.offset,
        child: UncontrolledProviderScope(
          container: ProviderScope.containerOf(context),
          child: TextFieldTapRegion(
            child: TapRegion(
              onTapOutside: (_) => _session.dismiss(),
              child: ExcludeFocus(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: placement.maxHeight),
                  child: _session.expanded
                      ? PromptCompletionPanel(
                          session: _session,
                          nameFor: nameFor,
                          rowKey: rowKey,
                          scroll: _scroll,
                          preview: _preview,
                          onPreview: _openPreview,
                          onClosePreview: _closePreview,
                        )
                      : PromptCompletionStrip(
                          session: _session,
                          nameFor: nameFor,
                          rowKey: rowKey,
                          scroll: _scroll,
                          onPreview: _openPreview,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: (_) {
          _schedulePlacement();
          return false;
        },
        child: CompositedTransformTarget(
          link: _link,
          child: SizedBox(key: _anchor, child: widget.child),
        ),
      );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _releaseSession(widget.focusNode);
    _translations?.removeListener(_translationChanged);
    _scroll.dispose();
    super.dispose();
  }
}
