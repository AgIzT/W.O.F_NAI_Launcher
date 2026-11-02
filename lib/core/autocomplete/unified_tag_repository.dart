import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:nai_launcher/core/utils/app_support_directory.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../core/database/asset_database_manager.dart';
import '../../core/database/datasources/danbooru_tag_data_source.dart'
    show DanbooruTagDataSource, DanbooruTagRecord;
import '../../core/utils/app_logger.dart';
import 'completion_models.dart';
import 'tag_catalog_repository.dart';

/// One local tag view for the prompt picker and the encyclopedia.
///
/// The bundled catalog supplies aliases and a broad baseline. A completed
/// Danbooru sync overlays category and post count, and contributes new names.
/// No merged copy is persisted, so both consumers see the next committed sync.
class UnifiedTagRepository implements CompletionSource {
  UnifiedTagRepository({
    required TagCatalogRepository catalog,
    required Future<DanbooruTagDataSource> Function() runtime,
    Future<Database> Function({required bool includeWiki})? unionDatabase,
  }) : _catalog = catalog,
       _runtime = runtime,
       _unionDatabase = unionDatabase;

  final TagCatalogRepository _catalog;
  final Future<DanbooruTagDataSource> Function() _runtime;
  final Future<Database> Function({required bool includeWiki})? _unionDatabase;

  @override
  Future<List<CompletionCandidate>> search(CompletionQuery query) async {
    if (query.categoryFilter != CompletionCategoryFilter.all) {
      return _searchFiltered(query.token, query.limit, query.categoryFilter);
    }
    final bundled = _catalog.search(query);
    final live = _runtimeSearch(query.token, query.limit);
    return _merge(await bundled, await live, query.limit);
  }

  Future<List<CompletionCandidate>> searchContains(
    String input, {
    int limit = 20,
    CompletionCategoryFilter categoryFilter = CompletionCategoryFilter.all,
  }) async {
    if (categoryFilter != CompletionCategoryFilter.all) {
      return _searchFiltered(input, limit, categoryFilter, contains: true);
    }
    final bundled = _catalog.searchContains(input, limit: limit);
    final live = _runtimeSearch(input, limit, contains: true);
    return _merge(await bundled, await live, limit);
  }

  Future<List<CompletionCandidate>> _searchFiltered(
    String input,
    int limit,
    CompletionCategoryFilter filter, {
    bool contains = false,
  }) async {
    final normalized = input.trim().toLowerCase().replaceAll(' ', '_');
    if (normalized.isEmpty) return const [];
    final escaped = normalized
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    final pattern = '${contains ? '%' : ''}$escaped%';
    final db = await _openUnion();
    try {
      final union = _unionSql(await _hasRuntimeTable(db));
      // Both aliases and canonical names use the current merged category.
      // The SQL limit is applied after the category and match predicates.
      final rows = await db.rawQuery(
        '''
        WITH all_tags AS ($union), matches AS (
          SELECT t.name,t.category,t.post_count,t.name AS term,0 AS kind
          FROM all_tags t WHERE t.name LIKE ? ESCAPE '\\'
          AND ${filter.sql('t.category')}
          UNION ALL
          SELECT t.name,t.category,t.post_count,a.alias AS term,1 AS kind
          FROM aliases a JOIN tags original ON original.id=a.tag_id
          JOIN all_tags t ON t.name=original.name
          WHERE a.alias LIKE ? ESCAPE '\\' AND ${filter.sql('t.category')}
        ), ranked AS (
          SELECT *,CASE WHEN term=? THEN kind*2
            WHEN term LIKE ? ESCAPE '\\' THEN kind*2+1 ELSE 8 END AS quality
          FROM matches
        ), unique_tags AS (
          SELECT *,ROW_NUMBER() OVER (PARTITION BY name ORDER BY quality,term) AS position FROM ranked
        ) SELECT * FROM unique_tags WHERE position=1
        ORDER BY quality,post_count DESC,name LIMIT ?
      ''',
        [pattern, pattern, normalized, '$escaped%', limit.clamp(1, 100)],
      );
      final aliases = await _catalog.aliasesFor(
        rows.map((row) => row['name'] as String),
      );
      return [
        for (final row in rows)
          if (_fromRow(row) case final candidate?)
            candidate.copyWith(
              aliases: aliases[candidate.canonicalTag] ?? const [],
              matchedAlias: row['kind'] == 1 ? row['term'] as String : null,
              matchKind: switch (row['quality']) {
                0 => CompletionMatchKind.englishExact,
                1 => CompletionMatchKind.englishPrefix,
                2 => CompletionMatchKind.aliasExact,
                3 => CompletionMatchKind.aliasPrefix,
                _ => CompletionMatchKind.fullText,
              },
            ),
      ];
    } finally {
      await db.close();
    }
  }

