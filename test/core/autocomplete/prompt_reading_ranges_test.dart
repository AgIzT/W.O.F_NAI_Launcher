import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/autocomplete/prompt_token_parser.dart';

void main() {
  test(
    'annotation ranges preserve exact original locations and syntax shells',
    () {
      const text =
          '{long hair}, 1.2::blue_eyes::, hatsune_miku_(vocaloid),\n[smile]';
      final ranges = PromptTokenParser.annotationRanges(text);
      expect(ranges.map((r) => r.tag), [
        'long_hair',
        'blue_eyes',
        'hatsune_miku_(vocaloid)',
        'smile',
      ]);
      expect(ranges.map((r) => text.substring(r.start, r.end)), [
        'long hair',
        'blue_eyes',
        'hatsune_miku_(vocaloid)',
        'smile',
      ]);
    },
  );

  test(
    'macros, editor objects and prose are never split into annotation tags',
    () {
      const text =
          '<preset:blue eyes, red hair>, \uFFFC, \uE000block\uE001, '
          'This is a long natural language sentence with many words., solo';
      expect(PromptTokenParser.annotationRanges(text).map((r) => r.tag), [
        'solo',
      ]);
    },
  );

  test(
    'completion queries left prefix and replaces full current tag without duplicating suffix',
    () {
      const text = 'solo, {long hair}, blue eyes';
      final query = PromptTokenParser.parseCompletion(
        text: text,
        cursorPosition: text.indexOf('long') + 2,
        limit: 20,
        locale: 'en',
      )!;
      expect(query.token, 'lo');
      final result = PromptTokenParser.apply(
        text: text,
        query: query,
        canonicalTag: 'long_hair',
        autoInsertComma: true,
      );
      expect(result.text, text);
      expect(result.cursorPosition, text.indexOf('blue'));
    },
  );

  test('completion ignores macro and private markers', () {
    for (final text in ['<preset', '\uFFFCblue', '\uE000blue']) {
      expect(
        PromptTokenParser.parseCompletion(
          text: text,
          cursorPosition: text.length,
          limit: 20,
          locale: 'en',
        ),
        isNull,
      );
    }
  });

  test('natural-language sentences become phrase ranges beside tags', () {
    const text =
        'masterpiece, a girl sitting on a bench in the park at sunset, '
        'smile,\nShe stands in a flower field. The sky is full of soft clouds.';
    expect(PromptTokenParser.annotationRanges(text).map((r) => r.tag), [
      'masterpiece',
      'smile',
    ]);
    final phrases = PromptTokenParser.phraseRanges(text);
    expect(phrases.map((r) => r.text), [
      'a girl sitting on a bench in the park at sunset',
      'She stands in a flower field.',
      'The sky is full of soft clouds.',
    ]);
    for (final range in phrases) {
      expect(text.substring(range.start, range.end), range.text);
    }
  });

  test('phrase ranges skip weights, macros, blocks and non-Latin text', () {
    const text =
        '1.2::a girl sitting on a long wooden bench by the lake::, '
        '<preset:a long natural sentence with many many words here>, '
        '\uFFFC, \u8FD9\u662F\u4E00\u53E5\u5F88\u957F\u7684\u4E2D\u6587\u53E5\u5B50\u3002, '
        '1.5::solo::';
    expect(PromptTokenParser.phraseRanges(text).map((r) => r.text), [
      'a girl sitting on a long wooden bench by the lake',
    ]);
  });
}
