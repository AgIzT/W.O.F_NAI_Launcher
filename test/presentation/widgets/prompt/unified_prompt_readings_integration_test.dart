import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/autocomplete/completion_models.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/core/storage/pill_workspace_storage.dart';
import 'package:nai_launcher/core/tag_expansion/local_tag_expansion_service.dart';
import 'package:nai_launcher/core/tag_expansion/tag_expansion_providers.dart';
import 'package:nai_launcher/core/wiki/tag_wiki_repository.dart';
import 'package:nai_launcher/data/models/character/character_prompt.dart';
import 'package:nai_launcher/data/models/image/image_params.dart'
    show ImageParams;
import 'package:nai_launcher/data/models/prompt_block/pill_document.dart';
import 'package:nai_launcher/data/models/prompt_block/prompt_block.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/providers/character_prompt_provider.dart';
import 'package:nai_launcher/presentation/providers/generation/generation_params_notifier.dart';
import 'package:nai_launcher/presentation/providers/pill_workspace_provider.dart';
import 'package:nai_launcher/presentation/providers/prompt_block_library_provider.dart';
import 'package:nai_launcher/presentation/providers/prompt_reading_preferences_provider.dart';
import 'package:nai_launcher/presentation/providers/tips_provider.dart';
import 'package:nai_launcher/presentation/ui/gen/gen_contract.dart';
import 'package:nai_launcher/presentation/ui/kit/ui_block_pill.dart';
import 'package:nai_launcher/presentation/widgets/prompt/pills/prompt_pill_editor.dart';
import 'package:nai_launcher/presentation/widgets/prompt/reading/prompt_completion_wrapper.dart';
import 'package:nai_launcher/presentation/widgets/prompt/reading/prompt_reading_layer.dart';
import 'package:nai_launcher/presentation/widgets/prompt/unified/unified_prompt_config.dart';
import 'package:nai_launcher/presentation/widgets/prompt/unified/unified_prompt_input.dart';
import 'package:nai_launcher/presentation/widgets/tag_expansion/tag_expansion_wrapper.dart';
import 'package:nai_launcher/presentation/wiring/generation_editor_wiring.dart';

import '../../../helpers/studio_capture_fonts.dart';
import '../../../helpers/prompt_reading_test_overrides.dart';

// No real model, settings, draft storage or catalog may be reached by this suite.
class _Storage extends LocalStorageService {
  @override
  T? getSetting<T>(String key, {T? defaultValue}) => defaultValue;
  @override
  Future<void> setSetting<T>(String key, T value) async {}
  @override
  bool getEnablePromptWeightScroll() => false;
  @override
  String getPromptWeightScrollModifier() => 'alt';
  @override
  bool getAutoFormatPrompt() => false;
  @override
  bool getHighlightEmphasis() => true;
  @override
  bool getSdSyntaxAutoConvert() => false;
}

class _WorkspaceStorage extends PillWorkspaceStorage {
  @override
  PillDocument? tryLoadSync(String scope) => null;
  @override
  Future<void> persist(String scope, PillDocument document) async {}
}

class _Preferences extends PromptReadingPreferencesNotifier {
  @override
  PromptReadingPreferences build() => const PromptReadingPreferences();
  @override
  Future<void> setShowReadings(bool value) async {
    state = PromptReadingPreferences(
      showReadings: value,
      completionEnabled: state.completionEnabled,
    );
  }
}

class _Blocks extends PromptBlockLibraryNotifier {
  @override
  Future<PromptBlockLibraryState> build() async => PromptBlockLibraryState(
    blocks: [
      PromptBlock(
        id: 'manual',
        title: 'Manual · 手动块',
        content: 'cinematic light',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    ],
    folders: [],
  );
}

class _Params extends GenerationParamsNotifier {
  @override
  ImageParams build() => const ImageParams(
    prompt: 'long hair, blue eyes',
    negativePrompt: 'bad hands',
  );
  @override
  void updatePromptImmediately(String prompt) {
    state = state.copyWith(prompt: prompt);
  }

