import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../../core/autocomplete/completion_models.dart';
import '../../../../core/autocomplete/prompt_token_parser.dart';

typedef PromptCompletionSearch =
    Future<List<CompletionCandidate>> Function(CompletionQuery query);

enum PromptCompletionGroup { all, tags, characters, works }

/// One session per editable field. Search and preview never write the document;
/// only an explicit selection may replace the captured current tag.
class PromptCompletionController extends ChangeNotifier {
  PromptCompletionController({
    required this.editor,
    required this.focusNode,
    required this.search,
    required this.scope,
    required this.locale,
    this.onApplied,
    this.enabled = true,
    this.debounce = const Duration(milliseconds: 250),
  }) : _lastValue = editor.value {
    editor.addListener(_changed);
    focusNode.addListener(_focusChanged);
  }

  final TextEditingController editor;
  final FocusNode focusNode;
  final PromptCompletionSearch search;
  final String scope;
  final ValueChanged<String>? onApplied;
  final Duration debounce;
  String locale;
  bool enabled;
  Timer? _timer;
  int _sequence = 0;
  bool _disposed = false, _applying = false, _acceptWhenReady = false;
  TextEditingValue _lastValue;
  TextEditingValue? _snapshot;
  CompletionQuery? _query;
  List<CompletionCandidate> _candidates = const [];
  bool loading = false, failed = false;

  /// Rows of the previous keystroke stay visible (dimmed) until the next
  /// query answers, so the docked strip does not flash on every character.
  bool stale = false;

  /// The full list with category filters and Wiki preview. Collapsed by
  /// default; every new session starts as the compact strip.
  bool expanded = false;
  PromptCompletionGroup group = PromptCompletionGroup.all;
  int selectedIndex = 0;

  List<CompletionCandidate> get candidates => switch (group) {
    PromptCompletionGroup.all => [
      // Keep the group containing the strongest match first. Other groups
      // retain their internal search ordering and deterministic identity.
      for (final category
          in _candidates.map((c) => groupFor(c.category)).toSet())
        ..._candidates.where((c) => groupFor(c.category) == category),
    ],
    PromptCompletionGroup.tags =>
      _candidates
          .where(
            (c) =>
                c.category != TagCategory.character &&
                c.category != TagCategory.copyright,
          )
          .toList(growable: false),
    PromptCompletionGroup.characters =>
      _candidates
          .where((c) => c.category == TagCategory.character)
          .toList(growable: false),
    PromptCompletionGroup.works =>
      _candidates
          .where((c) => c.category == TagCategory.copyright)
          .toList(growable: false),
  };

  /// A first query stays hidden while it loads; an empty answer closes it.
  /// Only a filtered list keeps its frame so the filter can be changed back.
  bool get isOpen =>
      _candidates.isNotEmpty ||
      (_query != null && (failed || group != PromptCompletionGroup.all));

  /// Visible rows do not answer the current text yet.
  bool get pending => stale || loading;
  static PromptCompletionGroup groupFor(TagCategory category) =>
      switch (category) {
        TagCategory.character => PromptCompletionGroup.characters,
        TagCategory.copyright => PromptCompletionGroup.works,
        _ => PromptCompletionGroup.tags,
      };
  CompletionCandidate? get selected => candidates.isEmpty
      ? null
      : candidates[selectedIndex.clamp(0, candidates.length - 1)];

  void configure({required bool enabled, required String locale}) {
    if (this.enabled == enabled && this.locale == locale) return;
    this.enabled = enabled;
    this.locale = locale;
    dismiss();
  }

  void _focusChanged() {
    if (!focusNode.hasFocus) dismiss();
  }

  void _changed() {
    final value = editor.value;
    final prior = _lastValue;
    _lastValue = value;
    // Layout-only refreshes (reading spacing) notify with the same value.
    if (_applying || value == prior) return;
    if (!enabled ||
        !focusNode.hasFocus ||
        !value.selection.isValid ||
        !value.selection.isCollapsed ||
        (prior.text == value.text && prior.composing == value.composing)) {
      dismiss();
      return;
    }
    final composing = !value.composing.isCollapsed;
    final query = composing
        ? null
        : PromptTokenParser.parseCompletion(
            text: value.text,
            cursorPosition: value.selection.extentOffset,
            limit: 20,
            locale: locale,
          );
    if (!composing &&
        (query == null || (!query.isChinese && query.token.runes.length < 2))) {
      dismiss();
      return;
    }
    // Supersede the old query but keep its rows until fresh ones arrive.
    // IME composition only waits; it never searches uncommitted text.
    _sequence++;
    _timer?.cancel();
    _timer = null;
    _acceptWhenReady = false;
    loading = failed = false;
    stale = _candidates.isNotEmpty;
    _snapshot = composing ? null : value;
    _query = query?.copyWith(categoryFilter: _filter);
    if (_query case final next?) {
      final sequence = _sequence;
      _timer = Timer(debounce, () => _run(next, value, sequence));
    }
    notifyListeners();
  }

