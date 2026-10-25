import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../database/asset_database_manager.dart';
import '../autocomplete/completion_models.dart';
import '../utils/tag_normalizer.dart';
import '../utils/app_support_directory.dart';
import 'tag_semantics_store.dart';
import '../wiki/tag_wiki_repository.dart';

/// Imported semantic hints; category/count describe this source snapshot only.
/// These are not user translations or replacements for a full Wiki article.
class TagSemanticProfile {
  const TagSemanticProfile({
    required this.tag,
    required this.synonymsZh,
    required this.coreZh,
    required this.summaryZh,
    required this.sourceCategory,
    required this.sourcePostCount,
  });

  final String tag, coreZh, summaryZh;
  final List<String> synonymsZh;
  final int sourceCategory, sourcePostCount;

  bool get complete =>
      coreZh.isNotEmpty && synonymsZh.isNotEmpty && summaryZh.isNotEmpty;

  factory TagSemanticProfile.fromRow(Map<String, Object?> row) =>
      TagSemanticProfile(
        tag: row['tag'] as String,
        synonymsZh: List<String>.unmodifiable(
          (jsonDecode(row['synonyms_zh'] as String) as List).cast<String>(),
        ),
        coreZh: row['core_zh'] as String,
        summaryZh: row['summary_zh'] as String,
        sourceCategory: row['category'] as int,
        sourcePostCount: row['source_post_count'] as int,
      );
}

class TagSemanticNameHit {
  const TagSemanticNameHit({required this.profile, required this.match});
  final TagSemanticProfile profile;
  final ChineseNameMatch match;
  String get tag => profile.tag;
}

/// Exact-tag data access, independent of the current completion/search pipeline.
class TagSemanticsRepository {
  const TagSemanticsRepository(
    this._databasePath, {
    this.supplements,
    this.currentWikiHash,
    this.catalogPath,
    this.runtimePath,
  });
  final Future<String> Function() _databasePath;
  final TagSemanticsStore? supplements;
  final Future<String> Function(String tag)? currentWikiHash;
  final Future<String> Function()? catalogPath;
  final Future<String?> Function()? runtimePath;

  Future<TagSemanticProfile?> find(String tag) async =>
      (await findAll([tag]))[TagNormalizer.normalize(tag)];

  Future<Map<String, TagSemanticProfile>> findAll(Iterable<String> tags) async {
    final names = tags
        .map(TagNormalizer.normalize)
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList();
    if (names.isEmpty) return const {};
    final db = await databaseFactoryFfi.openDatabase(
      await _databasePath(),
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      final result = <String, TagSemanticProfile>{};
      for (var offset = 0; offset < names.length; offset += 400) {
        final batch = names.skip(offset).take(400).toList();
        final rows = await db.query(
          'tag_semantics',
          where: 'tag IN (${List.filled(batch.length, '?').join(',')})',
          whereArgs: batch,
        );
        for (final row in rows) {
          final profile = TagSemanticProfile.fromRow(row);
          result[profile.tag] = profile;
        }
      }
      final overlay = await supplements?.findAll(names) ?? const {};
      for (final name in overlay.keys) {
        final prior = result[name];
        final row = overlay[name]!;
        final terms = (jsonDecode(row['synonyms_zh'] as String) as List)
            .cast<String>();
        final summaryCurrent =
            currentWikiHash == null ||
            row['summary_hash'] == await currentWikiHash!(name);
        result[name] = TagSemanticProfile(
          tag: name,
          coreZh: (row['core_zh'] as String).isNotEmpty
              ? row['core_zh'] as String
              : prior?.coreZh ?? '',
          synonymsZh: terms.isNotEmpty
              ? List.unmodifiable(terms)
              : prior?.synonymsZh ?? const [],
          summaryZh: summaryCurrent && (row['summary_zh'] as String).isNotEmpty
              ? row['summary_zh'] as String
              : prior?.summaryZh ?? '',
          sourceCategory: prior?.sourceCategory ?? 0,
          sourcePostCount: prior?.sourcePostCount ?? 0,
        );
      }
      return result;
    } finally {
      await db.close();
    }
  }

  /// Name lookup only. Natural-language scenes are handled by the local RAG.
  Future<List<String>> searchNames(String input, {int limit = 80}) async => [
    for (final hit in await searchNameMatches(input, limit: limit)) hit.tag,
  ];

