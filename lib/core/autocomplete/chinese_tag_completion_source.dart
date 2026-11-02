import '../tag_expansion/tag_semantics_repository.dart';
import 'completion_models.dart';

typedef ResolveTagNames =
    Future<Map<String, CompletionCandidate>> Function(Iterable<String> names);

/// Joins Chinese evidence to current tag identities, preserving alias-only
/// legacy names without inventing a redirect for an existing canonical tag.
class ChineseTagCompletionSource {
  const ChineseTagCompletionSource({
    required this.searchNames,
    required this.resolveNames,
  });

  final Future<List<TagSemanticNameHit>> Function(
    String input, {
    int limit,
    CompletionCategoryFilter categoryFilter,
  })
  searchNames;
  final ResolveTagNames resolveNames;

  Future<List<CompletionCandidate>> search(
    String input, {
    int limit = 40,
    CompletionCategoryFilter categoryFilter = CompletionCategoryFilter.all,
  }) async {
    final hits = await searchNames(
      input,
      limit: (limit * 3).clamp(1, 100),
      categoryFilter: categoryFilter,
    );
    final resolved = await resolveNames(hits.map((hit) => hit.tag));
    final candidates = <String, CompletionCandidate>{};
    for (final hit in hits) {
      final target = resolved[hit.tag];
      if (target == null || !categoryFilter.accepts(target.category)) continue;
      final candidate = target.copyWith(
        translation: hit.profile.coreZh.isEmpty ? null : hit.profile.coreZh,
        chineseMatch: hit.match,
        semanticTag: hit.tag,
        matchKind: hit.match.kind,
        retrievalOrigins: [
          hit.match.isCore ? 'chinese-core' : 'chinese-synonym',
          if (target.canonicalTag != hit.tag) 'canonical-alias',
        ],
      );
      final prior = candidates[target.stableId];
      if (prior == null || compare(candidate, prior) < 0) {
        candidates[target.stableId] = candidate;
      }
    }
    return (candidates.values.toList()..sort(compare))
        .take(limit)
        .toList(growable: false);
  }

  static int compare(CompletionCandidate a, CompletionCandidate b) {
    final kind = a.matchKind.index.compareTo(b.matchKind.index);
    if (kind != 0) return kind;
    final evidence = (a.chineseMatch?.priority ?? 0).compareTo(
      b.chineseMatch?.priority ?? 0,
    );
    if (evidence != 0) return evidence;
    final count = b.postCount.compareTo(a.postCount);
    return count != 0 ? count : a.canonicalTag.compareTo(b.canonicalTag);
  }
}
