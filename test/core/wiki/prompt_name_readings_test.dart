import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nai_launcher/core/tag_expansion/tag_semantics_repository.dart';
import 'package:nai_launcher/core/wiki/auto_tag_translation_controller.dart';
import 'package:nai_launcher/core/wiki/tag_wiki_repository.dart';
import 'package:nai_launcher/core/wiki/visible_tag_translation_cache.dart';
import 'package:nai_launcher/presentation/prompt_assistant/services/prompt_assistant_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Assistant extends Mock implements PromptAssistantService {}

class _Wiki implements TagWikiRepository {
  int calls = 0;
  @override
  Future<TagWikiEntry?> find(String tag) async {
    calls++;
    return TagWikiEntry(tag: tag, body: 'A test tag.', sourceUrl: '');
  }
}

class _Semantics extends TagSemanticsRepository {
  _Semantics(this.profiles) : super(() async => throw StateError('Unused'));
  final Map<String, TagSemanticProfile> profiles;
  final List<List<String>> batches = [];
  int singleReads = 0;
  @override
  Future<Map<String, TagSemanticProfile>> findAll(Iterable<String> tags) async {
    batches.add(tags.toList());
    return {
      for (final tag in tags)
        if (profiles[tag] case final p?) tag: p,
    };
  }

  @override
  Future<TagSemanticProfile?> find(String tag) async {
    singleReads++;
    return profiles[tag];
  }
}

class _Cache extends VisibleTagTranslationCache {
  _Cache(String path) : super(databasePath: () async => path);
  int batches = 0;
  int completed = 0;
  @override
  Future<Map<String, String>> namesFor({
    required Iterable<String> tags,
    required String language,
    required String? route,
    required int maxPromptVersion,
  }) async {
    batches++;
    final result = await super.namesFor(
      tags: tags,
      language: language,
      route: route,
      maxPromptVersion: maxPromptVersion,
    );
    completed++;
    return result;
  }
}

const _grass = TagSemanticProfile(
  tag: 'grass',
  coreZh: '草地',
  synonymsZh: [],
  summaryZh: '',
  sourceCategory: 0,
  sourcePostCount: 1,
);

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 2000; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Timed out');
}

