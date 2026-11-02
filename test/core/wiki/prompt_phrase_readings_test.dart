import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nai_launcher/core/wiki/auto_tag_translation_controller.dart';
import 'package:nai_launcher/core/wiki/tag_wiki_repository.dart';
import 'package:nai_launcher/core/wiki/visible_tag_translation_cache.dart';
import 'package:nai_launcher/presentation/prompt_assistant/services/prompt_assistant_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Assistant extends Mock implements PromptAssistantService {}

class _Wiki implements TagWikiRepository {
  @override
  Future<TagWikiEntry?> find(String tag) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 3000; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Timed out');
}

const _sitting = 'a girl sitting on a bench in the park at sunset';
const _field = 'She stands in a flower field.';
const _sky = 'The sky behind her is full of soft pink clouds.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(<String>[]));
  late Directory folder;
  late VisibleTagTranslationCache cache;
  late _Assistant assistant;
  late AutoTagTranslationController controller;
  late List<List<String>> requests;
  late Future<Map<String, String>> Function(List<String>) answer;
  var route = 'route-a';

  AutoTagTranslationController create() => AutoTagTranslationController(
    assistant: assistant,
    wiki: _Wiki(),
    cache: cache,
    readingLanguage: () => 'zh',
    closeCacheOnDispose: false,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    folder = await Directory.systemTemp.createTemp('prompt-phrase-readings-');
    cache = VisibleTagTranslationCache(
      databasePath: () async => '${folder.path}/cache.db',
    );
    assistant = _Assistant();
    route = 'route-a';
    requests = [];
    answer = (phrases) async => {for (final p in phrases) p: '译：$p'};
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
      final phrases = call.positionalArguments.first as List<String>;
      requests.add(phrases);
      return answer(phrases);
    });
    controller = create();
  });

  tearDown(() async {
    controller.dispose();
    await cache.close();
    await folder.delete(recursive: true);
  });

  test('cached phrase readings appear without a model request', () async {
    await cache.put(
      tag: 'phrase:${AutoTagTranslationController.phraseKey(_sitting)}',
      route: route,
      promptVersion:
          PromptAssistantService.promptReadingTranslationPromptVersion,
      wikiHash: '',
      nameZh: '一个女孩在日落时分坐在公园长椅上',
    );
    await controller.setEnabled(true);
    // Case and spacing do not change the key.
    controller.observePhrases(
      surface: 'main',
      phrases: ['A girl  sitting on a bench in the park at sunset'],
    );
    await _until(() => controller.phraseFor(_sitting) != null);
    expect(controller.phraseFor(_sitting), '一个女孩在日落时分坐在公园长椅上');
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(requests, isEmpty);
  });

  test(
    'visible phrases across surfaces share one batched request and cache',
    () async {
      await controller.setEnabled(true);
      controller.observePhrases(surface: 'main', phrases: [_sitting, _field]);
      controller.observePhrases(surface: 'character', phrases: [_sky]);
      await _until(() => controller.phraseFor(_sky) != null);
      expect(requests, hasLength(1));
      expect(requests.single.toSet(), {_sitting, _field, _sky});
      expect(controller.phraseFor(_field), '译：$_field');

      // A fresh controller reads the persisted readings back.
      controller.dispose();
      controller = create();
      await controller.setEnabled(true);
      controller.observePhrases(surface: 'main', phrases: [_field]);
      await _until(() => controller.phraseFor(_field) != null);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(requests, hasLength(1));
    },
  );

  test(
    'automatic translation off: only filling missing readings asks',
    () async {
      controller.observePhrases(surface: 'main', phrases: [_sitting]);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(requests, isEmpty);
      expect(controller.phraseFor(_sitting), isNull);
      controller.requestMissingNames(surface: 'main');
      await _until(() => controller.phraseFor(_sitting) != null);
      expect(requests.single, [_sitting]);
    },
  );

  test('phrases scrolled away before the pause are not requested', () async {
    await controller.setEnabled(true);
    controller.observePhrases(surface: 'main', phrases: [_sitting]);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    controller.observePhrases(surface: 'main', phrases: const []);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(requests, isEmpty);
  });

  test('a route change discards readings from the previous route', () async {
    final pending = Completer<Map<String, String>>();
    answer = (_) => pending.future;
    await controller.setEnabled(true);
    controller.observePhrases(surface: 'main', phrases: [_sitting]);
    await _until(() => requests.isNotEmpty);
    route = 'route-b';
    answer = (phrases) async => {for (final p in phrases) p: '新路由'};
    controller.routeChanged();
    pending.complete({_sitting: '旧路由'});
    await _until(() => controller.phraseFor(_sitting) != null);
    expect(controller.phraseFor(_sitting), '新路由');
    expect(requests, hasLength(2));
  });

  test('without a configured model nothing is requested', () async {
    route = '';
    controller.observePhrases(surface: 'main', phrases: [_sitting]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    controller.requestMissingNames(surface: 'main');
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(requests, isEmpty);
    expect(controller.phraseFor(_sitting), isNull);
  });

  test('a failed batch is not retried until explicitly requested', () async {
    answer = (_) async => throw StateError('offline');
    await controller.setEnabled(true);
    controller.observePhrases(surface: 'main', phrases: [_sitting]);
    await _until(() => requests.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    controller.observePhrases(surface: 'main', phrases: [_sitting, _field]);
    await _until(() => requests.length == 2);
    expect(requests.last, [_field]);
    answer = (phrases) async => {for (final p in phrases) p: '重试'};
    // An explicit request retries every visible phrase still missing.
    controller.requestMissingNames(surface: 'main');
    await _until(() => controller.phraseFor(_field) != null);
    expect(requests.last, [_sitting, _field]);
    expect(controller.phraseFor(_sitting), '重试');
  });
}
