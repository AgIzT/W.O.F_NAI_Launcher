// Standalone native probe. Pass an output JSON path and the repository root.
// Build in an isolated runner; this entry point never starts app storage/models.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nai_launcher/core/autocomplete/chinese_tag_completion_source.dart';
import 'package:nai_launcher/core/autocomplete/completion_models.dart';
import 'package:nai_launcher/core/autocomplete/tag_catalog_repository.dart';
import 'package:nai_launcher/core/autocomplete/unified_tag_repository.dart';
import 'package:nai_launcher/core/tag_expansion/tag_semantics_repository.dart';
import 'package:nai_launcher/core/wiki/auto_tag_translation_controller.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/widgets/common/themed_input.dart';
import 'package:nai_launcher/presentation/widgets/prompt/nai_syntax_controller.dart';
import 'package:nai_launcher/presentation/widgets/prompt/reading/prompt_completion_wrapper.dart';
import 'package:nai_launcher/presentation/widgets/prompt/reading/prompt_reading_layer.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Readings extends ChangeNotifier implements AutoTagTranslationController {
  int maxVisible = 0;
  @override
  String? nameFor(String tag) => tag.startsWith('tag_') ? '标签译名' : '长发';
  @override
  void observeNames({required String surface, required Iterable<String> tags}) {
    maxVisible = math.max(maxVisible, tags.length);
  }

  @override
  void clearSurface(String surface) {}
  @override
  void observe({
    required String surface,
    required String tag,
    required bool visible,
    String? existingNameZh,
    AutoTagTranslationContext? tagContext,
    TagReadingIntent intent = TagReadingIntent.details,
  }) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (arguments.length != 2) exit(2);
  final output = File(arguments[0]);
  try {
    final report = await measure(arguments[1]);
    await output.parent.create(recursive: true);
    await output.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    exit(0);
  } catch (error, stack) {
    await output.writeAsString(
      jsonEncode({'error': '$error', 'stack': '$stack'}),
    );
    exit(1);
  }
}

