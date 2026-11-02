import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/autocomplete/chinese_tag_completion_source.dart';
import 'package:nai_launcher/core/autocomplete/completion_models.dart';
import 'package:nai_launcher/core/autocomplete/tag_catalog_repository.dart';
import 'package:nai_launcher/core/autocomplete/unified_tag_repository.dart';
import 'package:nai_launcher/core/tag_expansion/tag_semantics_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/sqlite3.dart' as native;

void main() {
  late Directory directory;
  late TagCatalogRepository catalog;
  late TagSemanticsRepository semantics;
  late UnifiedTagRepository unified;
  late ChineseTagCompletionSource source;

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('chinese_completion_');
    final path = p.join(directory.path, 'fixture.db');
    final db = native.sqlite3.open(path);
    db.execute('''
      CREATE TABLE tags(id INTEGER PRIMARY KEY,name TEXT,category INTEGER,post_count INTEGER);
      CREATE TABLE aliases(id INTEGER PRIMARY KEY,tag_id INTEGER,alias TEXT);
      CREATE TABLE tag_semantics(tag TEXT PRIMARY KEY,core_zh TEXT,synonyms_zh TEXT,
        summary_zh TEXT,category INTEGER,source_post_count INTEGER);
      INSERT INTO tags VALUES (1,'hatsune_miku',4,100),(2,'vocaloid',3,999999),
        (3,'legacy_character',4,1),(4,'canonical_character',4,2);
      INSERT INTO aliases VALUES (1,1,'miku_hatsune'),(2,1,'miku'),
        (3,1,'ambiguous'),(4,2,'ambiguous'),(5,4,'legacy_character');
      INSERT INTO tag_semantics VALUES
        ('miku_hatsune','初音未来','["初音","电子歌姬"]','角色简释义',4,1),
        ('hatsune_miku','初音未来','["初音"]','角色简释义',4,100),
        ('vocaloid','虚拟歌手','["初音所属作品"]','作品简释义',3,999999),
        ('legacy_character','旧角色','["旧名"]','',4,1),
        ('ambiguous','歧义','[]','',4,1),
        ('not_in_catalog','缺失条目','[]','',0,1);
    ''');
    for (var index = 0; index < 30; index++) {
      db.execute('INSERT INTO tags VALUES (?,?,?,?)', [
        100 + index,
        'common_tag_$index',
        0,
        99999,
      ]);
      db.execute('INSERT INTO tag_semantics VALUES (?,?,?,?,?,?)', [
        'common_tag_$index',
        '共同',
        '[]',
        '',
        0,
        99999,
      ]);
    }
    db.execute('''
      INSERT INTO tags VALUES (200,'common_character',4,2),(201,'common_work',3,1);
      INSERT INTO aliases VALUES (200,200,'old_common_character');
      INSERT INTO tag_semantics VALUES ('old_common_character','共同','[]','',0,1),
        ('common_work','共同','[]','',0,1);
    ''');
    db.execute("INSERT INTO tags VALUES (300,'runtime_moved',0,1)");
    db.execute("INSERT INTO aliases VALUES (300,300,'old_runtime')");
    db.execute(
      "INSERT INTO tag_semantics VALUES ('old_runtime','动态角色','[]','',0,1)",
    );
    db.dispose();
    final runtimePath = p.join(directory.path, 'runtime.db');
    final runtimeDb = native.sqlite3.open(runtimePath);
    runtimeDb.execute(
      'CREATE TABLE danbooru_tags(tag TEXT PRIMARY KEY,category INTEGER,post_count INTEGER)',
    );
    runtimeDb.execute(
      "INSERT INTO danbooru_tags VALUES ('runtime_moved',4,200)",
    );
    runtimeDb.dispose();
    Future<Database> open() async {
      final db = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      await db.execute('ATTACH DATABASE ? AS runtime', [runtimePath]);
      return db;
    }

    catalog = TagCatalogRepository(database: await open());
    semantics = TagSemanticsRepository(
      () async => path,
      catalogPath: () async => path,
      runtimePath: () async => runtimePath,
    );
    unified = UnifiedTagRepository(
      catalog: catalog,
      runtime: () => throw StateError('Network/runtime never used'),
      unionDatabase: ({required includeWiki}) => open(),
    );
    source = ChineseTagCompletionSource(
      searchNames: semantics.searchNameMatches,
      resolveNames: unified.resolveExact,
    );
  });

  tearDown(() async {
    await catalog.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'Chinese category filtering uses synced category before the result limit',
    () async {
      final hits = await source.search(
        '动态角色',
        limit: 1,
        categoryFilter: CompletionCategoryFilter.characters,
      );
      expect(hits.single.canonicalTag, 'runtime_moved');
      expect(hits.single.category, TagCategory.character);
      expect(hits.single.postCount, 200);
      expect(
        await source.search(
          '动态角色',
          limit: 1,
          categoryFilter: CompletionCategoryFilter.tags,
        ),
        isEmpty,
      );
    },
  );

  test(
    'category SQL retrieves rare characters and works before applying limits',
    () async {
      final characters = await source.search(
        '共同',
        limit: 1,
        categoryFilter: CompletionCategoryFilter.characters,
      );
      expect(characters.single.canonicalTag, 'common_character');
      expect(characters.single.category, TagCategory.character);
      final works = await source.search(
        '共同',
        limit: 1,
        categoryFilter: CompletionCategoryFilter.works,
      );
      expect(works.single.canonicalTag, 'common_work');
      final english = await unified.searchContains(
        'common',
        limit: 1,
        categoryFilter: CompletionCategoryFilter.characters,
      );
      expect(english.single.canonicalTag, 'common_character');
      expect(english.single.aliases, contains('old_common_character'));
      expect(
        (await unified.searchContains(
          'common',
          limit: 1,
          categoryFilter: CompletionCategoryFilter.works,
        )).single.canonicalTag,
        'common_work',
      );
    },
  );

  test(
    'synonym equality outranks popular prefix and carries matched evidence',
    () async {
      final hits = await semantics.searchNameMatches('初音');
      expect(hits.first.match.kind, CompletionMatchKind.chineseExact);
      expect(hits.first.match.isCore, isFalse);
      expect(hits.first.match.term, '初音');
      final candidates = await source.search('初音');
      expect(candidates.map((c) => c.canonicalTag), [
        'hatsune_miku',
        'vocaloid',
      ]);
      expect(candidates.first.category, TagCategory.character);
      expect(candidates.last.category, TagCategory.copyright);
      expect(candidates.first.aliases, ['ambiguous', 'miku', 'miku_hatsune']);
      expect(candidates.first.chineseMatch?.term, '初音');
    },
  );

  test(
    'alias-only Chinese record resolves and uses current catalog popularity',
    () async {
      final candidates = await source.search('电子歌姬');
      expect(candidates.single.canonicalTag, 'hatsune_miku');
      expect(candidates.single.postCount, 100);
      expect(candidates.single.matchedAlias, 'miku_hatsune');
      expect(candidates.single.translation, '初音未来');
      expect(candidates.single.aliases, contains('miku'));
    },
  );

  test(
    'real canonical wins over same-named alias; ambiguous and absent names are skipped',
    () async {
      expect(
        (await source.search('旧角色')).single.canonicalTag,
        'legacy_character',
      );
      expect(await source.search('歧义'), isEmpty);
      expect(await source.search('缺失条目'), isEmpty);
      expect(await semantics.searchNameMatches("初音' OR 1=1 --"), isEmpty);
    },
  );
}
