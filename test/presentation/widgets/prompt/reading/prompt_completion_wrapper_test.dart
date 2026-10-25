import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nai_launcher/core/autocomplete/autocomplete_settings.dart';
import 'package:nai_launcher/core/autocomplete/completion_models.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/core/wiki/auto_tag_translation_controller.dart';
import 'package:nai_launcher/core/wiki/tag_wiki_repository.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/widgets/prompt/reading/prompt_completion_controller.dart';
import 'package:nai_launcher/presentation/widgets/prompt/reading/prompt_completion_preview.dart';
import 'package:nai_launcher/presentation/widgets/prompt/reading/prompt_completion_wrapper.dart';
import '../../../../helpers/studio_capture_fonts.dart';

class _Storage extends Mock implements LocalStorageService {}

class _Settings extends AutocompleteSettingsNotifier {
  _Settings() : super(_Storage());
}

class _Readings extends ChangeNotifier implements AutoTagTranslationController {
  final surfaces = <String, Set<String>>{};
  @override
  void observeNames({required String surface, required Iterable<String> tags}) {
    surfaces[surface] = tags.toSet();
  }

  @override
  void clearSurface(String surface) {
    surfaces.remove(surface);
  }

  @override
  String? nameFor(String tag) => tag == 'long_hair' ? '长发' : null;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #observe) return null;
    return super.noSuchMethod(invocation);
  }
}

CompletionCandidate tag(
  String name, {
  TagCategory category = TagCategory.general,
}) => CompletionCandidate(
  canonicalTag: name,
  category: category,
  postCount: 10,
  matchKind: CompletionMatchKind.englishPrefix,
  sources: const {CompletionSourceKind.base},
  aliases: const ['official_alias'],
);

Future<void> pumpEditor(
  WidgetTester tester,
  TextEditingController editor,
  FocusNode focus,
  PromptCompletionSearch search, {
  ValueChanged<String>? onApplied,
  Locale locale = const Locale('en'),
  Brightness brightness = Brightness.light,
  double textScale = 1,
  UndoHistoryController? undoController,
  ScrollController? pageScroll,
  double top = 20,
  int? minLines,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        promptCompletionSearchProvider.overrideWithValue(search),
        autoTagTranslationProvider.overrideWith((ref) => _Readings()),
        autocompleteSettingsProvider.overrideWith((ref) => _Settings()),
        promptCompletionPreviewProvider.overrideWith(
          (ref, query) => Stream.value(
            PromptCompletionPreviewData(
              wiki: TagWikiEntry(
                tag: query.tag,
                body: 'A precise source description. More details.',
                sourceUrl: 'https://danbooru.donmai.us',
              ),
            ),
          ),
        ),
      ],
      child: RepaintBoundary(
        key: const Key('completion-capture'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: brightness,
            fontFamily: 'HarmonyOS Sans SC',
            fontFamilyFallback: const ['Geist', 'Pretendard'],
          ),
          locale: locale,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              controller: pageScroll,
              child: SizedBox(
                height: 1000,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(20, top, 20, 20),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: 600,
                      child: PromptCompletionWrapper(
                        controller: editor,
                        focusNode: focus,
                        scope: 'main',
                        onApplied: onApplied,
                        child: TextField(
                          key: const Key('editor'),
                          controller: editor,
                          focusNode: focus,
                          minLines: minLines,
                          maxLines: minLines == null ? 4 : minLines + 2,
                          undoController: undoController,
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
    ),
  );
}

const _strip = Key('prompt-completion-strip');
const _panel = Key('prompt-completion-panel');

Future<void> typeAndSettle(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('editor')), text);
  await tester.pump(const Duration(milliseconds: 260));
  await tester.pump();
}

