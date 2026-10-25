import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nai_launcher/core/wiki/auto_tag_translation_controller.dart';
import 'package:nai_launcher/presentation/widgets/prompt/reading/prompt_completion_controller.dart';
import 'package:nai_launcher/presentation/widgets/prompt/reading/prompt_completion_wrapper.dart';

/// Shared input-display substitutes. A mounted input must never initialize the
/// runtime tag database, persisted translation cache, or an actual model in a
/// widget test that is only checking editor/layout behavior.
List<Override> promptReadingTestOverrides({
  PromptReadingTestController? readings,
  PromptCompletionSearch? search,
}) => [
  autoTagTranslationProvider.overrideWith(
    (ref) => readings ?? PromptReadingTestController(),
  ),
  promptCompletionSearchProvider.overrideWithValue(search ?? (_) async => []),
];

class PromptReadingTestController extends ChangeNotifier
    implements AutoTagTranslationController {
  final names = <String, String>{};
  final surfaces = <String, Set<String>>{};
  final requests = <String>[];

  Set<String> get visible => {for (final tags in surfaces.values) ...tags};
  @override
  String? nameFor(String tag) => names[tag];
  @override
  bool get enabled => false;
  @override
  int get activeRequests => 0;
  @override
  void observeNames({required String surface, required Iterable<String> tags}) {
    surfaces[surface] = tags.toSet();
  }

  @override
  void observe({
    required String surface,
    required String tag,
    required bool visible,
    String? existingNameZh,
    AutoTagTranslationContext? tagContext,
    TagReadingIntent intent = TagReadingIntent.details,
  }) {
    final tags = surfaces.putIfAbsent(surface, () => {});
    if (visible) {
      tags.add(tag);
    } else {
      tags.remove(tag);
    }
  }

  @override
  void requestMissingNames({required String surface}) => requests.add(surface);
  @override
  void clearSurface(String surface) => surfaces.remove(surface);

  final phrases = <String, String>{};
  final phraseSurfaces = <String, Set<String>>{};
  @override
  String? phraseFor(String text) =>
      phrases[AutoTagTranslationController.phraseKey(text)];
  @override
  void observePhrases({
    required String surface,
    required Iterable<String> phrases,
  }) {
    phraseSurfaces[surface] = phrases.toSet();
  }

  void reveal(Map<String, String> values) {
    names.addAll(values);
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
