import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nai_launcher/core/wiki/auto_tag_translation_controller.dart';
import 'package:nai_launcher/core/wiki/tag_wiki_repository.dart';
import 'package:nai_launcher/core/wiki/visible_tag_translation_cache.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/prompt_assistant/services/prompt_assistant_service.dart';
import 'package:nai_launcher/presentation/widgets/common/image_detail/components/detail_prompt_section.dart';
import 'package:nai_launcher/presentation/widgets/prompt/reading/prompt_reading_text.dart';
import 'package:nai_launcher/presentation/wiring/online_prompt_translation.dart';

class _Assistant extends Mock implements PromptAssistantService {}

class _Wiki extends Mock implements TagWikiRepository {}

class _Readings extends AutoTagTranslationController {
  _Readings()
    : super(
        assistant: _Assistant(),
        wiki: _Wiki(),
        cache: VisibleTagTranslationCache(),
        closeCacheOnDispose: false,
      );
  final surfaces = <String, Set<String>>{};
  @override
  String? nameFor(String tag) => tag == 'blue_eyes' ? '蓝眼睛' : null;
  @override
  void observeNames({required String surface, required Iterable<String> tags}) {
    surfaces[surface] = tags.toSet();
  }

  @override
  void clearSurface(String surface) => surfaces.remove(surface);
}

void main() {
  for (final online in [false, true]) {
    testWidgets(
      'detail readings open explicitly and preserve source online=$online',
      (tester) async {
        final readings = _Readings();
        const source = 'blue eyes, {red hair}';
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              autoTagTranslationProvider.overrideWith((ref) => readings),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: SizedBox(
                  width: 400,
                  child: Builder(
                    builder: (context) => online
                        ? buildOnlineTranslation(
                            context,
                            'image',
                            source,
                            (action, reading) => Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [action, if (reading != null) reading],
                            ),
                          )
                        : const PromptSection(
                            title: 'Prompt',
                            icon: Icons.notes,
                            content: source,
                            initiallyExpanded: true,
                          ),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.byType(PromptReadingText), findsNothing);
        expect(readings.surfaces, isEmpty);
        await tester.tap(find.byKey(const Key('detail-prompt-translate')));
        await tester.pump();
        expect(find.byType(PromptReadingText), findsOneWidget);
        final input = tester.widget<TextField>(find.byType(TextField));
        expect(input.readOnly, isTrue);
        expect(input.controller!.text, source);
        expect(readings.surfaces.values.single, contains('blue_eyes'));
        await tester.tap(find.byKey(const Key('detail-prompt-translate')));
        await tester.pump();
        expect(find.byType(PromptReadingText), findsNothing);
        expect(readings.surfaces, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