  Future<void> _run(
    CompletionQuery query,
    TextEditingValue value,
    int sequence,
  ) async {
    if (!_current(value, sequence)) return;
    loading = true;
    notifyListeners();
    try {
      final found = await search(query);
      if (!_current(value, sequence)) return;
      _candidates = found
          .where((c) => !c.isExisting)
          .take(query.limit)
          .toList(growable: false);
      failed = false;
    } catch (_) {
      if (!_current(value, sequence)) return;
      _candidates = const [];
      failed = true;
    }
    if (!_current(value, sequence)) return;
    selectedIndex = 0;
    loading = stale = false;
    notifyListeners();
    if (_acceptWhenReady) {
      _acceptWhenReady = false;
      if (!failed) apply();
    }
  }

  /// Enter/Tab while the rows on screen belong to older text: search now and
  /// accept the first fresh result rather than a row for a shorter prefix.
  void acceptWhenReady() {
    final query = _query, snapshot = _snapshot;
    if (query == null || snapshot == null) return;
    _acceptWhenReady = true;
    if (_timer?.isActive ?? false) {
      _timer!.cancel();
      _timer = null;
      unawaited(_run(query, snapshot, _sequence));
    }
  }

  bool _current(TextEditingValue value, int sequence) =>
      !_disposed &&
      enabled &&
      focusNode.hasFocus &&
      _sequence == sequence &&
      editor.value == value;

  void retry() {
    final query = _query, snapshot = _snapshot;
    if (query == null || snapshot == null) return;
    failed = false;
    unawaited(_run(query, snapshot, ++_sequence));
  }

  void setGroup(PromptCompletionGroup value) {
    if (group == value) return;
    group = value;
    selectedIndex = 0;
    final query = _query, snapshot = _snapshot;
    if (query == null || snapshot == null) return;
    _timer?.cancel();
    _query = query.copyWith(categoryFilter: _filter);
    _candidates = const [];
    failed = stale = false;
    unawaited(_run(_query!, snapshot, ++_sequence));
  }

  /// Collapsing returns to the unfiltered strip; filters belong to the list.
  void setExpanded(bool value) {
    if (expanded == value || (value && !isOpen)) return;
    expanded = value;
    notifyListeners();
    if (!value) setGroup(PromptCompletionGroup.all);
  }

  CompletionCategoryFilter get _filter => switch (group) {
    PromptCompletionGroup.all => CompletionCategoryFilter.all,
    PromptCompletionGroup.tags => CompletionCategoryFilter.tags,
    PromptCompletionGroup.characters => CompletionCategoryFilter.characters,
    PromptCompletionGroup.works => CompletionCategoryFilter.works,
  };

  void select(int index) {
    if (candidates.isEmpty) return;
    selectedIndex = index.clamp(0, candidates.length - 1);
    notifyListeners();
  }

  void move(int delta) {
    if (candidates.isEmpty) return;
    select((selectedIndex + delta) % candidates.length);
  }

  bool apply([CompletionCandidate? candidate]) {
    final query = _query, snapshot = _snapshot;
    final chosen = candidate ?? selected;
    if (query == null ||
        snapshot == null ||
        chosen == null ||
        !_current(snapshot, _sequence) ||
        !snapshot.composing.isCollapsed ||
        !_candidates.any((item) => item.stableId == chosen.stableId)) {
      dismiss();
      return false;
    }
    final result = PromptTokenParser.apply(
      text: snapshot.text,
      query: query,
      canonicalTag: chosen.canonicalTag,
      autoInsertComma: true,
    );
    dismiss();
    _applying = true;
    try {
      editor.value = TextEditingValue(
        text: result.text,
        selection: TextSelection.collapsed(offset: result.cursorPosition),
      );
      onApplied?.call(result.text);
    } finally {
      _applying = false;
    }
    return true;
  }

  void dismiss() {
    _sequence++;
    _timer?.cancel();
    _timer = null;
    final hadState = isOpen || expanded;
    _snapshot = null;
    _query = null;
    _candidates = const [];
    loading = failed = stale = expanded = _acceptWhenReady = false;
    group = PromptCompletionGroup.all;
    selectedIndex = 0;
    if (hadState && !_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    dismiss();
    editor.removeListener(_changed);
    focusNode.removeListener(_focusChanged);
    super.dispose();
  }
}
