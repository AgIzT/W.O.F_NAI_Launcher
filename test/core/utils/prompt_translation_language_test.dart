import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/utils/prompt_translation_language.dart';

void main() {
  test(
    'reading languages accept locale variants and reject noncanonical keys',
    () {
      expect(
        PromptTranslationLanguage.fromCode('ja-JP'),
        PromptTranslationLanguage.japanese,
      );
      expect(
        PromptTranslationLanguage.fromCode('ko_KR'),
        PromptTranslationLanguage.korean,
      );
      expect(
        PromptTranslationLanguage.fromCode('zh-Hant-TW'),
        PromptTranslationLanguage.traditionalChinese,
      );
      expect(
        PromptTranslationLanguage.fromCode('unsupported'),
        PromptTranslationLanguage.chinese,
      );
      expect(PromptTranslationLanguage.isCode('zh_TW'), isFalse);
      expect(PromptTranslationLanguage.isCode(null), isFalse);
    },
  );

  for (final language in PromptTranslationLanguage.values) {
    test('${language.code} remains a valid canonical reading language', () {
      expect(PromptTranslationLanguage.isCode(language.code), isTrue);
      expect(PromptTranslationLanguage.fromCode(language.code), language);
      expect(language.promptName, isNotEmpty);
      expect(language.badgePrefix, isNotEmpty);
    });
  }

  test('following the interface preserves region and script', () {
    expect(
      PromptTranslationLanguage.forLocale(
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      ),
      PromptTranslationLanguage.traditionalChinese,
    );
    expect(
      PromptTranslationLanguage.forLocale(const Locale('en', 'US')),
      PromptTranslationLanguage.english,
    );
  });
}
