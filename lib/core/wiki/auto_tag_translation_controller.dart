import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../presentation/prompt_assistant/services/prompt_assistant_service.dart';
import '../../presentation/prompt_assistant/services/prompt_assistant_api_client.dart';
import '../../presentation/prompt_assistant/providers/prompt_assistant_config_provider.dart';
import '../../presentation/prompt_assistant/models/prompt_assistant_models.dart';
import '../../presentation/providers/locale_provider.dart';
import '../utils/prompt_translation_language.dart';
import '../utils/tag_normalizer.dart';
import 'tag_wiki_repository.dart';
import 'visible_tag_translation_cache.dart';
import 'wiki_tag_links.dart';
import '../utils/localization_extension.dart';
import '../utils/fatal_diagnostics.dart';
import '../tag_expansion/tag_semantics_repository.dart';
import '../tag_expansion/tag_semantics_store.dart';
import '../database/dictionary_revision.dart';

final autoTagTranslationProvider =
    ChangeNotifierProvider<AutoTagTranslationController>((ref) {
      final controller = AutoTagTranslationController(
        assistant: ref.read(promptAssistantServiceProvider),
        wiki: ref.read(tagWikiRepositoryProvider),
        cache: ref.read(visibleTagTranslationCacheProvider),
        closeCacheOnDispose: false,
        semantics: ref.read(tagSemanticsRepositoryProvider),
        semanticStore: ref.read(tagSemanticsStoreProvider),
        wikiLinks: ref.read(wikiTagLinksProvider),
        readingLanguage: () => ref
            .read(promptAssistantServiceProvider)
            .targetLanguageFor(LauncherInterface.tagTranslate),
        wikiReadingLanguage: () => ref
            .read(promptAssistantServiceProvider)
            .targetLanguageFor(LauncherInterface.wikiTranslate),
      );
      ref.listen(promptAssistantConfigProvider, (_, __) {
        controller.routeChanged();
      });
      ref.listen(localeNotifierProvider, (_, __) => controller.routeChanged());
      ref.listen(
        dictionaryRevisionProvider,
        (_, __) => controller.routeChanged(),
      );
      unawaited(controller.loadPreference());
      return controller;
    });

enum TagTranslationPhase { queued, translating, failed }

typedef _ReadingKey = ({String text, bool phrase});

/// Prompt annotations need only a name. Detail surfaces may additionally fill
/// missing semantic fields and translate a Wiki explicitly opened by the user.
enum TagReadingIntent { nameOnly, details }

class TagTranslationActivity {
  const TagTranslationActivity(this.phase, {this.wiki = false, this.error});
  final TagTranslationPhase phase;
  final bool wiki;
  final String? error;
}

class _VisibleTask {
  const _VisibleTask(this.tag, this.wiki, this.priority, {this.force = false});
  final String tag;
  final bool wiki;
  final int priority;
  final bool force;
}

class AutoTagTranslationContext {
  const AutoTagTranslationContext({
    this.category,
    this.aliases = const [],
    this.postCount,
    this.relatedTo,
  });

  final String? category;
  final List<String> aliases;
  final int? postCount;
  final String? relatedTo;
}

/// Global queue shared by tag expansion and the encyclopedia. Only the latest
/// visible requests wait in the queue; requests already sent may finish and
/// populate the cache after the user scrolls away.
class AutoTagTranslationController extends ChangeNotifier {
  AutoTagTranslationController({
    required PromptAssistantService assistant,
    required TagWikiRepository wiki,
    required VisibleTagTranslationCache cache,
    WikiTagLinks? wikiLinks,
    this.maxConcurrentRequests = 5,
    String Function()? readingLanguage,
    String Function()? wikiReadingLanguage,
    this.closeCacheOnDispose = true,
    this.semantics,
    this.semanticStore,
  }) : _assistant = assistant,
       _wiki = wiki,
       _cache = cache,
       _wikiLinks = wikiLinks,
       _readingLanguage = readingLanguage ?? (() => 'zh'),
       _wikiReadingLanguage =
           wikiReadingLanguage ?? readingLanguage ?? (() => 'zh');

  static const _preferenceKey = 'auto_visible_tag_translation_enabled';
  final PromptAssistantService _assistant;
  final TagWikiRepository _wiki;
  final VisibleTagTranslationCache _cache;
  final WikiTagLinks? _wikiLinks;
  final int maxConcurrentRequests;
  final String Function() _readingLanguage;
  final String Function() _wikiReadingLanguage;
  final bool closeCacheOnDispose;
  final TagSemanticsRepository? semantics;
  final TagSemanticsStore? semanticStore;
  final Set<String> _semanticSettled = {}, _referenceChecked = {};
  PromptTranslationLanguage get _reading =>
      PromptTranslationLanguage.fromCode(_readingLanguage());
  final Map<String, Set<String>> _visibleBySurface = {};
  final Map<String, Set<String>> _nameOnlyBySurface = {};
  final Set<String> _readingPending = {},
      _readingChecked = {},
      _readingLoading = {};
  final Set<String> _forcedNameTags = {};
  bool _readingFlushScheduled = false;
  final Map<String, String> _wikiBySurface = {};
  final Map<String, _VisibleTask> _pending = {};
  final Set<String> _inFlight = {};
  final Map<String, int> _inFlightEpoch = {};
  final Set<String> _wikiInFlight = {};
  final Map<String, String> _sessions = {};
  final Map<String, String> _names = {};
  final Map<String, String> _definitions = {};
  final Map<String, String> _wikiBodies = {};
  final Map<String, String> _wikiOriginals = {};
  final Map<String, AutoTagTranslationContext> _contexts = {};
  final Map<String, String> _nameErrors = {};
  final Map<String, String> _wikiErrors = {};
  int _priority = 0;
  int _routeEpoch = 0;
  int _active = 0;
  bool _enabled = false;
  bool _preferenceChanged = false;
  bool _disposed = false;
  String? _route;
  String? get lastError =>
      _wikiErrors.values.followedBy(_nameErrors.values).firstOrNull;

  bool get enabled => _enabled;
  int get activeRequests => _active + (_readingBatchSession == null ? 0 : 1);
  String? nameFor(String tag) => _names[TagNormalizer.normalize(tag)];
  String? definitionFor(String tag) =>
      _definitions[TagNormalizer.normalize(tag)];
  String? wikiFor(String tag) => _wikiBodies[TagNormalizer.normalize(tag)];
  String? wikiOriginalFor(String tag) =>
      _wikiOriginals[TagNormalizer.normalize(tag)];
  String? wikiErrorFor(String tag) => _wikiErrors[TagNormalizer.normalize(tag)];