  Future<List<CompletionCandidate>> popular({int limit = 12}) async {
    final bundled = _catalog.popular(limit: limit + 80);
    List<CompletionCandidate> live = const [];
    try {
      final records = await (await _runtime()).getHotTags(
        limit: limit + 80,
        category: 0,
        minPostCount: 0,
      );
      live = records
          .map(_fromRuntime)
          .whereType<CompletionCandidate>()
          .toList();
    } catch (error) {
      AppLogger.w('Runtime tag index unavailable: $error', 'UnifiedTags');
    }
    return _merge(await bundled, live, limit);
  }

  Future<List<CompletionCandidate>> _runtimeSearch(
    String input,
    int limit, {
    bool contains = false,
  }) async {
    try {
      final source = await _runtime();
      final records = contains
          ? await source.searchFuzzy(input, limit: limit)
          : await source.search(input, limit: limit);
      final normalized = input.trim().toLowerCase().replaceAll(' ', '_');
      return records
          .map(_fromRuntime)
          .whereType<CompletionCandidate>()
          .map(
            (candidate) => candidate.copyWith(
              matchKind: candidate.canonicalTag == normalized
                  ? CompletionMatchKind.englishExact
                  : candidate.canonicalTag.startsWith(normalized)
                  ? CompletionMatchKind.englishPrefix
                  : CompletionMatchKind.fullText,
            ),
          )
          .toList();
    } catch (error) {
      AppLogger.w('Runtime tag search unavailable: $error', 'UnifiedTags');
      return const [];
    }
  }

  static CompletionCandidate? _fromRuntime(DanbooruTagRecord record) {
    final category = TagCategory.fromDanbooru(record.category);
    if (category == null) return null;
    return CompletionCandidate(
      canonicalTag: record.tag,
      category: category,
      postCount: record.postCount,
      matchKind: CompletionMatchKind.fullText,
      sources: const {CompletionSourceKind.base},
    );
  }

  static List<CompletionCandidate> _merge(
    List<CompletionCandidate> bundled,
    List<CompletionCandidate> live,
    int limit,
  ) {
    final byName = <String, CompletionCandidate>{
      for (final candidate in bundled) candidate.canonicalTag: candidate,
    };
    for (final candidate in live) {
      final prior = byName[candidate.canonicalTag];
      byName[candidate.canonicalTag] = prior == null
          ? candidate
          : prior.copyWith(
              category: candidate.category,
              postCount: candidate.postCount,
            );
    }
    final result = byName.values.toList()
      ..sort((a, b) {
        final rank = a.matchKind.index.compareTo(b.matchKind.index);
        if (rank != 0) return rank;
        final count = b.postCount.compareTo(a.postCount);
        return count != 0 ? count : a.canonicalTag.compareTo(b.canonicalTag);
      });
    return result.take(limit).toList(growable: false);
  }

  /// Stable, paged browsing over the union of bundled and synced tag names.
  Future<List<CompletionCandidate>> browse({
    TagCategory? category,
    bool? hasWiki,
    bool alphabetical = false,
    int offset = 0,
    int limit = 80,
  }) async {
    final db = await _openUnion(includeWiki: hasWiki != null);
    try {
      final runtime = await _hasRuntimeTable(db);
      final union = _unionSql(runtime);
      final categories = _rawCategories(category);
      final clauses = <String>[
        if (categories.isNotEmpty)
          'category IN (${List.filled(categories.length, '?').join(',')})',
        if (hasWiki == true)
          'EXISTS (SELECT 1 FROM wiki.wiki_pages w WHERE w.tag = all_tags.name)',
        if (hasWiki == false)
          'NOT EXISTS (SELECT 1 FROM wiki.wiki_pages w WHERE w.tag = all_tags.name)',
      ];
      final filter = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
      final order = alphabetical
          ? 'name COLLATE NOCASE ASC'
          : 'post_count DESC, name COLLATE NOCASE ASC';
      final rows = await db.rawQuery(
        'WITH all_tags AS ($union) '
        'SELECT name, category, post_count FROM all_tags $filter '
        'ORDER BY $order LIMIT ? OFFSET ?',
        [...categories, limit, offset],
      );
      return rows
          .map(_fromRow)
          .whereType<CompletionCandidate>()
          .toList(growable: false);
    } finally {
      await db.close();
    }
  }

  Future<int> count({TagCategory? category, bool? hasWiki}) async {
    final db = await _openUnion(includeWiki: hasWiki != null);
    try {
      final union = _unionSql(await _hasRuntimeTable(db));
      final categories = _rawCategories(category);
      final clauses = <String>[
        if (categories.isNotEmpty)
          'category IN (${List.filled(categories.length, '?').join(',')})',
        if (hasWiki == true)
          'EXISTS (SELECT 1 FROM wiki.wiki_pages w WHERE w.tag = all_tags.name)',
        if (hasWiki == false)
          'NOT EXISTS (SELECT 1 FROM wiki.wiki_pages w WHERE w.tag = all_tags.name)',
      ];
      final filter = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
      final rows = await db.rawQuery(
        'WITH all_tags AS ($union) SELECT COUNT(*) AS total FROM all_tags $filter',
        categories,
      );
      return (rows.single['total'] as num).toInt();
    } finally {
      await db.close();
    }
  }

