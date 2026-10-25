import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nai_launcher/core/wiki/auto_tag_translation_controller.dart';
import 'package:nai_launcher/core/wiki/tag_wiki_repository.dart';
import 'package:nai_launcher/core/wiki/visible_tag_translation_cache.dart';
import 'package:nai_launcher/presentation/prompt_assistant/services/prompt_assistant_service.dart';
import 'package:nai_launcher/presentation/widgets/prompt/nai_syntax_controller.dart';
import 'package:nai_launcher/presentation/widgets/prompt/reading/prompt_reading_layer.dart';
import 'package:nai_launcher/presentation/widgets/prompt/reading/prompt_reading_text.dart';

import '../../../helpers/studio_capture_fonts.dart';

class _Assistant extends Mock implements PromptAssistantService {}

class _Wiki extends Mock implements TagWikiRepository {}

/// A notifier-only substitute: no preferences, user databases or models.
class _Readings extends AutoTagTranslationController {
  _Readings()
    : super(
        assistant: _Assistant(),
        wiki: _Wiki(),
        cache: VisibleTagTranslationCache(),
        closeCacheOnDispose: false,
      );
  final names = <String, String>{};
  final surfaces = <String, Set<String>>{};
  final requests = <String>[];
  Set<String> get visible => {for (final tags in surfaces.values) ...tags};
  @override
  String? nameFor(String tag) => names[tag];
  @override
  void observeNames({required String surface, required Iterable<String> tags}) {
    surfaces[surface] = tags.toSet();
  }

  @override
  void requestMissingNames({required String surface}) => requests.add(surface);
  @override
  void clearSurface(String surface) => surfaces.remove(surface);
  void reveal(Map<String, String> translations) {
    names.addAll(translations);
    notifyListeners();
  }
}

const _font = TextStyle(
  fontFamily: 'Geist',
  fontFamilyFallback: ['HarmonyOS Sans SC'],
  fontSize: 18,
  color: Color(0xff142333),
);

Widget _field(
  TextEditingController controller, {
  bool enabled = true,
  double size = 18,
  int? maxLines = 4,
  ScrollController? scroll,
  UndoHistoryController? undo,
  GlobalKey<PromptReadingLayerState>? readingKey,
}) => PromptReadingLayer(
  key: readingKey,
  controller: controller,
  enabled: enabled,
  style: _font.copyWith(
    fontSize: size * .65,
    height: 1,
    color: const Color(0xff526c8b),
  ),
  child: TextField(
    controller: controller,
    undoController: undo,
    scrollController: scroll,
    maxLines: maxLines,
    minLines: 1,
    style: _font.copyWith(
      fontSize: size,
      height: PromptReadingLayer.lineHeight,
      leadingDistribution: TextLeadingDistribution.even,
    ),
    decoration: const InputDecoration(
      border: OutlineInputBorder(),
      contentPadding: EdgeInsets.all(12),
    ),
  ),
);

Widget _app(_Readings readings, Widget child) => ProviderScope(
  overrides: [autoTagTranslationProvider.overrideWith((ref) => readings)],
  child: MaterialApp(
    theme: ThemeData(fontFamily: 'Geist'),
    home: Scaffold(backgroundColor: const Color(0xfff2f5f8), body: child),
  ),
);