  TagTranslationActivity? activityFor(String tag, {bool wiki = false}) {
    final canonical = TagNormalizer.normalize(tag);
    final readingKey = (text: canonical, phrase: false);
    if (!wiki && _readingInFlight.contains(readingKey)) {
      return const TagTranslationActivity(TagTranslationPhase.translating);
    }
    if (!wiki &&
        (_readingQueue.contains(readingKey) ||
            _readingRetryTimers.containsKey(readingKey))) {
      return const TagTranslationActivity(TagTranslationPhase.queued);
    }
    final currentRequest = _inFlightEpoch[canonical] == _routeEpoch;
    TagTranslationActivity active(bool article) => TagTranslationActivity(
      _sessions.containsKey(canonical)
          ? TagTranslationPhase.translating
          : TagTranslationPhase.queued,
      wiki: article,
    );
    if (wiki) {
      if (currentRequest && _wikiInFlight.contains(canonical)) {
        return active(true);
      }
      if (_pending[canonical]?.wiki == true) {
        return const TagTranslationActivity(
          TagTranslationPhase.queued,
          wiki: true,
        );
      }
      if (_wikiErrors[canonical] case final error?) {
        return TagTranslationActivity(
          TagTranslationPhase.failed,
          wiki: true,
          error: error,
        );
      }
    }
    if (currentRequest &&
        _inFlight.contains(canonical) &&
        (!_wikiInFlight.contains(canonical) ||
            !_names.containsKey(canonical))) {
      return active(_wikiInFlight.contains(canonical));
    }
    final pending = _pending[canonical];
    if (pending != null && (!pending.wiki || !_names.containsKey(canonical))) {
      return TagTranslationActivity(
        TagTranslationPhase.queued,
        wiki: pending.wiki,
      );
    }
    if (_nameErrors[canonical] case final error?) {
      return TagTranslationActivity(TagTranslationPhase.failed, error: error);
    }
    return null;
  }

  void retranslateName({required String surface, required String tag}) {
    final canonical = TagNormalizer.normalize(tag);
    if (canonical.isEmpty ||
        _inFlight.contains(canonical) ||
        _pending.containsKey(canonical)) {
      return;
    }
    _visibleBySurface.putIfAbsent(surface, () => <String>{}).add(canonical);
    _nameErrors.remove(canonical);
    _pending[canonical] = _VisibleTask(
      canonical,
      false,
      ++_priority,
      force: true,
    );
    notifyListeners();
    _pump();
  }

  bool isTranslating(String tag) {
    final canonical = TagNormalizer.normalize(tag);
    return _inFlight.contains(canonical) ||
        _readingInFlight.contains((text: canonical, phrase: false));
  }

  bool isWikiTranslating(String tag) {
    final canonical = TagNormalizer.normalize(tag);
    return _wikiInFlight.contains(canonical) ||
        _pending[canonical]?.wiki == true;
  }

  /// An explicit retry works even with automatic translation turned off.
  /// The old body stays visible until the complete new request succeeds.
  void retranslateWiki({required String surface, required String tag}) {
    final canonical = TagNormalizer.normalize(tag);
    if (canonical.isEmpty || isWikiTranslating(canonical)) return;
    _visibleBySurface.putIfAbsent(surface, () => <String>{}).add(canonical);
    _wikiBySurface[surface] = canonical;
    _wikiErrors.remove(canonical);
    if (!_names.containsKey(canonical)) _nameErrors.remove(canonical);
    _pending[canonical] = _VisibleTask(
      canonical,
      true,
      ++_priority,
      force: true,
    );
    notifyListeners();
    _pump();
  }

  void routeChanged() {
    _routeEpoch++;
    _resetReadingQueue();
    _resetPhrases();
    _pending.clear();
    _readingChecked.clear();
    _readingPending.clear();
    _readingLoading.clear();
    _readingFlushScheduled = false;
    _forcedNameTags.clear();
    _route = null;
    _referenceChecked.clear();
    _semanticSettled.clear();
    _names.clear();
    _definitions.clear();
    _wikiBodies.clear();
    _wikiOriginals.clear();
    _nameErrors.clear();
    _wikiErrors.clear();
    notifyListeners();
    _reloadNameReadings();
    _loadPhrases(_visiblePhraseKeys);
    _queueVisible();
  }

  /// Explicit maintenance does not enqueue fresh model calls or change drafts.
  Future<void> clearCache() async {
    _routeEpoch++;
    _resetReadingQueue();
    _resetPhrases();
    _pending.clear();
    _readingPending.clear();
    _readingLoading.clear();
    _readingFlushScheduled = false;
    _readingChecked.clear();
    _forcedNameTags.clear();
    _referenceChecked.clear();
    for (final session in _sessions.values.toList()) {
      unawaited(_assistant.cancelCurrentTask(sessionId: session));
    }
    _names.clear();
    _definitions.clear();
    _wikiBodies.clear();
    _wikiOriginals.clear();
    _nameErrors.clear();
    _wikiErrors.clear();
    await _cache.clear();
    if (!_disposed) {
      // Clearing a cache may reload bundled names, but never starts new model
      // work until the user observes or explicitly requests missing names.
      _reloadNameReadings(allowRemote: false);
      _loadPhrases(_visiblePhraseKeys, allowRemote: false);
      notifyListeners();
    }
  }

  Future<void> loadPreference() async {
    final prefs = await SharedPreferences.getInstance();
    if (_disposed || _preferenceChanged) return;
    _enabled = prefs.getBool(_preferenceKey) ?? false;
    notifyListeners();
    _queueVisible();
  }

