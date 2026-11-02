import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nai_launcher/core/wiki/auto_tag_translation_controller.dart';
import 'package:nai_launcher/core/wiki/tag_wiki_repository.dart';
import 'package:nai_launcher/core/wiki/visible_tag_translation_cache.dart';
import 'package:nai_launcher/presentation/prompt_assistant/services/prompt_assistant_api_client.dart';
import 'package:nai_launcher/presentation/prompt_assistant/services/prompt_assistant_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Assistant extends Mock implements PromptAssistantService {}

class _Wiki extends Mock implements TagWikiRepository {}

class _Cache extends VisibleTagTranslationCache {
  final values = <String, String>{};
  int revision = 0;
  @override
  int get generation => revision;
  @override
  Future<Map<String, String>> namesFor({
    required Iterable<String> tags,
    required String language,
    required String? route,
    required int maxPromptVersion,
  }) async => {
    for (final tag in tags)
      if (values[tag] case final name?) tag: name,
  };
  @override
  Future<void> put({
    required String tag,
    required String route,
    required int promptVersion,
    required String wikiHash,
    required String nameZh,
    int? expectedGeneration,
    String? wikiZh,
    String? wikiOriginal,
    String? definition,
    String nameLanguage = 'zh',
    String definitionLanguage = 'zh',
  }) async {
    if (expectedGeneration == null || expectedGeneration == revision) {
      values[tag] = nameZh;
    }
  }

  @override
  Future<void> clear() async {
    revision++;
    values.clear();
  }

  @override
  Future<void> close() async {}
}

