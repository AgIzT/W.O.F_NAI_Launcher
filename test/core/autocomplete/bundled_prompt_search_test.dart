import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/autocomplete/chinese_tag_completion_source.dart';
import 'package:nai_launcher/core/autocomplete/completion_models.dart';
import 'package:nai_launcher/core/autocomplete/tag_catalog_repository.dart';
import 'package:nai_launcher/core/autocomplete/unified_tag_repository.dart';
import 'package:nai_launcher/core/tag_expansion/tag_semantics_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test(
    'bundled data supports English, Chinese tags and character names',
    () async {
      sqfliteFfiInit();
      final catalogPath = File('assets/databases/tag_catalog.db').absolute.path;
      final catalog = TagCatalogRepository(path: () async => catalogPath);
      addTearDown(catalog.dispose);
      final semantics = TagSemanticsRepository(
        () async => File('assets/databases/tag_semantics.db').absolute.path,
        catalogPath: () async => catalogPath,
      );
      final unified = UnifiedTagRepository(
        catalog: catalog,
        runtime: () => throw StateError('Bundled search must remain offline'),
        unionDatabase: ({required includeWiki}) =>
            databaseFactoryFfi.openDatabase(
              catalogPath,
              options: OpenDatabaseOptions(
                readOnly: true,
                singleInstance: false,
              ),
            ),
      );
      final chinese = ChineseTagCompletionSource(
        searchNames: semantics.searchNameMatches,
        resolveNames: unified.resolveExact,
      );
      for (final example in {
        'long ha': 'long_hair',
        'hatsune mi': 'hatsune_miku',
      }.entries) {
        final result = await catalog.search(
          CompletionQuery(
            fullText: example.key,
            cursorPosition: example.key.length,
            token: example.key,
            replacementRange: TextReplacementRange(
              start: 0,
              end: example.key.length,
            ),
            existingTags: const {},
            locale: 'zh',
            limit: 20,
          ),
        );
        expect(result.map((row) => row.canonicalTag), contains(example.value));
      }
      expect(
        (await chinese.search('长发', limit: 20)).first.canonicalTag,
        'long_hair',
      );
      for (final name in ['初音', '初音未来']) {
        final characters = await chinese.search(
          name,
          limit: 20,
          categoryFilter: CompletionCategoryFilter.characters,
        );
        expect(
          characters.map((row) => row.canonicalTag),
          contains('hatsune_miku'),
        );
        expect(
          characters.every((row) => row.category == TagCategory.character),
          isTrue,
        );
      }
    },
  );
}