  Future<void> setEnabled(bool enabled) async {
    _preferenceChanged = true;
    _enabled = enabled;
    if (!enabled) {
      _pending.clear();
      for (final session in _sessions.values) {
        unawaited(_assistant.cancelCurrentTask(sessionId: session));
      }
      _readingQueue.removeWhere((key) => !_readingForced(key));
      for (final key in _readingRetryTimers.keys.toList()) {
        if (!_readingForced(key)) _readingRetryTimers.remove(key)?.cancel();
      }
      if (_readingBatchSession case final session?
          when !_readingInFlight.any(_readingForced)) {
        _readingBatchSession = null;
        _readingInFlight.clear();
        unawaited(_assistant.cancelCurrentTask(sessionId: session));
      }
    }
    notifyListeners();
    if (enabled) _queueVisible();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_preferenceKey, enabled);
  }

  void observe({
    required String surface,
    required String tag,
    required bool visible,
    String? existingNameZh,
    AutoTagTranslationContext? tagContext,
    TagReadingIntent intent = TagReadingIntent.details,
  }) {
    final canonical = TagNormalizer.normalize(tag);
    if (canonical.isEmpty) return;
    final tags = _visibleBySurface.putIfAbsent(surface, () => <String>{});
    final nameOnly = _nameOnlyBySurface.putIfAbsent(surface, () => <String>{});
    if (visible && intent == TagReadingIntent.nameOnly) {
      if (nameOnly.add(canonical)) _deferReadingSurface(surface);
    } else {
      nameOnly.remove(canonical);
    }
    if (tagContext != null) _contexts[canonical] = tagContext;
    // Existing names come from the same translation interface.
    final acceptsChineseName = intent == TagReadingIntent.nameOnly
        ? _reading.code == 'zh'
        : _reading.isChinese;
    if (acceptsChineseName && existingNameZh?.trim().isNotEmpty == true) {
      _names.putIfAbsent(canonical, () => existingNameZh!.trim());
    }
    if (visible) {
      tags.add(canonical);
      if (intent == TagReadingIntent.nameOnly) {
        _scheduleNameReadings([canonical]);
        return;
      }
      if (semantics != null && _referenceChecked.add(canonical)) {
        unawaited(_loadReference(canonical));
      }
      if (_enabled &&
          (!_names.containsKey(canonical) ||
              semantics != null && !_semanticSettled.contains(canonical))) {
        _enqueue(canonical, wiki: false);
      }
    } else {
      tags.remove(canonical);
      if (!_isVisible(canonical)) _pending.remove(canonical);
      _pruneReadingQueue();
    }
  }

  /// Replaces a prompt's currently visible annotation tags. Local reads are
  /// coalesced across surfaces; no model request is made until they finish.
  void observeNames({required String surface, required Iterable<String> tags}) {
    final next = tags
        .map(TagNormalizer.normalize)
        .where((tag) => tag.isNotEmpty)
        .toSet();
    final previous = _visibleBySurface[surface] ?? const <String>{};
    if (!setEquals(next, _nameOnlyBySurface[surface])) {
      _deferReadingSurface(surface);
    }
    _visibleBySurface[surface] = next;
    _nameOnlyBySurface[surface] = {...next};
    for (final tag in previous.difference(next)) {
      if (!_isVisible(tag)) {
        _pending.remove(tag);
        _forcedNameTags.remove(tag);
      }
    }
    _pruneReadingQueue();
    _scheduleNameReadings(next);
  }

  /// Explicitly fills only missing names on this surface, even with automatic
  /// model calls disabled. Existing names are never retranslated by this action.
  void requestMissingNames({required String surface}) {
    final tags = _nameOnlyBySurface[surface] ?? const <String>{};
    for (final tag in tags) {
      if (!_names.containsKey(tag)) {
        _forcedNameTags.add(tag);
        _nameErrors.remove(tag);
        _resetReadingRetry((text: tag, phrase: false));
      }
    }
    _scheduleNameReadings(tags);
    final phrases = _phrasesBySurface[surface] ?? const <String>{};
    for (final key in phrases) {
      if (!_phraseReadings.containsKey(key)) {
        _phraseForced.add(key);
        _phraseErrors.remove(key);
        _resetReadingRetry((text: key, phrase: true));
      }
    }
    _loadPhrases(phrases);
    notifyListeners();
  }

  // ---- Natural-language phrases ------------------------------------------
  //
  // Prompt sentences that are not tags read like Plana's: every visible one
  // is queued, batched after a short pause and cached. They follow the same
  // automatic switch, route, language and cache invalidation as tag names.

  final Map<String, Set<String>> _phrasesBySurface = {};
  final Map<String, String> _phraseSources = {};
  final Map<String, String> _phraseReadings = {};
  final Map<String, String> _phraseErrors = {};
  final Set<String> _phraseChecked = {},
      _phraseLoading = {},
      _phraseForced = {};

  /// Whitespace and letter case do not change a phrase's reading.
  static String phraseKey(String text) =>
      text.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  /// Phrase rows share the reading cache without colliding with tag rows.
  static String _phraseCacheKey(String key) => 'phrase:$key';

  String? phraseFor(String text) => _phraseReadings[phraseKey(text)];

  /// Replaces a prompt's currently visible natural-language phrases.
  void observePhrases({
    required String surface,
    required Iterable<String> phrases,
  }) {
    final next = <String>{};
    for (final phrase in phrases) {
      final key = phraseKey(phrase);
      if (key.isEmpty) continue;
      next.add(key);
      _phraseSources.putIfAbsent(key, () => phrase.trim());
    }
    if (!setEquals(next, _phrasesBySurface[surface])) {
      _deferReadingSurface(surface);
    }
    _phrasesBySurface[surface] = next;
    _pruneReadingQueue();
    _loadPhrases(next);
  }

  Iterable<String> get _visiblePhraseKeys =>
      _phrasesBySurface.values.expand((keys) => keys).toSet();

  bool _phraseVisible(String key) =>
      _phrasesBySurface.values.any((keys) => keys.contains(key));

  void _resetPhrases() {
    _phraseReadings.clear();
    _phraseErrors.clear();
    _phraseChecked.clear();
    _phraseLoading.clear();
    _phraseForced.clear();
  }

  /// Reads cached phrases once per route, then queues what is still missing.
  void _loadPhrases(Iterable<String> keys, {bool allowRemote = true}) {
    final unchecked = <String>[];
    for (final key in keys) {
      if (_phraseChecked.add(key)) {
        unchecked.add(key);
      } else if (allowRemote) {
        _queuePhrase(key);
      }
    }
    if (unchecked.isEmpty) return;
    _phraseLoading.addAll(unchecked);
    unawaited(_readCachedPhrases(unchecked, allowRemote: allowRemote));
  }

  Future<void> _readCachedPhrases(
    List<String> keys, {
    required bool allowRemote,
  }) async {
    final epoch = _routeEpoch;
    final generation = _cache.generation;
    final language = _reading.code;
    final route = _assistant.translateRouteFingerprint();
    Map<String, String> cached;
    try {
      cached = await _cache.namesFor(
        tags: keys.map(_phraseCacheKey),
        language: language,
        route: route.isEmpty ? null : route,
        maxPromptVersion:
            PromptAssistantService.promptReadingTranslationPromptVersion,
      );
    } catch (_) {
      cached = const {};
    }
    if (_disposed ||
        epoch != _routeEpoch ||
        generation != _cache.generation ||
        language != _reading.code) {
      return;
    }
    for (final key in keys) {
      _phraseLoading.remove(key);
      final reading = cached[_phraseCacheKey(key)];
      if (reading != null && reading.trim().isNotEmpty) {
        _phraseReadings[key] = reading;
      }
      if (allowRemote) _queuePhrase(key);
    }
    notifyListeners();
  }

  void _queuePhrase(String key) {
    if (_phraseReadings.containsKey(key)) {
      _phraseForced.remove(key);
      return;
    }
    if (_phraseLoading.contains(key) || !_phraseVisible(key)) return;
    final force = _phraseForced.contains(key);
    if (!_enabled && !force) return;
    if (_assistant.translateRouteFingerprint().isEmpty) {
      if (force) _phraseErrors[key] = currentL10n.wiki_configureTagModel;
      _phraseForced.remove(key);
      return;
    }
    _queueReading((text: key, phrase: true));
  }

  // ---- Shared, idle-only model queue for prompt readings ------------------

  static const _readingDebounce = Duration(milliseconds: 800);
  static const _readingBatchGap = Duration(milliseconds: 300);
  static const _readingRetryDelays = [
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];
  static const _readingBatchSize = 8, _readingBatchChars = 2400;
  final Set<_ReadingKey> _readingQueue = {}, _readingInFlight = {};
  final Map<_ReadingKey, Timer> _readingRetryTimers = {};
  final Map<_ReadingKey, int> _readingRetries = {};
  final Map<String, Timer> _readingSurfaceTimers = {};
  final Set<String> _settledReadingSurfaces = {},
      _composingReadingSurfaces = {};
  Timer? _readingBatchTimer;
  Timer? _readingCooldownTimer;
  String? _readingBatchSession;
  int _readingBatchSerial = 0;

  /// Every real edit restarts the pause, including edits which leave the same
  /// set of visible tags. Local/cache reads are never delayed by this gate.
  void deferPromptReadings({required String surface, required bool composing}) {
    if (composing) {
      _composingReadingSurfaces.add(surface);
    } else {
      _composingReadingSurfaces.remove(surface);
    }
    _deferReadingSurface(surface);
  }

  void _deferReadingSurface(String surface) {
    _readingSurfaceTimers.remove(surface)?.cancel();
    _settledReadingSurfaces.remove(surface);
    if (_composingReadingSurfaces.contains(surface)) return;
    _readingSurfaceTimers[surface] = Timer(_readingDebounce, () {
      _readingSurfaceTimers.remove(surface);
      if (_disposed) return;
      _settledReadingSurfaces.add(surface);
      _scheduleReadingBatch();
    });
  }

  Iterable<String> _surfacesForReading(_ReadingKey key) =>
      (key.phrase ? _phrasesBySurface : _nameOnlyBySurface).entries
          .where((entry) => entry.value.contains(key.text))
          .map((entry) => entry.key);

  bool _readingVisible(_ReadingKey key) => _surfacesForReading(key).isNotEmpty;
  bool _readingForced(_ReadingKey key) =>
      (key.phrase ? _phraseForced : _forcedNameTags).contains(key.text);
  bool _readingMissing(_ReadingKey key) =>
      !(key.phrase ? _phraseReadings : _names).containsKey(key.text);
  Map<String, String> _errorsForReading(_ReadingKey key) =>
      key.phrase ? _phraseErrors : _nameErrors;
  String _sourceForReading(_ReadingKey key) =>
      key.phrase ? _phraseSources[key.text]! : key.text;

  bool _readingReady(_ReadingKey key) => _surfacesForReading(key).any(
    (surface) =>
        !_composingReadingSurfaces.contains(surface) &&
        (_readingForced(key) || _settledReadingSurfaces.contains(surface)),
  );

  void _resetReadingRetry(_ReadingKey key) {
    _readingRetryTimers.remove(key)?.cancel();
    _readingRetries.remove(key);
  }

  void _pruneReadingQueue() {
    _readingQueue.retainWhere(_readingVisible);
    for (final key in _readingRetryTimers.keys.toList()) {
      if (!_readingVisible(key)) _readingRetryTimers.remove(key)?.cancel();
    }
    _forcedNameTags.retainWhere(
      (tag) => _readingVisible((text: tag, phrase: false)),
    );
    _phraseForced.retainWhere(_phraseVisible);
  }

  void _resetReadingQueue() {
    _readingBatchTimer?.cancel();
    _readingBatchTimer = null;
    _readingCooldownTimer?.cancel();
    _readingCooldownTimer = null;
    for (final timer in _readingRetryTimers.values) {
      timer.cancel();
    }
    _readingRetryTimers.clear();
    _readingRetries.clear();
    _readingQueue.clear();
    _readingInFlight.clear();
    if (_readingBatchSession case final session?) {
      unawaited(_assistant.cancelCurrentTask(sessionId: session));
    }
    _readingBatchSession = null;
  }

  void _queueReading(_ReadingKey key) {
    if (!_readingVisible(key) ||
        !_readingMissing(key) ||
        _readingInFlight.contains(key)) {
      return;
    }
    final forced = _readingForced(key);
    if ((!_enabled && !forced) ||
        _errorsForReading(key).containsKey(key.text)) {
      return;
    }
    // Single letters and non-Latin fragments still use the local dictionary,
    // but are not useful automatic model requests while a word is forming.
    if (!forced &&
        (key.text.runes.length < 2 || !RegExp('[A-Za-z]').hasMatch(key.text))) {
      return;
    }
    _readingQueue.add(key);
    _scheduleReadingBatch();
  }

  void _scheduleReadingBatch() {
    if (_disposed ||
        _readingBatchSession != null ||
        (_readingCooldownTimer?.isActive ?? false) ||
        _readingQueue.isEmpty ||
        (_readingBatchTimer?.isActive ?? false)) {
      return;
    }
    _readingBatchTimer = Timer(Duration.zero, _flushReadings);
  }

  void _recordReadingFailure(_ReadingKey key, Object error) {
    final message = FatalDiagnostics.redactSensitiveText(
      '$error'.replaceAll(RegExp(r'https?://[^\s]+'), '[URL]'),
    );
    _errorsForReading(key)[key.text] = message;
    final attempts = _readingRetries[key] ?? 0;
    if (error is! PromptAssistantRequestFailure || !error.retryable) {
      return;
    }
    var delay =
        _readingRetryDelays[attempts.clamp(0, _readingRetryDelays.length - 1)];
    if (error.statusCode == 429 && delay < const Duration(seconds: 90)) {
      delay = const Duration(seconds: 90);
    }
    if (error.retryAfter case final requested? when requested > delay) {
      delay = requested;
    }
    if (error.statusCode == 429 || error.retryAfter != null) {
      // Rate limiting applies to the route, including newly typed fragments.
      // New entries must not bypass the failed batch's server cooldown.
      if (!(_readingCooldownTimer?.isActive ?? false)) {
        _readingCooldownTimer = Timer(delay, () {
          _readingCooldownTimer = null;
          _scheduleReadingBatch();
        });
      }
    }
    if (attempts >= _readingRetryDelays.length ||
        !_enabled ||
        !_readingVisible(key)) {
      return;
    }
    _readingRetries[key] = attempts + 1;
    _readingRetryTimers[key]?.cancel();
    _readingRetryTimers[key] = Timer(delay, () {
      _readingRetryTimers.remove(key);
      if (_disposed ||
          !_enabled ||
          !_readingVisible(key) ||
          !_readingMissing(key)) {
        return;
      }
      _errorsForReading(key).remove(key.text);
      _queueReading(key);
      notifyListeners();
    });
  }

  Future<void> _flushReadings() async {
    _readingBatchTimer = null;
    if (_disposed ||
        _readingBatchSession != null ||
        (_readingCooldownTimer?.isActive ?? false) ||
        _active >= maxConcurrentRequests) {
      return;
    }
    _pruneReadingQueue();
    final batch = <_ReadingKey>[];
    var chars = 0;
    for (final key in _readingQueue.toList()) {
      if (!_readingMissing(key)) {
        _readingQueue.remove(key);
        continue;
      }
      if ((!_enabled && !_readingForced(key)) ||
          !_readingReady(key) ||
          _errorsForReading(key).containsKey(key.text) ||
          (!key.phrase &&
              (_inFlight.contains(key.text) ||
                  _pending.containsKey(key.text)))) {
        continue;
      }
      final length = _sourceForReading(key).length;
      if (batch.isNotEmpty &&
          (batch.length >= _readingBatchSize ||
              chars + length > _readingBatchChars)) {
        break;
      }
      batch.add(key);
      chars += length;
    }
    if (batch.isEmpty) return;
    final route = _assistant.translateRouteFingerprint();
    if (route.isEmpty) return;
    final epoch = _routeEpoch, generation = _cache.generation;
    final language = _reading.code;
    final forced = batch.where(_readingForced).toSet();
    bool allowed(_ReadingKey key) =>
        _enabled || forced.contains(key) || _readingForced(key);
    final session =
        'prompt-readings-${identityHashCode(this)}-${++_readingBatchSerial}';
    bool current() =>
        !_disposed &&
        _readingBatchSession == session &&
        epoch == _routeEpoch &&
        generation == _cache.generation &&
        language == _reading.code &&
        route == _assistant.translateRouteFingerprint();
    _readingQueue.removeAll(batch);
    _readingInFlight.addAll(batch);
    _readingBatchSession = session;
    notifyListeners();
    try {
      final result = await _assistant.translatePromptReadings(
        batch.map(_sourceForReading).toList(),
        sessionId: session,
        canonicalTags: [
          for (final key in batch)
            if (!key.phrase) key.text,
        ],
      );
      for (final key in batch) {
        if (!current()) return;
        if (!allowed(key)) continue;
        if (!_readingMissing(key)) continue;
        final reading = result[_sourceForReading(key)];
        if (reading == null ||
            reading.trim().isEmpty ||
            (!key.phrase && reading.length > 64)) {
          _recordReadingFailure(
            key,
            const FormatException('Missing or invalid prompt reading'),
          );
          continue;
        }
        try {
          await _cache.put(
            expectedGeneration: generation,
            tag: key.phrase ? _phraseCacheKey(key.text) : key.text,
            route: route,
            promptVersion: key.phrase
                ? PromptAssistantService.promptReadingTranslationPromptVersion
                : PromptAssistantService.visibleTagTranslationPromptVersion,
            wikiHash: '',
            nameZh: reading,
            nameLanguage: language,
            definitionLanguage: language,
          );
        } catch (_) {
          /* The in-memory reading remains useful without persistence. */
        }
        if (!current()) return;
        if (!allowed(key)) continue;
        (key.phrase ? _phraseReadings : _names)[key.text] = reading;
        _errorsForReading(key).remove(key.text);
        _resetReadingRetry(key);
      }
    } catch (error) {
      if (!current()) return;
      for (final key in batch) {
        if (allowed(key)) _recordReadingFailure(key, error);
      }
    } finally {
      // A cancelled old route must not clear the new route's active batch.
      if (_readingBatchSession == session) {
        _readingBatchSession = null;
        _readingInFlight.clear();
        for (final key in batch) {
          (key.phrase ? _phraseForced : _forcedNameTags).remove(key.text);
        }
        if (!_disposed) {
          if (_readingQueue.isNotEmpty) {
            _readingBatchTimer = Timer(_readingBatchGap, _flushReadings);
          }
          notifyListeners();
          _pump();
        }
      }
    }
  }

  void _reloadNameReadings({bool allowRemote = true}) => _scheduleNameReadings(
    _nameOnlyBySurface.values.expand((tags) => tags),
    allowRemote: allowRemote,
  );

  void _scheduleNameReadings(Iterable<String> tags, {bool allowRemote = true}) {
    for (final tag in tags) {
      if (_readingChecked.add(tag)) {
        _readingPending.add(tag);
      } else if (allowRemote && !_readingPending.contains(tag)) {
        _queueMissingName(tag);
      }
    }
    if (_readingFlushScheduled ||
        _readingPending.difference(_readingLoading).isEmpty) {
      return;
    }
    _readingFlushScheduled = true;
    final epoch = _routeEpoch;
    scheduleMicrotask(() {
      if (_disposed || epoch != _routeEpoch) return;
      _readingFlushScheduled = false;
      final batch = _readingPending.difference(_readingLoading).toList();
      if (batch.isEmpty) return;
      _readingLoading.addAll(batch);
      unawaited(_loadNameReadings(batch, allowRemote: allowRemote));
    });
  }

  Future<void> _loadNameReadings(
    List<String> tags, {
    required bool allowRemote,
  }) async {
    final epoch = _routeEpoch;
    final generation = _cache.generation;
    final language = _reading.code;
    final route = _assistant.translateRouteFingerprint();
    Future<Map<String, String>> cachedNames() async {
      try {
        return await _cache.namesFor(
          tags: tags,
          language: language,
          route: route.isEmpty ? null : route,
          maxPromptVersion:
              PromptAssistantService.visibleTagTranslationPromptVersion,
        );
      } catch (_) {
        return const {};
      }
    }

    Future<Map<String, TagSemanticProfile>> localNames() async {
      if (language != 'zh') return const {};
      try {
        return await semantics?.findAll(tags) ?? const {};
      } catch (_) {
        return const {};
      }
    }

    final cachedFuture = cachedNames();
    final profiles = await localNames();
    final cached = await cachedFuture;
    if (_disposed ||
        epoch != _routeEpoch ||
        generation != _cache.generation ||
        language != _reading.code ||
        route != _assistant.translateRouteFingerprint()) {
      return;
    }
    for (final tag in tags) {
      _readingPending.remove(tag);
      _readingLoading.remove(tag);
      final name = cached[tag] ?? profiles[tag]?.coreZh;
      if (name?.trim().isNotEmpty == true) {
        _names[tag] = name!;
        _nameErrors.remove(tag);
        _forcedNameTags.remove(tag);
      }
      if (allowRemote) _queueMissingName(tag);
    }
    notifyListeners();
  }

  void _queueMissingName(String tag) {
    if (!_isVisible(tag) || _readingPending.contains(tag)) return;
    if (_names.containsKey(tag)) {
      _forcedNameTags.remove(tag);
      return;
    }
    final force = _forcedNameTags.contains(tag);
    if (!_enabled && !force) return;
    if (_assistant.translateRouteFingerprint().isEmpty) {
      // An unconfigured automatic reader remains a useful offline reader.
      if (force) _nameErrors[tag] = currentL10n.wiki_configureTagModel;
      _forcedNameTags.remove(tag);
      return;
    }
    _queueReading((text: tag, phrase: false));
  }

  Future<void> _loadReference(String tag) async {
    final epoch = _routeEpoch;
    try {
      final profile = await semantics?.find(tag);
      if (_disposed || epoch != _routeEpoch || profile == null) return;
      if (profile.complete) _semanticSettled.add(tag);
      if (_reading.code == 'zh') {
        if (profile.coreZh.isNotEmpty) {
          _names.putIfAbsent(tag, () => profile.coreZh);
        }
        if (profile.summaryZh.isNotEmpty) {
          _definitions.putIfAbsent(tag, () => profile.summaryZh);
        }
        notifyListeners();
      }
    } catch (_) {
      _referenceChecked.remove(tag);
    }
  }

  /// Call only when the wiki body has actually been opened on screen.
  void requestWiki({
    required String surface,
    required String tag,
    AutoTagTranslationContext? tagContext,
  }) {
    final canonical = TagNormalizer.normalize(tag);
    if (canonical.isEmpty) return;
    _visibleBySurface.putIfAbsent(surface, () => <String>{}).add(canonical);
    if (tagContext != null) _contexts[canonical] = tagContext;
    _wikiBySurface[surface] = canonical;
    if (_enabled && !_wikiBodies.containsKey(canonical)) {
      _enqueue(canonical, wiki: true);
    }
  }

  void clearSurface(String surface) {
    _phrasesBySurface.remove(surface);
    _nameOnlyBySurface.remove(surface);
    _readingSurfaceTimers.remove(surface)?.cancel();
    _settledReadingSurfaces.remove(surface);
    _composingReadingSurfaces.remove(surface);
    _pruneReadingQueue();
    final removed = _visibleBySurface.remove(surface);
    final oldWiki = _wikiBySurface.remove(surface);
    if (oldWiki != null && !_wikiBySurface.values.contains(oldWiki)) {
      final pending = _pending[oldWiki];
      if (pending?.wiki == true) {
        if (_names.containsKey(oldWiki)) {
          _pending.remove(oldWiki);
        } else {
          _pending[oldWiki] = _VisibleTask(oldWiki, false, pending!.priority);
        }
      }
    }
    if (removed == null) return;
    for (final tag in removed) {
      if (!_isVisible(tag)) {
        _pending.remove(tag);
        _forcedNameTags.remove(tag);
      } else if (!_needsDetails(tag)) {
        final pending = _pending[tag];
        if (pending != null && !pending.wiki) {
          _pending.remove(tag);
          if (pending.force) _forcedNameTags.add(tag);
          _queueMissingName(tag);
        }
      }
    }
  }

  bool _isVisible(String tag) =>
      _visibleBySurface.values.any((tags) => tags.contains(tag));

  bool _needsDetails(String tag) => _visibleBySurface.entries.any(
    (entry) =>
        entry.value.contains(tag) &&
        !(_nameOnlyBySurface[entry.key]?.contains(tag) ?? false),
  );

  void _queueVisible() {
    if (!_enabled) return;
    for (final key in _visiblePhraseKeys) {
      _queuePhrase(key);
    }
    for (final tag in _wikiBySurface.values) {
      if (!_wikiBodies.containsKey(tag)) _enqueue(tag, wiki: true);
    }
    for (final tags in _visibleBySurface.values) {
      for (final tag in tags) {
        if (!_needsDetails(tag)) {
          _queueMissingName(tag);
          continue;
        }
        if (!_names.containsKey(tag) ||
            semantics != null && !_semanticSettled.contains(tag)) {
          _enqueue(tag, wiki: false);
        }
      }
    }
  }

  void _enqueue(String tag, {required bool wiki, bool force = false}) {
    if ((!_enabled && !force) ||
        (wiki ? _wikiErrors : _nameErrors).containsKey(tag) ||
        (_inFlightEpoch[tag] == _routeEpoch &&
            _inFlight.contains(tag) &&
            (!wiki || _wikiInFlight.contains(tag)))) {
      return;
    }
    final previous = _pending[tag];
    final merged = wiki || previous?.wiki == true;
    _pending[tag] = _VisibleTask(
      tag,
      merged,
      ++_priority,
      // A forced name retry must not turn an automatic Wiki request into a
      // cache-bypassing one.
      force:
          force && !merged ||
          previous != null && previous.wiki == merged && previous.force,
    );
    notifyListeners();
    _pump();
  }

  void _pump() {
    if (_disposed) return;
    while (activeRequests < maxConcurrentRequests) {
      final eligible =
          _pending.values
              .where(
                (task) =>
                    (_enabled || task.force) &&
                    _isVisible(task.tag) &&
                    !_inFlight.contains(task.tag) &&
                    !_readingInFlight.contains((
                      text: task.tag,
                      phrase: false,
                    )) &&
                    !(task.wiki ? _wikiErrors : _nameErrors).containsKey(
                      task.tag,
                    ),
              )
              .toList()
            ..sort((a, b) {
              if (a.wiki != b.wiki) return a.wiki ? -1 : 1;
              return b.priority.compareTo(a.priority);
            });
      if (eligible.isEmpty) return;
      final task = eligible.first;
      final taskEpoch = _routeEpoch;
      _pending.remove(task.tag);
      _inFlight.add(task.tag);
      _inFlightEpoch[task.tag] = _routeEpoch;
      if (task.wiki) _wikiInFlight.add(task.tag);
      _active++;
      notifyListeners();
      unawaited(
        _run(task).whenComplete(() {
          _active--;
          _inFlight.remove(task.tag);
          _inFlightEpoch.remove(task.tag);
          _wikiInFlight.remove(task.tag);
          if (!_disposed) {
            notifyListeners();
            if (taskEpoch == _routeEpoch) _scheduleReadingBatch();
            _pump();
          }
        }),
      );
    }
  }

  Future<void> _run(_VisibleTask task) async {
    final epoch = _routeEpoch;
    final cacheGeneration = _cache.generation;
    try {
      var profile = await semantics?.find(task.tag);
      if (_disposed || epoch != _routeEpoch) return;
      if (profile?.complete == true) _semanticSettled.add(task.tag);
      final route = _assistant.translateRouteFingerprint();
      if (!task.wiki &&
          !task.force &&
          _reading.code == 'zh' &&
          profile?.complete == true) {
        CachedVisibleTagTranslation? saved;
        if (route.isNotEmpty) {
          try {
            final body = (await _wiki.find(task.tag))?.body ?? '';
            saved = await _cache.get(
              tag: task.tag,
              route: route,
              promptVersion:
                  PromptAssistantService.visibleTagTranslationPromptVersion,
              wikiHash: sha256.convert(utf8.encode(body)).toString(),
              allowEarlierVersion: true,
            );
          } catch (_) {
            /* Bundled reference data remains usable. */
          }
        }
        if (_disposed || epoch != _routeEpoch) return;
        _names[task.tag] = saved?.nameZh ?? _names[task.tag] ?? profile!.coreZh;
        _definitions[task.tag] = saved?.definition ?? profile!.summaryZh;
        notifyListeners();
        return;
      }
      if (route.isEmpty) {
        throw StateError(currentL10n.wiki_configureTagModel);
      }
      if (_route != route) {
        // Names observed before the first task came from this same interface.
        if (_route != null) {
          _names.clear();
          _definitions.clear();
          _wikiBodies.clear();
          _wikiOriginals.clear();
        }
        _route = route;
      }
      final entry = await _wiki.find(task.tag);
      final body = entry?.body ?? '';
      final tagContext = _contexts[task.tag];
      if (task.wiki && !task.force && !shouldTranslateWiki(body)) return;
      final hash = sha256.convert(utf8.encode(body)).toString();
      final cached = task.force && task.wiki
          ? null
          : await _cache.get(
              tag: task.tag,
              route: route,
              promptVersion:
                  PromptAssistantService.visibleTagTranslationPromptVersion,
              wikiHash: hash,
              allowEarlierVersion: true,
            );
      if (_disposed ||
          epoch != _routeEpoch ||
          route != _assistant.translateRouteFingerprint()) {
        return;
      }
      // A known Chinese label is only partial reference data. Reuse it without
      // treating absent synonyms/summary as a completed semantic supplement.
      if (semanticStore != null &&
          !task.wiki &&
          cached != null &&
          profile?.complete != true &&
          !(await semanticStore!.attempted(
            task.tag,
            hash,
            PromptAssistantService.visibleTagTranslationPromptVersion,
          )) &&
          cached.nameLanguage == 'zh') {
        await semanticStore!.put(
          tag: task.tag,
          coreZh: profile?.coreZh.isNotEmpty == true ? '' : cached.nameZh,
          synonymsZh: profile?.synonymsZh.isNotEmpty == true
              ? const []
              : [cached.nameZh],
          summaryZh:
              profile?.summaryZh.isNotEmpty == true ||
                  cached.wikiHash != hash ||
                  cached.definitionLanguage != 'zh'
              ? ''
              : cached.definition ?? '',
          wikiHash: cached.wikiHash == hash ? hash : '',
          promptVersion: 0,
          provenance: 'legacy-reading-cache',
        );
        profile = await semantics?.find(task.tag);
      }
      final semanticNeeded =
          !task.wiki &&
          semantics != null &&
          profile?.complete != true &&
          (task.force ||
              !(await semanticStore?.attempted(
                    task.tag,
                    hash,
                    PromptAssistantService.visibleTagTranslationPromptVersion,
                  ) ??
                  false));
      if (!semanticNeeded && !task.wiki && semantics != null) {
        _semanticSettled.add(task.tag);
      }
      final name = task.force && !task.wiki
          ? null
          : cached?.nameZh ??
                _names[task.tag] ??
                (_reading.code == 'zh' && profile?.coreZh.isNotEmpty == true
                    ? profile!.coreZh
                    : null);
      if (name != null) _names[task.tag] = name;
      if (cached?.definition case final definition?) {
        _definitions[task.tag] = definition;
      }
      if (cached?.wikiZh case final wikiZh?) _wikiBodies[task.tag] = wikiZh;
      if (cached?.wikiOriginal case final source?) {
        _wikiOriginals[task.tag] = source;
      }
      // Same article text already translated under another route (model or
      // preset edits): show it instead of paying again. Retranslate refreshes.
      // Rows record name/definition languages only, so reuse is limited to the
      // common case where tag and Wiki reading languages are the same.
      if (task.wiki &&
          !task.force &&
          cached?.wikiZh == null &&
          body.trim().isNotEmpty &&
          _reading.code == _wikiReadingLanguage()) {
        final reuse = await _cache.wikiFromAnyRoute(
          tag: task.tag,
          wikiHash: hash,
          language: _wikiReadingLanguage(),
          maxPromptVersion:
              PromptAssistantService.visibleTagTranslationPromptVersion,
        );
        if (_disposed || epoch != _routeEpoch) return;
        if (reuse != null) {
          _wikiBodies[task.tag] = reuse.wikiZh;
          if (reuse.wikiOriginal case final source?) {
            _wikiOriginals[task.tag] = source;
          } else {
            _wikiOriginals.remove(task.tag);
          }
          _wikiErrors.remove(task.tag);
          notifyListeners();
          return;
        }
      }
      if (!_disposed) notifyListeners();
      if (task.wiki && body.trim().isEmpty) return;
      if ((task.wiki && cached?.wikiZh != null) ||
          (!task.wiki && name != null && !semanticNeeded && !task.force)) {
        return;
      }
      if ((!_enabled && !task.force) || !_isVisible(task.tag) || _disposed) {
        return;
      }
      var translatedName = name;
      var nameLanguage = name == null
          ? null
          : cached?.nameLanguage ?? _reading.code;
      var definition = task.force && !task.wiki ? null : cached?.definition;
      var definitionLanguage = task.force && !task.wiki
          ? null
          : cached?.definitionLanguage;
      final articleLanguage = _wikiReadingLanguage();
      final translatedWiki = StringBuffer();
      final originalWiki = StringBuffer();
      var completeOriginal = true;
      final chunks = task.wiki
          ? _wikiChunks(body)
          : <({String text, String separator})>[(text: body, separator: '')];
      if (task.wiki && chunks.length > 1 && translatedName == null) {
        final nameSession =
            'visible-tag-${DateTime.now().microsecondsSinceEpoch}-${task.tag}-name';
        _sessions[task.tag] = nameSession;
        notifyListeners();
        final nameResult = await _assistant.translateVisibleTag(
          tag: task.tag,
          wikiBody: body,
          includeWikiTranslation: false,
          category: tagContext?.category,
          aliases: tagContext?.aliases ?? const [],
          postCount: tagContext?.postCount,
          relatedTo: tagContext?.relatedTo,
          sessionId: nameSession,
        );
        _sessions.remove(task.tag);
        translatedName = nameResult.nameZh;
        nameLanguage = _reading.code;
        definition = nameResult.definition;
        definitionLanguage = _reading.code;
      }
      for (var index = 0; index < chunks.length; index++) {
        // A started Wiki translation finishes so it lands in the cache; closing
        // the panel mid-article used to throw the paid chunks away.
        if ((!_enabled && !task.force) ||
            (!task.wiki && !_isVisible(task.tag)) ||
            _disposed ||
            epoch != _routeEpoch) {
          return;
        }
        final chunk = chunks[index];
        final glossary =
            await _wikiLinks?.glossaryFor(
              task.wiki ? chunk.text : TagNormalizer.toDisplay(task.tag),
              currentTag: task.tag,
              limit: task.wiki ? 64 : 1,
            ) ??
            const <Map<String, Object>>[];
        if (_disposed ||
            epoch != _routeEpoch ||
            (!_enabled && !task.force) ||
            (!task.wiki && !_isVisible(task.tag))) {
          return;
        }
        final sessionId =
            'visible-tag-${DateTime.now().microsecondsSinceEpoch}-${task.tag}-$index';
        _sessions[task.tag] = sessionId;
        notifyListeners();
        final result = await _assistant.translateVisibleTag(
          tag: task.tag,
          wikiBody: chunk.text,
          includeWikiTranslation: task.wiki,
          existingNameZh: translatedName,
          category: tagContext?.category,
          aliases: tagContext?.aliases ?? const [],
          postCount: tagContext?.postCount,
          relatedTo: tagContext?.relatedTo,
          glossary: [
            ...glossary,
            if (!task.wiki && profile != null)
              {
                'tag': task.tag,
                'semantic_profile': {
                  'core_zh': profile.coreZh,
                  'synonyms_zh': profile.synonymsZh,
                  'summary_zh': profile.summaryZh,
                },
              },
          ],
          sessionId: sessionId,
        );
        _sessions.remove(task.tag);
        if (!task.wiki &&
            semanticStore != null &&
            semantics != null &&
            profile?.complete != true &&
            (_enabled || task.force) &&
            !_disposed &&
            epoch == _routeEpoch &&
            route == _assistant.translateRouteFingerprint()) {
          await semanticStore!.put(
            tag: task.tag,
            coreZh: result.coreZh ?? profile?.coreZh ?? '',
            synonymsZh: result.synonymsZh ?? profile?.synonymsZh ?? const [],
            summaryZh: result.summaryZh ?? profile?.summaryZh ?? '',
            wikiHash: hash,
            promptVersion:
                PromptAssistantService.visibleTagTranslationPromptVersion,
            provenance: 'visible-tag-translation',
          );
          _semanticSettled.add(task.tag);
        }
        translatedName = result.nameZh;
        nameLanguage ??= task.wiki ? articleLanguage : _reading.code;
        if (definition == null && result.definition != null) {
          definition = result.definition;
          definitionLanguage = task.wiki ? articleLanguage : _reading.code;
        }
        if (task.wiki) {
          translatedWiki.write(result.wikiZh);
          if (result.wikiOriginal case final source?) {
            originalWiki.write(source);
          } else {
            completeOriginal = false;
          }
          if (chunk.separator.isNotEmpty) {
            translatedWiki.write('\n\n');
            originalWiki.write('\n\n');
          }
        }
      }
      if (_disposed ||
          epoch != _routeEpoch ||
          (!_enabled && !task.force) ||
          route != _assistant.translateRouteFingerprint()) {
        return;
      }
      String? wikiZh;
      String? wikiOriginal;
      if (task.wiki) {
        final body = translatedWiki.toString().trim();
        wikiZh = _wikiLinks == null
            ? WikiTagLinks.withoutLocalLinks(body)
            : (await _wikiLinks.resolve(body)).markdown;
        if (completeOriginal && originalWiki.toString().trim().isNotEmpty) {
          final source = originalWiki.toString().trim();
          wikiOriginal = _wikiLinks == null
              ? WikiTagLinks.withoutLocalLinks(source)
              : (await _wikiLinks.resolve(source)).markdown;
        }
      }
      if (_disposed ||
          epoch != _routeEpoch ||
          (!_enabled && !task.force) ||
          route != _assistant.translateRouteFingerprint()) {
        return;
      }
      await _cache.put(
        expectedGeneration: cacheGeneration,
        tag: task.tag,
        route: route,
        promptVersion:
            PromptAssistantService.visibleTagTranslationPromptVersion,
        wikiHash: hash,
        nameZh: translatedName!,
        wikiZh: wikiZh ?? cached?.wikiZh,
        wikiOriginal: task.wiki ? wikiOriginal : cached?.wikiOriginal,
        definition: definition,
        nameLanguage: nameLanguage!,
        definitionLanguage: definitionLanguage ?? _reading.code,
      );
      if (_disposed || epoch != _routeEpoch) return;
      _names[task.tag] = translatedName;
      _nameErrors.remove(task.tag);
      if (definition != null) _definitions[task.tag] = definition;
      if (wikiZh != null) {
        _wikiErrors.remove(task.tag);
        _wikiBodies[task.tag] = wikiZh;
        if (wikiOriginal != null) {
          _wikiOriginals[task.tag] = wikiOriginal;
        } else {
          _wikiOriginals.remove(task.tag);
        }
      }
      if (!_disposed) notifyListeners();
    } catch (error) {
      if ((!_enabled && !task.force) || _disposed || epoch != _routeEpoch) {
        return;
      }
      final safeError = FatalDiagnostics.redactSensitiveText(
        '$error'.replaceAll(RegExp(r'https?://[^\s]+'), '[URL]'),
      );
      (task.wiki ? _wikiErrors : _nameErrors)[task.tag] = safeError;
      if (task.wiki && !_names.containsKey(task.tag)) {
        _nameErrors[task.tag] = safeError;
      }
      if (_pending[task.tag]?.wiki == task.wiki) _pending.remove(task.tag);
      if (!_disposed) notifyListeners();
    } finally {
      _sessions.remove(task.tag);
    }
  }

  static List<({String text, String separator})> _wikiChunks(String body) {
    const limit = 5000;
    if (body.length <= limit) return [(text: body, separator: '')];
    final chunks = <({String text, String separator})>[];
    var start = 0;
    while (start < body.length) {
      if (body.length - start <= limit) {
        chunks.add((text: body.substring(start).trim(), separator: ''));
        break;
      }
      final end = start + limit;
      final lineBreak = body.lastIndexOf('\n', end);
      final wordBreak = body.lastIndexOf(' ', end);
      final cut = lineBreak > start + limit ~/ 2
          ? lineBreak + 1
          : wordBreak > start + limit ~/ 2
          ? wordBreak + 1
          : end;
      chunks.add((
        text: body.substring(start, cut).trim(),
        separator: body[cut - 1] == '\n' ? '\n' : ' ',
      ));
      start = cut;
    }
    return chunks;
  }

  static bool shouldTranslateWiki(String body) {
    final latin = RegExp(r'[A-Za-z]').allMatches(body).length;
    if (latin == 0) return false;
    final han = RegExp(r'[\u3400-\u9fff]').allMatches(body).length;
    return latin >= han;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final timer in _readingSurfaceTimers.values) {
      timer.cancel();
    }
    _readingSurfaceTimers.clear();
    _resetReadingQueue();
    if (closeCacheOnDispose) unawaited(_cache.close());
    super.dispose();
  }
}