void _respond(
  _Assistant assistant,
  Future<VisibleTagTranslationResult> Function(Invocation) handler,
) {
  when(
    () => assistant.cancelCurrentTask(sessionId: any(named: 'sessionId')),
  ).thenAnswer((_) async {});
  when(
    () => assistant.translatePromptReadings(
      any(),
      sessionId: any(named: 'sessionId'),
      canonicalTags: any(named: 'canonicalTags'),
    ),
  ).thenAnswer((call) async {
    final result = await handler(call);
    return {
      for (final tag in call.positionalArguments.first as List<String>)
        tag: result.nameZh,
    };
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(<String>[]));
  late Directory folder;
  late _Cache cache;
  late _Assistant assistant;
  late _Wiki wiki;
  late _Semantics semantics;
  late AutoTagTranslationController controller;
  var route = 'route-a';
  var language = 'zh';
  var calls = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    folder = await Directory.systemTemp.createTemp('prompt-name-readings-');
    cache = _Cache('${folder.path}/cache.db');
    assistant = _Assistant();
    wiki = _Wiki();
    semantics = _Semantics({'grass': _grass});
    route = 'route-a';
    language = 'zh';
    calls = 0;
    when(() => assistant.translateRouteFingerprint()).thenAnswer((_) => route);
    _respond(assistant, (call) async {
      calls++;
      return const VisibleTagTranslationResult(nameZh: '新译名');
    });
    controller = AutoTagTranslationController(
      assistant: assistant,
      wiki: wiki,
      cache: cache,
      semantics: semantics,
      readingLanguage: () => language,
      closeCacheOnDispose: false,
    );
  });

  tearDown(() async {
    controller.dispose();
    await cache.close();
    await folder.delete(recursive: true);
  });

  Future<void> save(
    String tag,
    String name, {
    String lang = 'zh',
    String? model,
  }) => cache.put(
    tag: tag,
    route: model ?? route,
    promptVersion: PromptAssistantService.visibleTagTranslationPromptVersion,
    wikiHash: 'old-wiki',
    nameZh: name,
    nameLanguage: lang,
  );

  test(
    'batches surfaces and reads cache before partial semantic labels',
    () async {
      await save('grass', '个人译名');
      await save('blue_eyes', '蓝眼');
      await controller.setEnabled(true);
      controller.observeNames(surface: 'main', tags: ['Grass', 'blue eyes']);
      controller.observeNames(surface: 'character', tags: ['grass']);
      await _until(() => controller.nameFor('blue_eyes') == '蓝眼');
      expect(controller.nameFor('grass'), '个人译名');
      expect(cache.batches, 1);
      expect(semantics.batches.single.toSet(), {'grass', 'blue_eyes'});
      expect(semantics.singleReads, 0);
      expect(wiki.calls, 0);
      expect(calls, 0);
      // Rebuilding or observing the same name on another surface does no I/O.
      controller.observeNames(surface: 'main', tags: ['grass', 'blue_eyes']);
      controller.observeNames(surface: 'negative', tags: ['grass']);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(cache.batches, 1);
      expect(calls, 0);
    },
  );

  test(
    'automatic AI off still reads saved names and local partial profiles',
    () async {
      await save('blue_eyes', '蓝眼');
      controller.observeNames(
        surface: 'main',
        tags: ['grass', 'blue_eyes', 'unknown'],
      );
      await _until(() => controller.nameFor('blue_eyes') == '蓝眼');
      expect(controller.nameFor('grass'), '草地');
      expect(controller.nameFor('unknown'), isNull);
      expect(controller.activityFor('unknown'), isNull);
      expect(calls, 0);
    },
  );

  test(
    'without a model, same-language historical names remain readable',
    () async {
      await save('blue_eyes', '蓝眼');
      await save('red_eyes', '赤い目', lang: 'ja');
      route = '';
      await controller.setEnabled(true);
      controller.observeNames(
        surface: 'main',
        tags: ['grass', 'blue_eyes', 'red_eyes'],
      );
      await _until(() => controller.nameFor('blue_eyes') == '蓝眼');
      expect(controller.nameFor('grass'), '草地');
      expect(controller.nameFor('red_eyes'), isNull);
      expect(controller.activityFor('red_eyes'), isNull);
      expect(calls, 0);
    },
  );

  test(
    'one in-flight request serves the same missing tag across surfaces',
    () async {
      final result = Completer<VisibleTagTranslationResult>();
      _respond(assistant, (_) {
        calls++;
        return result.future;
      });
      await controller.setEnabled(true);
      controller.observeNames(surface: 'main', tags: ['unknown']);
      controller.observeNames(surface: 'negative', tags: ['unknown']);
      await _until(() => calls == 1);
      controller.clearSurface('main');
      result.complete(const VisibleTagTranslationResult(nameZh: '共享译名'));
      await _until(() => controller.activeRequests == 0);
      expect(controller.nameFor('unknown'), '共享译名');
      expect(calls, 1);
      expect(
        (await cache.namesFor(
          tags: ['unknown'],
          language: 'zh',
          route: route,
          maxPromptVersion:
              PromptAssistantService.visibleTagTranslationPromptVersion,
        ))['unknown'],
        '共享译名',
      );
    },
  );

  test(
    'explicit fill works while AI is off and leaves known names alone',
    () async {
      controller.observeNames(surface: 'main', tags: ['grass', 'unknown']);
      controller.requestMissingNames(surface: 'main');
      await _until(() => controller.nameFor('unknown') == '新译名');
      expect(controller.nameFor('grass'), '草地');
      expect(calls, 1);
      expect(controller.enabled, isFalse);
      controller.requestMissingNames(surface: 'main');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls, 1);
    },
  );

  test(
    'route and language changes reload isolated names with AI off',
    () async {
      await save('unknown', '甲模型', model: 'route-a');
      await save('unknown', '乙模型', model: 'route-b');
      await save('unknown', '日本語', model: 'route-ja', lang: 'ja');
      controller.observeNames(surface: 'main', tags: ['grass', 'unknown']);
      await _until(() => controller.nameFor('unknown') == '甲模型');
      route = 'route-b';
      controller.routeChanged();
      await _until(() => controller.nameFor('unknown') == '乙模型');
      language = 'ja';
      route = 'route-ja';
      controller.routeChanged();
      await _until(() => controller.nameFor('unknown') == '日本語');
      expect(controller.nameFor('grass'), isNull);
      expect(calls, 0);
    },
  );

  test(
    'a late old-route response cannot replace a newly loaded reading',
    () async {
      final result = Completer<VisibleTagTranslationResult>();
      _respond(assistant, (_) {
        calls++;
        return result.future;
      });
      await controller.setEnabled(true);
      controller.observeNames(surface: 'main', tags: ['unknown']);
      await _until(() => calls == 1);
      await save('unknown', '当前模型缓存', model: 'route-b');
      route = 'route-b';
      controller.routeChanged();
      await _until(() => controller.nameFor('unknown') == '当前模型缓存');
      result.complete(const VisibleTagTranslationResult(nameZh: '旧模型结果'));
      await _until(() => controller.activeRequests == 0);
      expect(controller.nameFor('unknown'), '当前模型缓存');
      expect(
        await cache.namesFor(
          tags: ['unknown'],
          language: 'zh',
          route: 'route-a',
          maxPromptVersion:
              PromptAssistantService.visibleTagTranslationPromptVersion,
        ),
        isEmpty,
      );
      expect(calls, 1);
    },
  );

  test(
    'clearing cache rejects a late model result without enqueueing another',
    () async {
      final result = Completer<VisibleTagTranslationResult>();
      _respond(assistant, (_) {
        calls++;
        return result.future;
      });
      await controller.setEnabled(true);
      controller.observeNames(surface: 'main', tags: ['grass', 'unknown']);
      await _until(() => calls == 1);
      await controller.clearCache();
      result.complete(const VisibleTagTranslationResult(nameZh: '过期结果'));
      await _until(
        () =>
            controller.activeRequests == 0 &&
            controller.nameFor('grass') == '草地',
      );
      expect(controller.nameFor('unknown'), isNull);
      expect(
        await cache.namesFor(
          tags: ['unknown'],
          language: 'zh',
          route: route,
          maxPromptVersion:
              PromptAssistantService.visibleTagTranslationPromptVersion,
        ),
        isEmpty,
      );
      expect(calls, 1);
    },
  );
}