Future<Map<String, Object?>> measure(String root) async {
  sqfliteFfiInit();
  final catalogPath = p.join(root, 'assets/databases/tag_catalog.db');
  final catalog = TagCatalogRepository(path: () async => catalogPath);
  final semantics = TagSemanticsRepository(
    () async => p.join(root, 'assets/databases/tag_semantics.db'),
    catalogPath: () async => catalogPath,
  );
  final unified = UnifiedTagRepository(
    catalog: catalog,
    runtime: () => throw StateError('Probe must not access runtime storage'),
    unionDatabase: ({required includeWiki}) => databaseFactoryFfi.openDatabase(
      catalogPath,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    ),
  );
  final chinese = ChineseTagCompletionSource(
    searchNames: semantics.searchNameMatches,
    resolveNames: unified.resolveExact,
  );
  final searches = <String, Object?>{};
  for (final term in ['long ha', '长发', '初音', '初音未来']) {
    final times = <int>[];
    List<CompletionCandidate> results = [];
    for (var i = 0; i < 6; i++) {
      final watch = Stopwatch()..start();
      results = term == 'long ha'
          ? await catalog.search(
              CompletionQuery(
                fullText: term,
                cursorPosition: term.length,
                token: term,
                replacementRange: TextReplacementRange(
                  start: 0,
                  end: term.length,
                ),
                existingTags: const {},
                limit: 20,
                locale: 'zh',
              ),
            )
          : await chinese.search(term, limit: 20);
      times.add(watch.elapsedMicroseconds);
    }
    searches[term] = {
      'first_us': times.first,
      'warm_us': times.skip(1).toList(),
      'first_tag': results.isEmpty ? null : results.first.canonicalTag,
      'count': results.length,
    };
  }
  final batch = (await catalog.popular(
    limit: 50,
  )).map((c) => c.canonicalTag).toList();
  final batchTimes = <int>[];
  for (var i = 0; i < 6; i++) {
    final watch = Stopwatch()..start();
    await semantics.findAll(batch);
    batchTimes.add(watch.elapsedMicroseconds);
  }
  await catalog.dispose();

  final readings = _Readings();
  final editor = NaiSyntaxController(text: 'long hair, blue eyes');
  final focus = FocusNode();
  final scroll = ScrollController();
  runApp(
    ProviderScope(
      overrides: [
        autoTagTranslationProvider.overrideWith((ref) => readings),
        promptCompletionSearchProvider.overrideWithValue(
          (query) async => const [
            CompletionCandidate(
              canonicalTag: 'long_hair',
              category: TagCategory.general,
              postCount: 100,
              matchKind: CompletionMatchKind.englishPrefix,
              sources: {CompletionSourceKind.base},
            ),
          ],
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(fontFamily: 'HarmonyOS Sans SC'),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(30),
            child: SingleChildScrollView(
              controller: scroll,
              child: SizedBox(
                width: 600,
                child: PromptCompletionWrapper(
                  controller: editor,
                  focusNode: focus,
                  scope: 'benchmark',
                  child: PromptReadingLayer(
                    controller: editor,
                    enabled: true,
                    style: const TextStyle(fontSize: 10, height: 1),
                    child: ThemedInput(
                      controller: editor,
                      focusNode: focus,
                      maxLines: null,
                      minLines: 3,
                      style: const TextStyle(
                        fontSize: 16,
                        height: PromptReadingLayer.lineHeight,
                        leadingDistribution: TextLeadingDistribution.even,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await Future<void>.delayed(const Duration(seconds: 2));
  final rows = <ui.FrameTiming>[];
  void timings(List<ui.FrameTiming> batch) => rows.addAll(batch);
  SchedulerBinding.instance.addTimingsCallback(timings);
  final frames = <String, Object?>{};
  Future<void> drive(String name, void Function(int tick) action) async {
    rows.clear();
    final start = developer.Timeline.now;
    final done = Completer<void>();
    var ticks = 0;
    final ticker = Ticker((elapsed) {
      if (elapsed.inSeconds >= 5) {
        if (!done.isCompleted) done.complete();
        return;
      }
      action(ticks++);
    })..start();
    await done.future;
    ticker.dispose();
    final end = developer.Timeline.now;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    frames[name] = [
      for (final row in rows)
        if (row.timestampInMicroseconds(ui.FramePhase.vsyncStart) >= start &&
            row.timestampInMicroseconds(ui.FramePhase.vsyncStart) <= end)
          {
            'build_us': row.buildDuration.inMicroseconds,
            'raster_us': row.rasterDuration.inMicroseconds,
            'total_us': row.totalSpan.inMicroseconds,
          },
    ];
  }

  focus.requestFocus();
  await drive('typing_with_completion', (i) {
    if (i % 24 != 0) return;
    final text = i % 48 == 0 ? 'long ha' : 'long hair, blue ey';
    editor.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  });
  focus.unfocus();
  editor.text = List.generate(
    600,
    (i) => 'tag_$i, long hair, blue eyes',
  ).join(',\n');
  await Future<void>.delayed(const Duration(seconds: 1));
  await drive(
    'scroll_600_lines',
    (i) => scroll.jumpTo(
      (math.sin(i / 90) + 1) / 2 * scroll.position.maxScrollExtent,
    ),
  );
  SchedulerBinding.instance.removeTimingsCallback(timings);
  return {
    'mode': 'release native production input components; isolated synthetic UI',
    'search': searches,
    'visible_batch_size': batch.length,
    'visible_batch_us': batchTimes,
    'max_visible_names': readings.maxVisible,
    'frames': frames,
    'limitations':
        'Engine timings, not presented FPS. Cold means first query in this process; OS cache not flushed. No app bootstrap, account, network model or generation.',
  };
}