void main() {
  for (final height in [600.0, 180.0]) {
    testWidgets(
      'expanded completion fits ${height}px with empty and failed queries',
      (tester) async {
        tester.view.physicalSize = Size(800, height);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final editor = TextEditingController(), focus = FocusNode();
        addTearDown(editor.dispose);
        addTearDown(focus.dispose);
        var workAttempts = 0;
        await pumpEditor(
          tester,
          editor,
          focus,
          (query) async {
            if (query.categoryFilter == CompletionCategoryFilter.characters) {
              return [];
            }
            if (query.categoryFilter == CompletionCategoryFilter.works) {
              if (workAttempts++ == 0) throw StateError('offline');
              return [tag('long_work', category: TagCategory.copyright)];
            }
            return [tag('long_hair')];
          },
          top: 60,
          minLines: 20,
        );
        await typeAndSettle(tester, 'lo');
        await tester.tap(find.byKey(const Key('prompt-completion-expand')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final panel = tester.getRect(find.byKey(_panel));
        expect(panel.top, greaterThanOrEqualTo(0));
        expect(panel.bottom, lessThanOrEqualTo(height));
        if (height == 600) expect(panel.height, greaterThan(100));

        await tester.tap(find.widgetWithText(ChoiceChip, 'Character'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.widgetWithText(ChoiceChip, 'Works'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final retry = find.widgetWithText(TextButton, 'Retry');
        await tester.ensureVisible(retry);
        await tester.pumpAndSettle();
        await tester.tap(retry);
        await tester.pumpAndSettle();
        expect(workAttempts, 2);
        expect(find.textContaining('long work'), findsOneWidget);
        expect(editor.text, 'lo');
        expect(focus.hasFocus, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final expanded in [false, true]) {
    testWidgets(
      'keyboard wrap reveals offscreen candidates in ${expanded ? 'list' : 'strip'}',
      (tester) async {
        final editor = TextEditingController(), focus = FocusNode();
        addTearDown(editor.dispose);
        addTearDown(focus.dispose);
        await pumpEditor(
          tester,
          editor,
          focus,
          (_) async => [
            for (var i = 0; i < 20; i++)
              tag(
                'long_candidate_name_number_$i',
                category: i < 10 ? TagCategory.general : TagCategory.character,
              ),
          ],
        );
        await typeAndSettle(tester, 'lo');
        if (expanded) {
          await tester.tap(find.byKey(const Key('prompt-completion-expand')));
          await tester.pumpAndSettle();
        }
        Finder candidate(int index) => find
            .byKey(
              ValueKey(
                'prompt-completion-${expanded ? 'info' : 'chip'}-long_candidate_name_number_$index',
              ),
            )
            .hitTestable();
        final readings =
            ProviderScope.containerOf(
                  tester.element(find.byKey(const Key('editor'))),
                ).read(autoTagTranslationProvider)
                as _Readings;
        Set<String> visible() =>
            readings.surfaces.values.expand((tags) => tags).toSet();
        expect(candidate(0), findsOneWidget);
        expect(candidate(19), findsNothing);
        expect(visible().length, lessThan(20));

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expect(candidate(19), findsOneWidget);
        expect(candidate(0), findsNothing);
        expect(visible(), contains('long_candidate_name_number_19'));
        expect(visible().length, lessThan(20));

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(candidate(0), findsOneWidget);
        expect(candidate(19), findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(editor.text, 'long candidate name number 19, ');
        expect(focus.hasFocus, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'compact strip docks under the editor without covering any text',
    (tester) async {
      final editor = TextEditingController(), focus = FocusNode();
      addTearDown(editor.dispose);
      addTearDown(focus.dispose);
      await pumpEditor(
        tester,
        editor,
        focus,
        (_) async => [tag('long_hair')],
        minLines: 1,
      );
      await typeAndSettle(tester, 'lo');
      final field = tester.getRect(find.byKey(const Key('editor')));
      final strip = tester.getRect(find.byKey(_strip));
      expect(strip.top, moreOrLessEquals(field.bottom + 3));
      expect(strip.left, field.left);
      expect(strip.width, field.width);
      expect(strip.height, lessThanOrEqualTo(46));
      expect(strip.overlaps(field), isFalse);
      // Filters, Wiki and the full list stay out of the way until asked for.
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.byType(PromptCompletionPreview), findsNothing);
      expect(find.text('长发'), findsOneWidget);
    },
  );

  testWidgets('strip sits in blank lines at the bottom of a tall editor', (
    tester,
  ) async {
    final editor = TextEditingController(), focus = FocusNode();
    addTearDown(editor.dispose);
    addTearDown(focus.dispose);
    await pumpEditor(
      tester,
      editor,
      focus,
      (_) async => [tag('long_hair')],
      minLines: 6,
    );
    await typeAndSettle(tester, 'lo');
    final field = tester.getRect(find.byKey(const Key('editor')));
    final strip = tester.getRect(find.byKey(_strip));
    expect(strip.bottom, moreOrLessEquals(field.bottom - 3));
    final editable = tester.renderObject<RenderEditable>(
      find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Editable'),
    );
    final line = MatrixUtils.transformRect(
      editable.getTransformTo(null),
      editable.getLocalRectForCaret(const TextPosition(offset: 2)),
    );
    expect(strip.top, greaterThan(line.bottom));
  });

  testWidgets('strip flips above an editor near the bottom of the window', (
    tester,
  ) async {
    final editor = TextEditingController(), focus = FocusNode();
    addTearDown(editor.dispose);
    addTearDown(focus.dispose);
    await pumpEditor(
      tester,
      editor,
      focus,
      (_) async => [tag('long_hair')],
      top: 530,
      minLines: 1,
    );
    await typeAndSettle(tester, 'lo');
    final field = tester.getRect(find.byKey(const Key('editor')));
    final strip = tester.getRect(find.byKey(_strip));
    expect(strip.bottom, moreOrLessEquals(field.top - 3));
    expect(strip.overlaps(field), isFalse);
  });

  testWidgets(
    'filters live in the expanded list and the strip follows page scroll',
    (tester) async {
      final editor = TextEditingController(), focus = FocusNode();
      final scroll = ScrollController();
      addTearDown(editor.dispose);
      addTearDown(focus.dispose);
      addTearDown(scroll.dispose);
      final queries = <CompletionQuery>[];
      await pumpEditor(tester, editor, focus, (query) async {
        queries.add(query);
        return query.categoryFilter == CompletionCategoryFilter.characters
            ? [tag('rare_character', category: TagCategory.character)]
            : [for (var i = 0; i < 20; i++) tag('common_tag_$i')];
      }, pageScroll: scroll);
      await typeAndSettle(tester, 'co');
      expect(find.text('rare character'), findsNothing);
      await tester.tap(find.byKey(const Key('prompt-completion-expand')));
      await tester.pump();
      expect(find.byKey(_panel), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Character'));
      await tester.pump();
      await tester.pump();
      expect(queries.last.categoryFilter, CompletionCategoryFilter.characters);
      expect(queries.last.limit, 20);
      expect(find.text('rare character'), findsOneWidget);
      // Collapsing drops the filter: the strip never hides a category.
      await tester.tap(find.byKey(const Key('prompt-completion-collapse')));
      await tester.pump();
      await tester.pump();
      expect(queries.last.categoryFilter, CompletionCategoryFilter.all);
      expect(find.byKey(_strip), findsOneWidget);
      final before = tester.getRect(find.byKey(_strip));
      scroll.jumpTo(10);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(_strip), findsOneWidget);
      expect(tester.getRect(find.byKey(_strip)).top, before.top - 10);
      expect(editor.text, 'co');
    },
  );

  testWidgets('typing keeps the previous rows dimmed instead of flashing', (
    tester,
  ) async {
    final editor = TextEditingController(), focus = FocusNode();
    addTearDown(editor.dispose);
    addTearDown(focus.dispose);
    final pending = Completer<List<CompletionCandidate>>();
    await pumpEditor(
      tester,
      editor,
      focus,
      (q) async => q.token == 'lo' ? [tag('long_hair')] : pending.future,
    );
    await typeAndSettle(tester, 'lo');
    double opacity() => tester
        .widget<AnimatedOpacity>(
          find.descendant(
            of: find.byKey(_strip),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;
    expect(opacity(), 1);
    await tester.enterText(find.byKey(const Key('editor')), 'lon');
    await tester.pump();
    expect(find.byKey(_strip), findsOneWidget);
    expect(opacity(), .5);
    await tester.pump(const Duration(milliseconds: 260));
    expect(find.text('long hair'), findsOneWidget);
    pending.complete([tag('longer_tag')]);
    // The completer settles after the frame; the strip redraws on the next.
    await tester.pump();
    await tester.pump();
    expect(find.text('longer tag'), findsOneWidget);
    expect(find.text('long hair'), findsNothing);
    expect(opacity(), 1);
  });

  testWidgets('Tab during the debounce accepts the first fresh result', (
    tester,
  ) async {
    final editor = TextEditingController(), focus = FocusNode();
    addTearDown(editor.dispose);
    addTearDown(focus.dispose);
    await pumpEditor(
      tester,
      editor,
      focus,
      (q) async => [tag(q.token == 'lo' ? 'lowres' : 'long_hair')],
    );
    await typeAndSettle(tester, 'lo');
    expect(find.text('lowres'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('editor')), 'lon');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.pump();
    expect(editor.text, 'long hair, ');
    expect(find.byKey(_strip), findsNothing);
    expect(focus.hasFocus, isTrue);
  });

  testWidgets(
    'stable input selection is one event and native undo restores the prefix',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final editor = TextEditingController(), focus = FocusNode();
      final history = UndoHistoryController();
      addTearDown(editor.dispose);
      addTearDown(focus.dispose);
      addTearDown(history.dispose);
      final applied = <String>[];
      await pumpEditor(
        tester,
        editor,
        focus,
        (_) async => [tag('long_hair')],
        undoController: history,
        onApplied: applied.add,
      );
      await tester.enterText(find.byKey(const Key('editor')), 'lo');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(editor.text, 'long hair, ');
      expect(applied, hasLength(1));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(editor.text, 'lo');
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'completion sessions isolate cancellation across two fields and scopes',
    (tester) async {
      final a = TextEditingController(), b = TextEditingController();
      final fa = FocusNode(), fb = FocusNode();
      final first = Completer<List<CompletionCandidate>>();
      final sa = PromptCompletionController(
        editor: a,
        focusNode: fa,
        scope: 'main',
        locale: 'en',
        search: (_) => first.future,
      );
      final sb = PromptCompletionController(
        editor: b,
        focusNode: fb,
        scope: 'character:2',
        locale: 'en',
        search: (_) async => [tag('blue_eyes')],
      );
      addTearDown(() {
        sa.dispose();
        sb.dispose();
        a.dispose();
        b.dispose();
        fa.dispose();
        fb.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TextField(controller: a, focusNode: fa),
                TextField(controller: b, focusNode: fb),
              ],
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField).first, 'lo');
      await tester.pump(const Duration(milliseconds: 260));
      await tester.enterText(find.byType(TextField).last, 'bl');
      await tester.pump(const Duration(milliseconds: 260));
      first.complete([tag('long_hair')]);
      await tester.pump();
      expect(sa.candidates, isEmpty);
      expect(sb.candidates.single.canonicalTag, 'blue_eyes');
      sa.dismiss();
      expect(sb.apply(), isTrue);
      expect(a.text, 'lo');
      expect(b.text, 'blue eyes, ');
    },
  );

  testWidgets(
    'debounces committed input, groups characters and works, and selects with Enter',
    (tester) async {
      final editor = TextEditingController(), focus = FocusNode();
      addTearDown(editor.dispose);
      addTearDown(focus.dispose);
      final queries = <CompletionQuery>[], applied = <String>[];
      await pumpEditor(tester, editor, focus, (query) async {
        queries.add(query);
        return [
          tag('long_hair'),
          tag('hatsune_miku', category: TagCategory.character),
          tag('vocaloid', category: TagCategory.copyright),
        ];
      }, onApplied: applied.add);
      await tester.enterText(find.byKey(const Key('editor')), 'lo');
      await tester.pump(const Duration(milliseconds: 249));
      expect(queries, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(queries.single.token, 'lo');
      expect(find.byKey(_strip), findsOneWidget);
      // The strip separates groups by glyph and divider, not by headings.
      expect(find.text('Character'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(_strip),
          matching: find.byType(VerticalDivider),
        ),
        findsNWidgets(2),
      );
      await tester.tap(find.byKey(const Key('prompt-completion-expand')));
      await tester.pump();
      expect(find.text('Character'), findsWidgets);
      expect(find.text('Works'), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(editor.text, 'long hair, ');
      expect(applied, ['long hair, ']);
      expect(find.byKey(_strip), findsNothing);
      expect(find.byKey(_panel), findsNothing);
    },
  );

  testWidgets('clicking a chip inserts it and keeps editor focus', (
    tester,
  ) async {
    final editor = TextEditingController(), focus = FocusNode();
    addTearDown(editor.dispose);
    addTearDown(focus.dispose);
    await pumpEditor(
      tester,
      editor,
      focus,
      (_) async => [tag('long_hair'), tag('lowres')],
    );
    await typeAndSettle(tester, 'lo');
    await tester.tap(
      find.byKey(const ValueKey('prompt-completion-chip-lowres')),
    );
    await tester.pump();
    expect(editor.text, 'lowres, ');
    expect(focus.hasFocus, isTrue);
    expect(find.byKey(_strip), findsNothing);
  });

  testWidgets(
    'does not query or intercept IME composition; one committed Chinese character searches',
    (tester) async {
      final editor = TextEditingController(), focus = FocusNode();
      addTearDown(editor.dispose);
      addTearDown(focus.dispose);
      final queries = <CompletionQuery>[];
      await pumpEditor(tester, editor, focus, (query) async {
        queries.add(query);
        return [tag('long_hair')];
      });
      await tester.tap(find.byKey(const Key('editor')));
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'chang',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange(start: 0, end: 5),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(queries, isEmpty);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '长',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pump();
      expect(queries.single.token, '长');
      expect(editor.text, '长');
    },
  );

  testWidgets(
    'stale results, selection changes and Escape never reopen dismissed completion',
    (tester) async {
      final editor = TextEditingController(), focus = FocusNode();
      addTearDown(editor.dispose);
      addTearDown(focus.dispose);
      final pending = <String, Completer<List<CompletionCandidate>>>{};
      await pumpEditor(
        tester,
        editor,
        focus,
        (q) => (pending[q.token] = Completer()).future,
      );
      await tester.enterText(find.byKey(const Key('editor')), 'lo');
      await tester.pump(const Duration(milliseconds: 260));
      await tester.enterText(find.byKey(const Key('editor')), 'bl');
      await tester.pump(const Duration(milliseconds: 260));
      pending['lo']!.complete([tag('long_hair')]);
      await tester.pump();
      expect(find.text('long hair'), findsNothing);
      pending['bl']!.complete([tag('blue_eyes')]);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(_strip), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(_strip), findsNothing);
      expect(editor.text, 'bl');
      editor.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(_strip), findsNothing);
    },
  );

  testWidgets(
    'Wiki and alias preview preserve text, selection and editor focus',
    (tester) async {
      final editor = TextEditingController(), focus = FocusNode();
      addTearDown(editor.dispose);
      addTearDown(focus.dispose);
      await pumpEditor(tester, editor, focus, (_) async => [tag('long_hair')]);
      await typeAndSettle(tester, 'lo');
      final before = editor.value;
      await tester.tap(find.byKey(const Key('prompt-completion-expand')));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('prompt-completion-info-long_hair')),
      );
      await tester.pumpAndSettle();
      expect(find.text('A precise source description.'), findsOneWidget);
      expect(find.text('official alias'), findsOneWidget);
      expect(editor.value, before);
      expect(focus.hasFocus, isTrue);
      // Escape steps back one level at a time: preview, list, then strip.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const Key('prompt-completion-preview')), findsNothing);
      expect(find.byKey(_panel), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(_panel), findsNothing);
      expect(find.byKey(_strip), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(_strip), findsNothing);
      expect(editor.value, before);
    },
  );

  for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.tab]) {
    for (final delay in [20, 260]) {
      testWidgets(
        'typing after Wiki preview waits for fresh ${key.keyLabel} result at ${delay}ms',
        (tester) async {
          final editor = TextEditingController(), focus = FocusNode();
          addTearDown(editor.dispose);
          addTearDown(focus.dispose);
          final pending = Completer<List<CompletionCandidate>>();
          await pumpEditor(
            tester,
            editor,
            focus,
            (q) async => q.token == 'lo' ? [tag('lowres')] : pending.future,
          );
          await typeAndSettle(tester, 'lo');
          await tester.tap(
            find.byKey(const ValueKey('prompt-completion-chip-lowres')),
            buttons: kSecondaryButton,
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('prompt-completion-preview')),
            findsOneWidget,
          );

          await tester.enterText(find.byKey(const Key('editor')), 'long');
          await tester.pump(Duration(milliseconds: delay));
          expect(
            find.byKey(const Key('prompt-completion-preview')),
            findsNothing,
          );
          await tester.sendKeyEvent(key);
          await tester.pump();
          expect(editor.text, 'long');
          pending.complete([tag('long_hair')]);
          await tester.pumpAndSettle();
          expect(editor.text, 'long hair, ');
          expect(focus.hasFocus, isTrue);
        },
      );
    }
  }

  testWidgets('right-clicking a chip previews it directly', (tester) async {
    final editor = TextEditingController(), focus = FocusNode();
    addTearDown(editor.dispose);
    addTearDown(focus.dispose);
    await pumpEditor(tester, editor, focus, (_) async => [tag('long_hair')]);
    await typeAndSettle(tester, 'lo');
    final before = editor.value;
    await tester.tap(
      find.byKey(const ValueKey('prompt-completion-chip-long_hair')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('prompt-completion-preview')), findsOneWidget);
    expect(find.text('A precise source description.'), findsOneWidget);
    expect(editor.value, before);
    expect(focus.hasFocus, isTrue);
  });

  if (Platform.environment['CAPTURE_STUDIO_UI'] == '1') {
    for (final capture in [
      ('narrow-zh', 360.0, const Locale('zh'), Brightness.light, 1.2),
      ('wide-en-dark', 1280.0, const Locale('en'), Brightness.dark, 1.0),
      ('narrow-ja', 360.0, const Locale('ja'), Brightness.light, 1.0),
      ('narrow-ko', 360.0, const Locale('ko'), Brightness.dark, 1.0),
      ('wide-zh-tw', 1280.0, const Locale('zh', 'TW'), Brightness.light, 1.0),
    ]) {
      testWidgets('completion visual capture ${capture.$1}', (tester) async {
        debugDisableShadows = false;
        addTearDown(() => debugDisableShadows = true);
        await tester.runAsync(loadStudioCaptureFonts);
        tester.view.physicalSize = Size(capture.$2, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final editor = TextEditingController(), focus = FocusNode();
        addTearDown(editor.dispose);
        addTearDown(focus.dispose);
        await pumpEditor(
          tester,
          editor,
          focus,
          (_) async => [
            tag(
              'hatsune_miku_(a_long_variant_name)_(vocaloid)',
              category: TagCategory.character,
            ),
            tag(
              'project_sekai_colorful_stage!_feat._hatsune_miku',
              category: TagCategory.copyright,
            ),
            tag('long_hair'),
            tag('very_long_hair_blowing_in_the_wind'),
          ],
          locale: capture.$3,
          brightness: capture.$4,
          textScale: capture.$5,
        );
        await tester.enterText(find.byKey(const Key('editor')), '初音');
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        Future<void> save(String suffix) async {
          final render = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('completion-capture')),
          );
          await tester.runAsync(() async {
            final image = await render.toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final directory = Directory('build/prompt-completion-qa');
            await directory.create(recursive: true);
            await File(
              '${directory.path}/${capture.$1}$suffix.png',
            ).writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }

        await save('');
        await tester.tap(find.byKey(const Key('prompt-completion-expand')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await save('-list');
        await tester.tap(
          find.byKey(
            const ValueKey(
              'prompt-completion-info-hatsune_miku_(a_long_variant_name)_(vocaloid)',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await save('-wiki');
        debugDisableShadows = true;
      });
    }
  }
}