  @override
  void updateNegativePromptImmediately(String prompt) {
    state = state.copyWith(negativePrompt: prompt);
  }
}

class _Characters extends CharacterPromptNotifier {
  @override
  CharacterPromptConfig build() => const CharacterPromptConfig(
    characters: [
      CharacterPrompt(
        id: 'test',
        name: 'Test',
        prompt: 'smile',
        negativePrompt: 'blurry',
      ),
    ],
  );
  @override
  void updateCharacter(CharacterPrompt character) {
    state = state.updateCharacter(character);
  }
}

class _Source implements CompletionSource {
  @override
  Future<List<CompletionCandidate>> search(CompletionQuery query) async => [];
}

class _Wiki implements TagWikiRepository {
  @override
  Future<TagWikiEntry?> find(String tag) async => null;
}

ProviderContainer _container(PromptReadingTestController readings) =>
    ProviderContainer(
      overrides: [
        localStorageServiceProvider.overrideWithValue(_Storage()),
        pillWorkspaceStorageProvider.overrideWithValue(_WorkspaceStorage()),
        promptReadingPreferencesProvider.overrideWith(_Preferences.new),
        ...promptReadingTestOverrides(readings: readings),
        promptBlockLibraryNotifierProvider.overrideWith(_Blocks.new),
        generationParamsNotifierProvider.overrideWith(_Params.new),
        characterPromptNotifierProvider.overrideWith(_Characters.new),
        tipEpochProvider.overrideWith((ref) => Stream.value(0)),
        localTagExpansionServiceProvider.overrideWithValue(
          LocalTagExpansionService(
            catalog: _Source(),
            relatedTags: _Source(),
            substringSearch: (_, {limit = 20}) async => [],
            popularSearch: ({limit = 12}) async => [],
          ),
        ),
        tagWikiRepositoryProvider.overrideWithValue(_Wiki()),
        promptCompletionSearchProvider.overrideWithValue(
          (query) async => [
            const CompletionCandidate(
              canonicalTag: 'long_hair',
              category: TagCategory.general,
              postCount: 100,
              matchKind: CompletionMatchKind.englishPrefix,
              sources: {CompletionSourceKind.base},
            ),
          ],
        ),
      ],
    );

const _boundary = Key('integration-reading-capture');
Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget child, {
  Locale locale = const Locale('en'),
  Brightness brightness = Brightness.light,
  double width = 600,
  double scale = 1,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          platform: TargetPlatform.windows,
          brightness: brightness,
          fontFamily: 'Geist',
          fontFamilyFallback: const ['HarmonyOS Sans SC', 'Pretendard'],
        ),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: RepaintBoundary(
          key: _boundary,
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: width, height: 320, child: child),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _shortcut(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  setUpAll(loadStudioCaptureFonts);

  for (final scenario in [
    ('main', const GenEditorTarget.base()),
    ('negative', const GenEditorTarget.base(negative: true)),
    ('char:test:pos', const GenEditorTarget.character(0)),
    ('char:test:neg', const GenEditorTarget.character(0, negative: true)),
    ('main', const GenEditorTarget.base(fullscreen: true)),
  ]) {
    testWidgets(
      'reading display preserves ${scenario.$1} fullscreen=${scenario.$2.fullscreen} draft',
      (tester) async {
        final readings = PromptReadingTestController();
        final container = _container(readings);
        addTearDown(container.dispose);
        await _pump(
          tester,
          container,
          GenerationEditorWiring(target: scenario.$2),
        );
        expect(
          tester
              .widget<PromptPillEditor>(find.byType(PromptPillEditor))
              .pillScope,
          scenario.$1,
        );
        final workspace = container.read(pillWorkspaceProvider(scenario.$1));
        final revision = container.read(pillWorkspaceRevisionProvider);
        final params = container.read(generationParamsNotifierProvider);
        final characters = container.read(characterPromptNotifierProvider);
        final editor = tester
            .widget<EditableText>(find.byType(EditableText))
            .controller;
        editor.selection = TextSelection.collapsed(offset: editor.text.length);
        final before = editor.value;
        final prefs = container.read(promptReadingPreferencesProvider.notifier);
        await prefs.setShowReadings(false);
        await tester.pump();
        expect(
          tester
              .widget<PromptReadingLayer>(find.byType(PromptReadingLayer))
              .enabled,
          isFalse,
        );
        readings.reveal({
          'long_hair': '长发',
          'blue_eyes': '蓝眼',
          'bad_hands': '手部缺陷',
          'smile': '微笑',
          'blurry': '模糊',
        });
        await tester.pump();
        await prefs.setShowReadings(true);
        await tester.pump();
        expect(editor.value, before);
        expect(container.read(pillWorkspaceRevisionProvider), revision);
        expect(container.read(pillWorkspaceProvider(scenario.$1)), workspace);
        expect(container.read(generationParamsNotifierProvider), params);
        expect(container.read(characterPromptNotifierProvider), characters);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'find, replace and native undo retain their text semantics with async readings',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final readings = PromptReadingTestController();
      final container = _container(readings);
      addTearDown(container.dispose);
      await _pump(
        tester,
        container,
        const PromptPillEditor(
          initialPlainText: 'blue eyes, blue hair',
          config: UnifiedPromptConfig(enableAutoFormat: false),
        ),
      );
      final editable = find.byType(EditableText).first;
      final controller = tester.widget<EditableText>(editable).controller;
      await tester.tap(editable);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.enterText(editable, 'blue eyes, blue hair, smile');
      await tester.pump(const Duration(milliseconds: 600));
      final before = controller.value;
      readings.reveal({'blue_eyes': '蓝眼', 'blue_hair': '蓝发', 'smile': '微笑'});
      await container
          .read(promptReadingPreferencesProvider.notifier)
          .setShowReadings(false);
      await tester.pump();
      await container
          .read(promptReadingPreferencesProvider.notifier)
          .setShowReadings(true);
      await tester.pump();
      expect(controller.value, before);
      await _shortcut(tester, LogicalKeyboardKey.keyZ);
      expect(controller.text, 'blue eyes, blue hair');
      expect(
        container.read(pillWorkspaceProvider(PillScopes.main)).projection,
        controller.text,
      );
      await _shortcut(tester, LogicalKeyboardKey.keyH);
      await tester.enterText(
        find.byKey(const ValueKey('prompt_input_search_field')),
        'blue',
      );
      await tester.enterText(
        find.byKey(const ValueKey('prompt_input_replace_field')),
        'green',
      );
      await tester.tap(find.byKey(const ValueKey('prompt_input_replace_all')));
      await tester.pump();
      expect(controller.text, 'green eyes, green hair');
      expect(
        container.read(pillWorkspaceProvider(PillScopes.main)).projection,
        'green eyes, green hair',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('advanced tag expansion disables completion until it closes', (
    tester,
  ) async {
    final readings = PromptReadingTestController();
    final container = _container(readings);
    final controller = TextEditingController();
    addTearDown(container.dispose);
    addTearDown(controller.dispose);
    await _pump(
      tester,
      container,
      UnifiedPromptInput(
        controller: controller,
        config: const UnifiedPromptConfig(enableAutoFormat: false),
      ),
    );
    await tester.enterText(find.byType(TextField), 'lo');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byKey(const Key('prompt-completion-strip')), findsOneWidget);
    final host = find.descendant(
      of: find.byType(PromptReadingLayer),
      matching: find.byType(TextField),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(host);
    await tester.pump();
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(find.byKey(const Key('tag-expansion-popup')), findsOneWidget);
    expect(find.byKey(const Key('prompt-completion-strip')), findsNothing);
    expect(
      tester
          .widget<PromptCompletionWrapper>(find.byType(PromptCompletionWrapper))
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<TagExpansionWrapper>(find.byType(TagExpansionWrapper))
          .ragScope,
      isNull,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const Key('tag-expansion-popup')), findsNothing);
    expect(
      tester
          .widget<PromptCompletionWrapper>(find.byType(PromptCompletionWrapper))
          .enabled,
      isTrue,
    );
    expect(controller.text, 'lo');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final language in const [
    (Locale('zh'), '长发', '蓝眼睛'),
    (Locale('zh', 'TW'), '長髮', '藍眼睛'),
    (Locale('en'), 'long hair', 'blue eyes'),
    (Locale('ja'), '長い髪', '青い目'),
    (Locale('ko'), '긴 머리', '파란 눈'),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'real manual pill and readings ${language.$1.toLanguageTag()} ${brightness.name}',
        (tester) async {
          tester.view.physicalSize = const Size(760, 380);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final readings = PromptReadingTestController()
            ..reveal({'long_hair': language.$2, 'blue_eyes': language.$3});
          final container = _container(readings);
          addTearDown(container.dispose);
          await container.read(promptBlockLibraryNotifierProvider.future);
          final workspace = container.read(
            pillWorkspaceProvider(PillScopes.main).notifier,
          );
          workspace.setText('long hair, blue eyes, long hair, blue eyes');
          workspace.insertBlockAt(offset: 10, blockId: 'manual');
          final before = container.read(pillWorkspaceProvider(PillScopes.main));
          final scale = language.$1.languageCode == 'ko' ? 1.3 : 1.0;
          await _pump(
            tester,
            container,
            const PromptPillEditor(
              textStyle: TextStyle(
                fontFamily: 'Geist',
                fontFamilyFallback: ['HarmonyOS Sans SC', 'Pretendard'],
                fontSize: 20,
              ),
              config: UnifiedPromptConfig(enableAutoFormat: false),
            ),
            locale: language.$1,
            brightness: brightness,
            width: 330,
            scale: scale,
          );
          expect(find.byType(UiBlockPill), findsOneWidget);
          final pill = tester.getRect(find.byType(UiBlockPill));
          final title = tester.getRect(find.text('Manual · 手动块'));
          expect(pill.height, closeTo(20 * scale, .01));
          expect(title.top, greaterThanOrEqualTo(pill.top));
          expect(title.bottom, lessThanOrEqualTo(pill.bottom));
          expect(
            tester.widget<Text>(find.text('Manual · 手动块')).style?.height,
            1,
          );
          expect(
            container.read(pillWorkspaceProvider(PillScopes.main)),
            before,
          );
          expect(tester.takeException(), isNull);
          final render = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(_boundary),
          );
          await tester.runAsync(() async {
            final image = await render.toImage(pixelRatio: 1.5);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/test_captures/reading-${language.$1.toLanguageTag()}-${brightness.name}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