  Future<List<CompletionCandidate>> byNames(Iterable<String> names) async {
    final normalized = names
        .map((name) => name.trim().toLowerCase().replaceAll(' ', '_'))
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList();
    if (normalized.isEmpty) return const [];
    final db = await _openUnion();
    try {
      final union = _unionSql(await _hasRuntimeTable(db));
      final result = <String, CompletionCandidate>{};
      for (var start = 0; start < normalized.length; start += 400) {
        final chunk = normalized.skip(start).take(400).toList();
        final placeholders = List.filled(chunk.length, '?').join(',');
        final rows = await db.rawQuery(
          'WITH all_tags AS ($union) SELECT name, category, post_count '
          'FROM all_tags WHERE name IN ($placeholders)',
          chunk,
        );
        for (final row in rows) {
          final candidate = _fromRow(row);
          if (candidate != null) result[candidate.canonicalTag] = candidate;
        }
      }
      final aliases = await _catalog.aliasesFor(result.keys);
      return [
        for (final name in normalized)
          if (result[name] case final candidate?)
            candidate.copyWith(aliases: aliases[name] ?? const []),
      ];
    } finally {
      await db.close();
    }
  }

  Future<Map<String, CompletionCandidate>> resolveExact(
    Iterable<String> terms,
  ) async {
    final names = terms
        .map(
          (term) => term.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '_'),
        )
        .toSet();
    final canonical = await byNames(names);
    final result = {for (final item in canonical) item.canonicalTag: item};
    final aliases = await _catalog.exactAliases(
      names.difference(result.keys.toSet()),
    );
    // Resolve only unambiguous aliases and load authoritative category/count
    // plus the full alias list for their canonical targets.
    final targets = {
      for (final candidate in await byNames(
        aliases.values.map((candidate) => candidate.canonicalTag),
      ))
        candidate.canonicalTag: candidate,
    };
    for (final entry in aliases.entries) {
      final target = targets[entry.value.canonicalTag];
      if (target != null) {
        result[entry.key] = target.copyWith(matchedAlias: entry.key);
      }
    }
    return result;
  }

  static CompletionCandidate? _fromRow(Map<String, Object?> row) {
    final category = TagCategory.fromCatalog((row['category'] as num).toInt());
    if (category == null) return null;
    return CompletionCandidate(
      canonicalTag: row['name'] as String,
      category: category,
      postCount: (row['post_count'] as num).toInt(),
      matchKind: CompletionMatchKind.fullText,
      sources: const {CompletionSourceKind.base},
    );
  }

  Future<Database> _openUnion({bool includeWiki = false}) async {
    if (_unionDatabase case final override?) {
      return override(includeWiki: includeWiki);
    }
    final db = await AssetDatabaseManager.instance.openTagCatalogDatabase();
    final support = await getApplicationSupportDirectory();
    final runtime = File(p.join(support.path, 'databases', 'danbooru.db'));
    if (await runtime.exists()) {
      try {
        await db.execute('ATTACH DATABASE ? AS runtime', [runtime.path]);
      } catch (error) {
        AppLogger.w('Could not attach runtime tags: $error', 'UnifiedTags');
      }
    }
    if (includeWiki) {
      final wiki = await AssetDatabaseManager.instance.ensureTagWikiDb();
      await db.execute('ATTACH DATABASE ? AS wiki', [wiki]);
    }
    return db;
  }

  static Future<bool> _hasRuntimeTable(Database db) async {
    final rows = await db.rawQuery('PRAGMA database_list');
    if (!rows.any((row) => row['name'] == 'runtime')) return false;
    final tables = await db.rawQuery(
      "SELECT name FROM runtime.sqlite_master WHERE type='table' "
      "AND name='danbooru_tags'",
    );
    return tables.isNotEmpty;
  }

  static String _unionSql(bool runtime) => runtime
      ? 'SELECT tag AS name, category, post_count FROM runtime.danbooru_tags '
            'UNION ALL SELECT t.name, t.category, t.post_count FROM tags t '
            'WHERE NOT EXISTS (SELECT 1 FROM runtime.danbooru_tags r '
            'WHERE r.tag = t.name)'
      : 'SELECT name, category, post_count FROM tags';

  static List<int> _rawCategories(TagCategory? category) => switch (category) {
    TagCategory.general => [0, 7],
    TagCategory.artist => [1, 8],
    TagCategory.copyright => [3, 10],
    TagCategory.character => [4, 11],
    TagCategory.meta => [5, 14],
    TagCategory.contributor => [9],
    TagCategory.species => [12],
    TagCategory.lore => [15],
    _ => const [],
  };
}
