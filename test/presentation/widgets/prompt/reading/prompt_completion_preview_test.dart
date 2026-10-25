import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/tag_expansion/tag_semantics_repository.dart';
import 'package:nai_launcher/core/wiki/tag_wiki_repository.dart';
import 'package:nai_launcher/data/datasources/remote/danbooru_api_service.dart';
import 'package:nai_launcher/presentation/widgets/prompt/reading/prompt_completion_preview.dart';

class _Semantics extends TagSemanticsRepository {
  _Semantics({this.missing})
    : super(() async => throw StateError('No asset/database access'));
  final String? missing;
  @override
  Future<TagSemanticProfile?> find(String tag) async => tag == missing
      ? null
      : TagSemanticProfile(
          tag: tag,
          synonymsZh: const ['长头发'],
          coreZh: '长发',
          summaryZh: '长发的角色。',
          sourceCategory: 0,
          sourcePostCount: 10,
        );
}

class _Wiki implements TagWikiRepository {
  _Wiki(this.body);
  final String? body;
  @override
  Future<TagWikiEntry?> find(String tag) async => body == null
      ? null
      : TagWikiEntry(
          tag: tag,
          body: body!,
          sourceUrl: 'https://danbooru.donmai.us',
        );
}

class _Api extends DanbooruApiService {
  _Api(this.response) : super(Dio());
  final Future<Map<String, dynamic>?> Function() response;
  int calls = 0;
  CancelToken? token;
  @override
  Future<Map<String, dynamic>?> getWikiPage(
    String title, {
    CancelToken? cancelToken,
  }) {
    calls++;
    token = cancelToken;
    return response();
  }
}

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue, reason: 'Preview state did not settle');
}

ProviderContainer _container(
  _Api api, {
  String? local,
  String? missingSemantic,
}) => ProviderContainer(
  overrides: [
    tagSemanticsRepositoryProvider.overrideWithValue(
      _Semantics(missing: missingSemantic),
    ),
    tagWikiRepositoryProvider.overrideWithValue(_Wiki(local)),
    danbooruApiServiceProvider.overrideWithValue(api),
  ],
);

void main() {
  test('alias-only semantic summary survives canonical resolution', () async {
    final api = _Api(() async => throw StateError('No network expected'));
    final scope = _container(
      api,
      local: 'Current canonical Wiki.',
      missingSemantic: 'current_tag',
    );
    addTearDown(scope.dispose);
    const query = (tag: 'current_tag', online: false);
    final states = <PromptCompletionPreviewData>[];
    final listener = scope.listen(promptCompletionPreviewProvider(query), (
      _,
      next,
    ) {
      if (next.asData case final data?) states.add(data.value);
    });
    addTearDown(listener.close);
    await until(() => states.isNotEmpty);
    final fallback = await scope.read(
      promptCompletionSemanticProfileProvider('old_alias').future,
    );
    expect(states.single.profile, isNull);
    expect(fallback?.tag, 'old_alias');
    expect(states.single.wiki?.tag, 'current_tag');
    expect(api.calls, 0);
  });

  test('local Wiki and semantics need no network request', () async {
    final api = _Api(() async => throw StateError('No network expected'));
    final scope = _container(
      api,
      local: 'Long hair extends below the shoulders.',
    );
    addTearDown(scope.dispose);
    const query = (tag: 'long_hair', online: true);
    final states = <PromptCompletionPreviewData>[];
    final listener = scope.listen(promptCompletionPreviewProvider(query), (
      _,
      next,
    ) {
      if (next.asData case final data?) states.add(data.value);
    }, fireImmediately: true);
    addTearDown(listener.close);
    await until(() => states.isNotEmpty);
    expect(states.last.profile?.coreZh, '长发');
    expect(states.last.wiki?.body, startsWith('Long hair'));
    expect(api.calls, 0);
  });

  test(
    'shared previews publish local summary first and cancel when last viewer closes',
    () async {
      final pending = Completer<Map<String, dynamic>?>();
      final api = _Api(() => pending.future);
      final scope = _container(api);
      addTearDown(scope.dispose);
      const query = (tag: 'long_hair', online: true);
      final states = <PromptCompletionPreviewData>[];
      final first = scope.listen(promptCompletionPreviewProvider(query), (
        _,
        next,
      ) {
        if (next.asData case final data?) states.add(data.value);
      });
      final second = scope.listen(
        promptCompletionPreviewProvider(query),
        (_, __) {},
      );
      await until(() => api.calls == 1 && states.isNotEmpty);
      expect(states.single.loadingOnline, isTrue);
      expect(states.single.profile?.summaryZh, '长发的角色。');
      first.close();
      await Future<void>.delayed(Duration.zero);
      expect(api.token?.isCancelled, isFalse);
      second.close();
      await Future<void>.delayed(Duration.zero);
      expect(api.token?.isCancelled, isTrue);
      pending.complete({'body': 'Too late.'});
      await Future<void>.delayed(Duration.zero);
      expect(
        scope.read(promptCompletionWikiCacheProvider).get('long_hair'),
        isNull,
      );
    },
  );

  test(
    'missing remote article is cached but transient errors remain retryable',
    () async {
      var fail = true;
      final api = _Api(() async {
        if (fail) throw const FormatException('temporary failure');
        return null;
      });
      final scope = _container(api);
      addTearDown(scope.dispose);
      const query = (tag: 'long_hair', online: true);
      final states = <PromptCompletionPreviewData>[];
      final listener = scope.listen(promptCompletionPreviewProvider(query), (
        _,
        next,
      ) {
        if (next.asData case final data?) states.add(data.value);
      });
      addTearDown(listener.close);
      await until(() => states.any((s) => s.failed && !s.loadingOnline));
      expect(
        scope.read(promptCompletionWikiCacheProvider).get('long_hair'),
        isNull,
      );
      fail = false;
      scope.invalidate(promptCompletionPreviewProvider(query));
      await until(
        () =>
            api.calls == 2 &&
            scope.read(promptCompletionWikiCacheProvider).get('long_hair') !=
                null,
      );
      scope.invalidate(promptCompletionPreviewProvider(query));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(api.calls, 2);
    },
  );
}