void main() {
  setUpAll(() => registerFallbackValue(<String>[]));
  late AutoTagTranslationController controller;
  late _Assistant assistant;
  late _Cache cache;
  late List<List<String>> requests, tagRequests;
  late Future<Map<String, String>> Function(List<String>) answer;
  var route = 'model-a', language = 'zh';
  const phrase = 'A girl sits in a garden.';
  Map<String, String> readings(List<String> sources) => {
    for (final s in sources) s: '译：$s',
  };

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    assistant = _Assistant();
    cache = _Cache();
    route = 'model-a';
    language = 'zh';
    requests = [];
    tagRequests = [];
    answer = (sources) async => readings(sources);
    when(() => assistant.translateRouteFingerprint()).thenAnswer((_) => route);
    when(
      () => assistant.cancelCurrentTask(sessionId: any(named: 'sessionId')),
    ).thenAnswer((_) async {});
    when(
      () => assistant.translatePromptReadings(
        any(),
        sessionId: any(named: 'sessionId'),
        canonicalTags: any(named: 'canonicalTags'),
      ),
    ).thenAnswer((call) {
      final sources = call.positionalArguments.single as List<String>;
      requests.add(sources);
      tagRequests.add(call.namedArguments[#canonicalTags] as List<String>);
      return answer(sources);
    });
    controller = AutoTagTranslationController(
      assistant: assistant,
      wiki: _Wiki(),
      cache: cache,
      readingLanguage: () => language,
      closeCacheOnDispose: false,
    );
  });
  void strategyTest(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        controller.dispose();
      }
    });
  }

  Future<void> advance(WidgetTester tester, int ms) async {
    await tester.pump(Duration(milliseconds: ms));
    await tester.pump();
  }

  strategyTest('typing resets the pause and drops every obsolete prefix', (
    tester,
  ) async {
    await controller.setEnabled(true);
    controller.observeNames(surface: 'main', tags: ['l']);
    await advance(tester, 900);
    expect(requests, isEmpty);
    for (final prefix in ['lo', 'lon', 'long']) {
      controller.observeNames(surface: 'main', tags: [prefix]);
      await advance(tester, 600);
      expect(requests, isEmpty);
    }
    await advance(tester, 199);
    expect(requests, isEmpty);
    await advance(tester, 1);
    expect(requests, [
      ['long'],
    ]);
  });

  strategyTest('edits with identical visible names still restart the pause', (
    tester,
  ) async {
    await controller.setEnabled(true);
    controller.observeNames(surface: 'main', tags: ['unknown']);
    await advance(tester, 700);
    controller.deferPromptReadings(surface: 'main', composing: false);
    controller.observeNames(surface: 'main', tags: ['unknown']);
    await advance(tester, 799);
    expect(requests, isEmpty);
    await advance(tester, 1);
    expect(requests, [
      ['unknown'],
    ]);
  });

  strategyTest('sentence edits debounce until the final sentence is idle', (
    tester,
  ) async {
    await controller.setEnabled(true);
    for (final source in [
      'A girl sits.',
      'A girl sits in a garden.',
      'A girl sits in a sunny garden.',
    ]) {
      controller.observePhrases(surface: 'main', phrases: [source]);
      await advance(tester, 500);
      expect(requests, isEmpty);
    }
    await advance(tester, 300);
    expect(requests.single, ['A girl sits in a sunny garden.']);
  });

  strategyTest('IME blocks requests until commit and a full idle interval', (
    tester,
  ) async {
    await controller.setEnabled(true);
    controller.observeNames(surface: 'main', tags: ['unknown']);
    await advance(tester, 700);
    controller.deferPromptReadings(surface: 'main', composing: true);
    await advance(tester, 5000);
    expect(requests, isEmpty);
    controller.deferPromptReadings(surface: 'main', composing: false);
    await advance(tester, 799);
    expect(requests, isEmpty);
    await advance(tester, 1);
    expect(requests, [
      ['unknown'],
    ]);
  });

  strategyTest('tags and sentences across surfaces share one request', (
    tester,
  ) async {
    await controller.setEnabled(true);
    controller.observeNames(surface: 'main', tags: ['long_hair']);
    controller.observeNames(surface: 'role', tags: ['long_hair', 'blue_eyes']);
    controller.observePhrases(surface: 'main', phrases: [phrase]);
    await advance(tester, 800);
    expect(requests, hasLength(1));
    expect(requests.single.toSet(), {'long_hair', 'blue_eyes', phrase});
    expect(tagRequests.single.toSet(), {'long_hair', 'blue_eyes'});
    expect(cache.values.keys.toSet(), {
      'long_hair',
      'blue_eyes',
      'phrase:${AutoTagTranslationController.phraseKey(phrase)}',
    });
  });

  strategyTest(
    'cached readings appear immediately with automatic translation off',
    (tester) async {
      cache.values['long_hair'] = '长发';
      controller.observeNames(surface: 'main', tags: ['long_hair', 'unknown']);
      await advance(tester, 0);
      expect(controller.nameFor('long_hair'), '长发');
      await advance(tester, 5000);
      expect(requests, isEmpty);
      controller.requestMissingNames(surface: 'main');
      await advance(tester, 0);
      expect(requests, [
        ['unknown'],
      ]);
      expect(controller.enabled, isFalse);
    },
  );

  strategyTest('removed surfaces discard tags and phrases before sending', (
    tester,
  ) async {
    await controller.setEnabled(true);
    controller.observeNames(surface: 'main', tags: ['unknown']);
    controller.observePhrases(surface: 'main', phrases: [phrase]);
    await advance(tester, 500);
    controller.clearSurface('main');
    await advance(tester, 5000);
    expect(requests, isEmpty);
  });

  strategyTest('a ready surface is not blocked by typing in another surface', (
    tester,
  ) async {
    await controller.setEnabled(true);
    controller.observeNames(surface: 'main', tags: ['unknown']);
    await advance(tester, 500);
    controller.observePhrases(surface: 'role', phrases: [phrase]);
    controller.deferPromptReadings(surface: 'role', composing: true);
    await advance(tester, 300);
    expect(requests, [
      ['unknown'],
    ]);
  });

  strategyTest('large queues use serial batches of at most eight readings', (
    tester,
  ) async {
    await controller.setEnabled(true);
    final pending = Completer<Map<String, String>>();
    answer = (_) => pending.future;
    controller.observeNames(
      surface: 'main',
      tags: [for (var i = 0; i < 19; i++) 'tag_$i'],
    );
    await advance(tester, 800);
    expect(requests.single, hasLength(8));
    expect(controller.activeRequests, 1);
    expect(controller.isTranslating('tag_0'), isTrue);
    await advance(tester, 5000);
    expect(requests, hasLength(1));
    pending.complete(readings(requests.first));
    answer = (sources) async => readings(sources);
    await advance(tester, 0);
    await advance(tester, 299);
    expect(requests, hasLength(1));
    await advance(tester, 1);
    expect(requests.map((r) => r.length), [8, 8]);
    await advance(tester, 300);
    expect(requests.map((r) => r.length), [8, 8, 3]);
  });

  strategyTest(
    'transient failure retries twice with backoff then waits for manual retry',
    (tester) async {
      await controller.setEnabled(true);
      answer = (_) async =>
          throw PromptAssistantRequestFailure('offline', retryable: true);
      controller.observeNames(surface: 'main', tags: ['unknown']);
      controller.observePhrases(surface: 'main', phrases: [phrase]);
      await advance(tester, 800);
      expect(requests, hasLength(1));
      await advance(tester, 29999);
      expect(requests, hasLength(1));
      await advance(tester, 1);
      expect(requests, hasLength(2));
      await advance(tester, 60000);
      expect(requests, hasLength(3));
      await advance(tester, 600000);
      expect(requests, hasLength(3));
      answer = (sources) async => readings(sources);
      controller.requestMissingNames(surface: 'main');
      await advance(tester, 0);
      expect(requests, hasLength(4));
      expect(controller.nameFor('unknown'), '译：unknown');
      expect(controller.phraseFor(phrase), '译：$phrase');
    },
  );

  strategyTest('rate limit honors Retry-After and retries only current items', (
    tester,
  ) async {
    await controller.setEnabled(true);
    answer = (_) async => throw PromptAssistantRequestFailure(
      'limited',
      retryable: true,
      statusCode: 429,
      retryAfter: const Duration(seconds: 120),
    );
    controller.observeNames(surface: 'main', tags: ['unknown', 'deleted']);
    await advance(tester, 800);
    controller.observeNames(surface: 'main', tags: ['unknown']);
    answer = (sources) async => readings(sources);
    await advance(tester, 119999);
    expect(requests, hasLength(1));
    await advance(tester, 1);
    expect(requests.last, ['unknown']);
  });

  for (final failure in [
    PromptAssistantRequestFailure(
      'HTTP 401',
      retryable: false,
      statusCode: 401,
    ),
    const FormatException('invalid model response'),
  ]) {
    strategyTest('permanent failure $failure does not keep retrying', (
      tester,
    ) async {
      await controller.setEnabled(true);
      answer = (_) async => throw failure;
      controller.observeNames(surface: 'main', tags: ['unknown']);
      await advance(tester, 800);
      await advance(tester, 600000);
      expect(requests, hasLength(1));
      expect(
        controller.activityFor('unknown')!.phase,
        TagTranslationPhase.failed,
      );
    });
  }

  strategyTest(
    'turning auto off cancels in-flight work and scheduled retries',
    (tester) async {
      await controller.setEnabled(true);
      final pending = Completer<Map<String, String>>();
      answer = (_) => pending.future;
      controller.observeNames(surface: 'main', tags: ['unknown']);
      await advance(tester, 800);
      await controller.setEnabled(false);
      pending.complete({'unknown': 'late'});
      await advance(tester, 600000);
      expect(controller.nameFor('unknown'), isNull);
      expect(cache.values, isEmpty);
      expect(requests, hasLength(1));
      verify(
        () => assistant.cancelCurrentTask(sessionId: any(named: 'sessionId')),
      ).called(1);
      answer = (_) async =>
          throw PromptAssistantRequestFailure('offline', retryable: true);
      await controller.setEnabled(true);
      await advance(tester, 0);
      expect(requests, hasLength(2));
      await controller.setEnabled(false);
      await advance(tester, 600000);
      expect(requests, hasLength(2));
    },
  );

  strategyTest('old route cannot overwrite a new route batch', (tester) async {
    await controller.setEnabled(true);
    final old = Completer<Map<String, String>>();
    answer = (_) => old.future;
    controller.observeNames(surface: 'main', tags: ['unknown']);
    await advance(tester, 800);
    route = 'model-b';
    language = 'ja';
    answer = (_) async => {'unknown': '新译名'};
    controller.routeChanged();
    await advance(tester, 0);
    old.complete({'unknown': '旧译名'});
    await advance(tester, 0);
    expect(controller.nameFor('unknown'), '新译名');
    expect(cache.values['unknown'], '新译名');
    expect(requests, hasLength(2));
  });

  strategyTest('clearing cache rejects late results without a fresh request', (
    tester,
  ) async {
    await controller.setEnabled(true);
    final pending = Completer<Map<String, String>>();
    answer = (_) => pending.future;
    controller.observeNames(surface: 'main', tags: ['unknown']);
    await advance(tester, 800);
    await controller.clearCache();
    pending.complete({'unknown': 'late'});
    await advance(tester, 5000);
    expect(requests, hasLength(1));
    expect(cache.values, isEmpty);
    expect(controller.nameFor('unknown'), isNull);
  });

  strategyTest('long sentences are capped by total batch characters', (
    tester,
  ) async {
    await controller.setEnabled(true);
    controller.observePhrases(
      surface: 'main',
      phrases: [for (var i = 0; i < 7; i++) 'Sentence $i ${'long ' * 100}'],
    );
    await advance(tester, 800);
    expect(requests.single.length, 4);
    expect(
      requests.single.fold<int>(0, (sum, text) => sum + text.length),
      lessThanOrEqualTo(2400),
    );
    await advance(tester, 300);
    expect(requests.last.length, 3);
  });

  strategyTest('new fragments cannot bypass a route rate-limit cooldown', (
    tester,
  ) async {
    await controller.setEnabled(true);
    answer = (_) async => throw PromptAssistantRequestFailure(
      'limited',
      retryable: true,
      statusCode: 429,
    );
    controller.observeNames(surface: 'main', tags: ['unknown']);
    await advance(tester, 800);
    controller.observeNames(surface: 'main', tags: ['unknown', 'new_word']);
    answer = (sources) async => readings(sources);
    await advance(tester, 89999);
    expect(requests, hasLength(1));
    await advance(tester, 1);
    expect(requests.last.toSet(), {'unknown', 'new_word'});
  });

  strategyTest(
    'a manual fill joining an in-flight batch survives switching auto off',
    (tester) async {
      await controller.setEnabled(true);
      final pending = Completer<Map<String, String>>();
      answer = (_) => pending.future;
      controller.observeNames(surface: 'main', tags: ['unknown']);
      await advance(tester, 800);
      controller.requestMissingNames(surface: 'main');
      await controller.setEnabled(false);
      pending.complete({'unknown': '主动补译'});
      await advance(tester, 0);
      expect(controller.nameFor('unknown'), '主动补译');
      expect(requests, hasLength(1));
    },
  );

  strategyTest(
    'a model omission does not repeat the successful part of a batch',
    (tester) async {
      await controller.setEnabled(true);
      answer = (_) async => {'known': '已有译名'};
      controller.observeNames(surface: 'main', tags: ['known', 'missing']);
      await advance(tester, 800);
      await advance(tester, 600000);
      expect(requests, hasLength(1));
      answer = (sources) async => readings(sources);
      controller.requestMissingNames(surface: 'main');
      await advance(tester, 0);
      expect(requests.last, ['missing']);
      expect(controller.nameFor('known'), '已有译名');
    },
  );
}