Future<void> _capture(WidgetTester tester, Key key, String filename) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/test_captures/$filename.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(loadStudioCaptureFonts);

  testWidgets(
    'names arrive without changing text, selection, composing or undo',
    (tester) async {
      final readings = _Readings();
      final controller = TextEditingController(text: 'long hair, blue eyes');
      final undo = UndoHistoryController();
      final key = GlobalKey<PromptReadingLayerState>();
      addTearDown(controller.dispose);
      addTearDown(undo.dispose);
      await tester.pumpWidget(
        _app(
          readings,
          Center(
            child: SizedBox(
              width: 600,
              child: _field(controller, undo: undo, readingKey: key),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(TextField));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.enterText(
        find.byType(TextField),
        'long hair, blue eyes, smile',
      );
      await tester.pump(const Duration(milliseconds: 600));
      controller.selection = const TextSelection(
        baseOffset: 3,
        extentOffset: 16,
      );
      await tester.pump();
      final before = controller.value;
      final beforeUndo = undo.value;
      readings.reveal({'long_hair': '长发', 'blue_eyes': '蓝眼', 'smile': '微笑'});
      await tester.pump();
      expect(controller.value, before);
      expect(undo.value, beforeUndo);
      expect(readings.visible, {'long_hair', 'blue_eyes', 'smile'});
      key.currentState!.requestMissingNames();
      expect(readings.requests.single, readings.surfaces.keys.single);
      undo.undo();
      await tester.pump();
      expect(controller.text, 'long hair, blue eyes');
    },
  );

  testWidgets('IME composing tag is excluded until composition commits', (
    tester,
  ) async {
    final readings = _Readings();
    final controller = TextEditingController.fromValue(
      const TextEditingValue(
        text: 'long hair, blue eyes',
        selection: TextSelection.collapsed(offset: 19),
        composing: TextRange(start: 11, end: 19),
      ),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        readings,
        Center(child: SizedBox(width: 600, child: _field(controller))),
      ),
    );
    await tester.pump();
    expect(readings.visible, {'long_hair'});
    final before = controller.value;
    readings.reveal({'blue_eyes': '蓝眼'});
    await tester.pump();
    expect(controller.value, before);
    expect(readings.visible, {'long_hair'});
    controller.value = before.copyWith(composing: TextRange.empty);
    await tester.pump();
    expect(readings.visible, {'long_hair', 'blue_eyes'});
  });

  testWidgets(
    'scrolling updates the visible names without changing the document',
    (tester) async {
      final readings = _Readings();
      final controller = TextEditingController(
        text: List.generate(70, (i) => 'tag_$i').join(',\n'),
      );
      final scroll = ScrollController();
      addTearDown(controller.dispose);
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        _app(
          readings,
          Center(
            child: SizedBox(
              width: 500,
              child: _field(controller, scroll: scroll, maxLines: 3),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(readings.visible, contains('tag_0'));
      expect(readings.visible.length, lessThan(6));
      final before = controller.value;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      expect(readings.visible, contains('tag_69'));
      expect(readings.visible, isNot(contains('tag_0')));
      expect(readings.visible.length, lessThan(6));
      expect(controller.value, before);
    },
  );

  testWidgets(
    'outer scrolling clips auto-growing fields before observing names',
    (tester) async {
      final readings = _Readings();
      final controller = TextEditingController(
        text: List.generate(70, (i) => 'tag_$i').join(',\n'),
      );
      final scroll = ScrollController();
      addTearDown(controller.dispose);
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        _app(
          readings,
          Center(
            child: SizedBox(
              width: 500,
              height: 160,
              child: SingleChildScrollView(
                controller: scroll,
                child: RepaintBoundary(
                  child: _field(controller, maxLines: null),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(readings.visible, contains('tag_0'));
      expect(readings.visible.length, lessThan(6));
      final before = controller.value;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      expect(readings.visible, contains('tag_69'));
      expect(readings.visible, isNot(contains('tag_0')));
      expect(readings.visible.length, lessThan(6));
      expect(controller.value, before);
      await tester.pumpWidget(const SizedBox());
      expect(readings.visible, isEmpty);
    },
  );

  testWidgets(
    'capture real-font annotations with manual blocks and large narrow text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1040, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final readings = _Readings();
      readings.names.addAll({
        '1girl': '1个女孩',
        'long_hair': '长发',
        'blue_eyes': '蓝色眼睛',
        'hatsune_miku': '初音未来',
        'smile': '微笑',
        'white_dress': '白色连衣裙',
        'very_long_hair': '极长发',
        'green_eyes': '绿色眼睛',
      });
      final plain = NaiSyntaxController(
        text: '1girl, long hair, blue eyes, hatsune miku, smile',
      );
      final narrow = NaiSyntaxController(
        text: 'very long hair, white dress,\nblue eyes, hatsune miku, smile',
      );
      final manual = NaiSyntaxController(
        text: 'long hair, \uE000, green eyes,\nwhite dress, hatsune miku',
        lineHeight: PromptReadingLayer.lineHeight,
      );
      manual.pillBuilder = (_, __, ___) => WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Container(
          width: 140,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xffd7e9fa),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text('手动积木', style: _font.copyWith(height: 1)),
        ),
      );
      addTearDown(plain.dispose);
      addTearDown(narrow.dispose);
      addTearDown(manual.dispose);
      const capture = Key('reading-capture');
      await tester.pumpWidget(
        _app(
          readings,
          RepaintBoundary(
            key: capture,
            child: ColoredBox(
              color: const Color(0xfff2f5f8),
              child: Padding(
                padding: const EdgeInsets.all(30),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Prompt readings · original text stays editable',
                      style: TextStyle(fontSize: 24),
                    ),
                    const SizedBox(height: 18),
                    _field(plain, maxLines: 2),
                    const SizedBox(height: 28),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 300,
                          child: _field(narrow, size: 22, maxLines: 8),
                        ),
                        const SizedBox(width: 28),
                        Expanded(
                          child: MediaQuery(
                            data: const MediaQueryData(
                              textScaler: TextScaler.linear(1.2),
                            ),
                            child: _field(manual, size: 24, maxLines: 6),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('手动积木'), findsOneWidget);
      await _capture(tester, capture, 'prompt-reading-layout');
    },
  );

  double caretX(WidgetTester tester, int offset) {
    final editable = tester.renderObject<RenderEditable>(
      find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Editable'),
    );
    return editable.getLocalRectForCaret(TextPosition(offset: offset)).left;
  }

  double readingWidth(String text) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: _font.copyWith(fontSize: 18 * .65, height: 1),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  const wideName = '一个女孩（单人构图）';

  testWidgets('a wide reading pushes the next word instead of being clipped', (
    tester,
  ) async {
    final readings = _Readings();
    final controller = NaiSyntaxController(text: '1girl, solo, smile');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        readings,
        Center(child: SizedBox(width: 700, child: _field(controller))),
      ),
    );
    await tester.pump();
    final before = controller.value;
    final narrowGap = caretX(tester, 7) - caretX(tester, 0);
    final soloGap = caretX(tester, 13) - caretX(tester, 7);
    readings.reveal({'1girl': wideName, 'solo': '单'});
    await tester.pump();
    await tester.pump();
    final gap = caretX(tester, 7) - caretX(tester, 0);
    expect(gap, greaterThan(narrowGap));
    expect(gap, greaterThanOrEqualTo(readingWidth(wideName) + 4 - .5));
    // A reading narrower than its tag reserves nothing.
    // Split spans may shift glyphs by a sub-pixel; nothing is reserved here.
    expect(caretX(tester, 13) - caretX(tester, 7), closeTo(soloGap, 1));
    expect(controller.value, before);
    expect(controller.text, '1girl, solo, smile');
    readings.reveal({'1girl': '1'});
    await tester.pump();
    await tester.pump();
    expect(caretX(tester, 7) - caretX(tester, 0), closeTo(narrowGap, 1));
  });

  testWidgets('spacing follows edits in the same frame', (tester) async {
    final readings = _Readings()..names['1girl'] = wideName;
    final controller = NaiSyntaxController(text: '1girl, solo');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        readings,
        Center(child: SizedBox(width: 700, child: _field(controller))),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'smile, 1girl, solo');
    await tester.pump();
    // The push moved with the tag; no frame applies it to the old offsets.
    expect(
      caretX(tester, 14) - caretX(tester, 7),
      greaterThanOrEqualTo(readingWidth(wideName) + 4 - .5),
    );
    expect(
      caretX(tester, 7) - caretX(tester, 0),
      lessThan(readingWidth(wideName)),
    );
  });

  testWidgets('disabling readings removes the reserved room', (tester) async {
    final readings = _Readings()..names['1girl'] = wideName;
    final controller = NaiSyntaxController(text: '1girl, solo');
    addTearDown(controller.dispose);
    Future<void> pump(bool enabled) => tester.pumpWidget(
      _app(
        readings,
        Center(
          child: SizedBox(
            width: 700,
            child: _field(controller, enabled: enabled),
          ),
        ),
      ),
    );
    await pump(true);
    await tester.pump();
    final wide = caretX(tester, 7) - caretX(tester, 0);
    expect(wide, greaterThanOrEqualTo(readingWidth(wideName) + 4 - .5));
    await pump(false);
    await tester.pump();
    await tester.pump();
    expect(caretX(tester, 7) - caretX(tester, 0), lessThan(wide));
  });

  testWidgets(
    'read-only details keep selectable English when readings arrive',
    (tester) async {
      final readings = _Readings();
      await tester.pumpWidget(
        _app(
          readings,
          const Center(
            child: SizedBox(
              width: 500,
              child: PromptReadingText(
                text: 'long hair, blue eyes',
                style: _font,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final editable = tester.widget<EditableText>(find.byType(EditableText));
      expect(editable.readOnly, isTrue);
      final original = editable.controller.value;
      readings.reveal({'long_hair': '长发', 'blue_eyes': '蓝眼'});
      await tester.pump();
      expect(editable.controller.value, original);
      expect(editable.controller.text, 'long hair, blue eyes');
      expect(readings.visible, {'long_hair', 'blue_eyes'});
    },
  );
}
