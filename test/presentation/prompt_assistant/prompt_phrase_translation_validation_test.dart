import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/presentation/prompt_assistant/services/prompt_assistant_service.dart';

Map<String, String> _validate(String raw, List<String> phrases) =>
    PromptAssistantService.validatePhraseTranslationResponse(raw, phrases);

void main() {
  test('keeps valid phrase translations and drops the rest', () {
    final result = _validate(
      '```json\n'
      '{"A cat sits.": "一只猫坐着。", "unknown": "x", '
      r'"A dog runs.": "一只狗\n在跑", "A bird sings.": 3}'
      '\n```',
      ['A cat sits.', 'A dog runs.', 'A bird sings.', 'Never answered.'],
    );
    expect(result, {'A cat sits.': '一只猫坐着。', 'A dog runs.': '一只狗 在跑'});
  });

  test('rejects non-objects and answers without any valid reading', () {
    expect(() => _validate('[]', ['A cat.']), throwsFormatException);
    expect(
      () => _validate('{"A cat.": "   "}', ['A cat.']),
      throwsFormatException,
    );
    expect(
      () => _validate('{"Other.": "其他"}', ['A cat.']),
      throwsFormatException,
    );
  });
}