  /// Returns the actual matched term so synonym equality is not lost when
  /// resolving old tag names through the authoritative catalog's aliases.
  Future<List<TagSemanticNameHit>> searchNameMatches(
    String input, {
    int limit = 80,
    CompletionCategoryFilter categoryFilter = CompletionCategoryFilter.all,
  }) async {
    final query = input.trim();
    if (query.isEmpty || !RegExp(r'[\u3400-\u9fff]').hasMatch(query)) {
      return const [];
    }
    final db = await databaseFactoryFfi.openDatabase(
      await _databasePath(),
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      var union =
          'SELECT tag,core_zh,synonyms_zh,summary_zh,category,source_post_count '
          'FROM tag_semantics';
      if (supplements != null) {
        await db.execute('ATTACH DATABASE ? AS supplements', [
          await supplements!.readyPath(),
        ]);
        union +=
            ' UNION ALL SELECT tag,core_zh,synonyms_zh,summary_zh,0 AS category,'
            '0 AS source_post_count FROM supplements.tag_semantics';
      }
      var identityCtes = '';
      var resolvedSql =
          'SELECT *,tag AS canonical,source_post_count AS current_count FROM ranked WHERE position=1 AND ${categoryFilter.sql('category')}';
      if (catalogPath != null) {
        await db.execute('ATTACH DATABASE ? AS catalog', [
          await catalogPath!(),
        ]);
        var hasRuntime = false;
        final runtime = await runtimePath?.call();
        if (runtime != null) {
          await db.execute('ATTACH DATABASE ? AS runtime', [runtime]);
          final tables = await db.rawQuery(
            "SELECT name FROM runtime.sqlite_master WHERE type='table' AND name='danbooru_tags'",
          );
          hasRuntime = tables.isNotEmpty;
        }
        final runtimeJoin = hasRuntime
            ? 'LEFT JOIN runtime.danbooru_tags live ON live.tag=t.name'
            : '';
        final category = hasRuntime
            ? 'COALESCE(live.category,t.category)'
            : 't.category';
        final count = hasRuntime
            ? 'COALESCE(live.post_count,t.post_count)'
            : 't.post_count';
        final runtimeMissing = hasRuntime
            ? 'AND NOT EXISTS(SELECT 1 FROM runtime.danbooru_tags live WHERE live.tag=r.tag)'
            : '';
        final runtimeNames = hasRuntime
            ? '''UNION ALL
          SELECT r.tag,live.tag,live.category,live.post_count
          FROM ranked r JOIN runtime.danbooru_tags live ON live.tag=r.tag
          WHERE r.position=1 AND NOT EXISTS(SELECT 1 FROM catalog.tags c WHERE c.name=r.tag)'''
            : '';
        // Resolve only semantic hits through indexed canonical/alias lookups.
        // Materializing every merged catalog identity on each keystroke would
        // cost seconds even when the Chinese query matches only a few names.
        identityCtes =
            '''identities AS (
          SELECT r.tag AS lookup,t.name AS canonical,$category AS category,$count AS post_count
          FROM ranked r JOIN catalog.tags t ON t.name=r.tag $runtimeJoin
          WHERE r.position=1
          $runtimeNames
          UNION ALL
          SELECT r.tag AS lookup,MIN(t.name) AS canonical,MIN($category),MIN($count)
          FROM ranked r JOIN catalog.aliases a ON a.alias=r.tag COLLATE NOCASE
          JOIN catalog.tags t ON t.id=a.tag_id $runtimeJoin
          WHERE r.position=1 AND NOT EXISTS(SELECT 1 FROM catalog.tags c WHERE c.name=r.tag)
          $runtimeMissing
          GROUP BY r.tag HAVING COUNT(DISTINCT t.name)=1
        ),''';
        resolvedSql = '''SELECT r.*,i.canonical,i.post_count AS current_count
          FROM ranked r JOIN identities i ON i.lookup=r.tag
          WHERE r.position=1 AND ${categoryFilter.sql('i.category')}''';
      }
      final rows = await db.rawQuery(
        '''WITH $identityCtes profiles AS ($union), terms AS (
          SELECT *,core_zh AS term,1 AS is_core FROM profiles
          UNION ALL SELECT s.*,j.value AS term,0 AS is_core
          FROM profiles s, json_each(s.synonyms_zh) j
        ), matched AS (
          SELECT *,CASE WHEN term=? THEN 0 WHEN instr(term,?)=1 THEN 1 ELSE 2 END AS quality
          FROM terms WHERE instr(term,?)>0
        ), ranked AS (
          SELECT *,ROW_NUMBER() OVER (
            PARTITION BY tag ORDER BY quality,is_core DESC,source_post_count DESC,term
          ) AS position FROM matched
        ), resolved AS ($resolvedSql), unique_tags AS (
          SELECT *,ROW_NUMBER() OVER(PARTITION BY canonical
            ORDER BY quality,is_core DESC,current_count DESC,tag) AS canonical_position
          FROM resolved
        ) SELECT * FROM unique_tags WHERE canonical_position=1
        ORDER BY quality,is_core DESC,current_count DESC,canonical LIMIT ?''',
        [query, query, query, limit.clamp(1, 100)],
      );
      return [
        for (final row in rows)
          TagSemanticNameHit(
            profile: TagSemanticProfile.fromRow(row),
            match: ChineseNameMatch(
              term: row['term'] as String,
              isCore: row['is_core'] == 1,
              kind: switch (row['quality']) {
                0 => CompletionMatchKind.chineseExact,
                1 => CompletionMatchKind.chinesePrefix,
                _ => CompletionMatchKind.chineseContains,
              },
            ),
          ),
      ];
    } finally {
      await db.close();
    }
  }
}

final tagSemanticsRepositoryProvider = Provider<TagSemanticsRepository>(
  (ref) => TagSemanticsRepository(
    AssetDatabaseManager.instance.ensureTagSemanticsDb,
    catalogPath: () async {
      await AssetDatabaseManager.initialize();
      return AssetDatabaseManager.instance.tagCatalogDbPath;
    },
    runtimePath: () async {
      final support = await getApplicationSupportDirectory();
      final file = File(p.join(support.path, 'databases', 'danbooru.db'));
      return await file.exists() ? file.path : null;
    },
    supplements: ref.watch(tagSemanticsStoreProvider),
    currentWikiHash: (tag) async => sha256
        .convert(
          utf8.encode(
            (await ref.read(tagWikiRepositoryProvider).find(tag))?.body ?? '',
          ),
        )
        .toString(),
  ),
);
