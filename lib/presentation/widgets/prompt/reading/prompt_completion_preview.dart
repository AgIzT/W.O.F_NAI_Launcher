import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/autocomplete/autocomplete_settings.dart';
import '../../../../core/autocomplete/completion_models.dart';
import '../../../../core/database/dictionary_revision.dart';
import '../../../../core/tag_expansion/tag_semantics_repository.dart';
import '../../../../core/utils/localization_extension.dart';
import '../../../../core/utils/tag_normalizer.dart';
import '../../../../core/wiki/tag_translation_glossary.dart';
import '../../../../core/wiki/tag_wiki_repository.dart';
import '../../../../data/datasources/remote/danbooru_api_service.dart';

class PromptCompletionPreviewData {
  const PromptCompletionPreviewData({
    this.profile,
    this.wiki,
    this.loadingOnline = false,
    this.failed = false,
  });
  final TagSemanticProfile? profile;
  final TagWikiEntry? wiki;
  final bool loadingOnline, failed;
}

/// A finite negative cache applies when the API reports no remote article.
/// Timeouts/errors are never recorded as an absent Wiki.
class PromptCompletionWikiCache {
  final _entries = <String, ({TagWikiEntry? wiki, DateTime expires})>{};
  ({TagWikiEntry? wiki, DateTime expires})? get(String tag) {
    final found = _entries[tag];
    if (found == null || found.expires.isBefore(DateTime.now())) {
      _entries.remove(tag);
      return null;
    }
    return found;
  }

  void put(String tag, TagWikiEntry? wiki) {
    if (_entries.length >= 100) _entries.remove(_entries.keys.first);
    _entries[tag] = (
      wiki: wiki,
      expires: DateTime.now().add(Duration(minutes: wiki == null ? 5 : 60)),
    );
  }
}

final promptCompletionWikiCacheProvider = Provider<PromptCompletionWikiCache>((
  ref,
) {
  ref.watch(dictionaryRevisionProvider);
  return PromptCompletionWikiCache();
});

typedef PromptCompletionPreviewQuery = ({String tag, bool online});

/// Legacy semantic names supply local hints without changing the Wiki request
/// key; every viewer of one canonical tag still shares network work.
final promptCompletionSemanticProfileProvider = FutureProvider.autoDispose
    .family<TagSemanticProfile?, String>((ref, tag) {
      ref.watch(dictionaryRevisionProvider);
      return ref.read(tagSemanticsRepositoryProvider).find(tag);
    });

/// Riverpod shares a request for identical previews. Closing its final viewer
/// cancels network work; a different field/tag cannot receive the old result.
final promptCompletionPreviewProvider = StreamProvider.autoDispose
    .family<PromptCompletionPreviewData, PromptCompletionPreviewQuery>((
      ref,
      query,
    ) async* {
      ref.watch(dictionaryRevisionProvider);
      final wikiRepository = ref.read(tagWikiRepositoryProvider);
      final semantics = ref.read(tagSemanticsRepositoryProvider);
      final cancel = CancelToken();
      var disposed = false;
      ref.onDispose(() {
        disposed = true;
        cancel.cancel();
      });
      TagWikiEntry? wiki;
      TagSemanticProfile? profile;
      var failed = false;
      await Future.wait([
        () async {
          try {
            wiki = await wikiRepository.find(query.tag);
          } catch (_) {
            failed = true;
          }
        }(),
        () async {
          try {
            profile = await semantics.find(query.tag);
          } catch (_) {
            failed = true;
          }
        }(),
      ]);
      if (disposed) return;
      if (wiki != null || !query.online) {
        yield PromptCompletionPreviewData(
          profile: profile,
          wiki: wiki,
          failed: failed,
        );
        return;
      }
      final cache = ref.read(promptCompletionWikiCacheProvider);
      final cached = cache.get(query.tag);
      if (cached != null) {
        yield PromptCompletionPreviewData(
          profile: profile,
          wiki: cached.wiki,
          failed: failed,
        );
        return;
      }
      yield PromptCompletionPreviewData(
        profile: profile,
        loadingOnline: true,
        failed: failed,
      );
      try {
        final raw = await ref
            .read(danbooruApiServiceProvider)
            .getWikiPage(query.tag, cancelToken: cancel);
        if (disposed) return;
        final body = raw?['body'];
        // Unexpected responses must remain retryable rather than poisoning the
        // absent-article cache. Transport failures are not cached.
        if (raw != null && body is! String) {
          throw const FormatException('Invalid Wiki response');
        }
        wiki = raw == null
            ? null
            : TagWikiEntry(
                tag: query.tag,
                body: body as String,
                sourceUrl: Uri.https(
                  'danbooru.donmai.us',
                  '/wiki_pages/${query.tag}',
                ).toString(),
              );
        cache.put(query.tag, wiki);
        yield PromptCompletionPreviewData(
          profile: profile,
          wiki: wiki,
          failed: failed,
        );
      } catch (_) {
        if (!disposed) {
          yield PromptCompletionPreviewData(profile: profile, failed: true);
        }
      }
    });

class PromptCompletionPreview extends ConsumerStatefulWidget {
  const PromptCompletionPreview({
    super.key,
    required this.candidate,
    required this.onClose,
  });
  final CompletionCandidate candidate;
  final VoidCallback onClose;
  @override
  ConsumerState<PromptCompletionPreview> createState() =>
      _PromptCompletionPreviewState();
}

class _PromptCompletionPreviewState
    extends ConsumerState<PromptCompletionPreview> {
  bool _expanded = false;
  @override
  Widget build(BuildContext context) {
    final candidate = widget.candidate;
    final query = (
      tag: candidate.canonicalTag,
      online: ref.watch(autocompleteSettingsProvider).danbooruEnabled,
    );
    final state = ref.watch(promptCompletionPreviewProvider(query));
    final data = state.asData?.value;
    final fallback =
        data?.profile == null &&
            candidate.semanticTag != null &&
            candidate.semanticTag != candidate.canonicalTag
        ? ref
              .watch(
                promptCompletionSemanticProfileProvider(candidate.semanticTag!),
              )
              .asData
              ?.value
        : null;
    final profile = data?.profile ?? fallback;
    final summary = profile?.summaryZh;
    final excerpt = TagTranslationGlossary.sourceDefinition(
      data?.wiki?.body ?? '',
    );
    final aliases = candidate.aliases;
    final synonyms = profile?.synonymsZh ?? const <String>[];
    return Padding(
      key: const Key('prompt-completion-preview'),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  TagNormalizer.toDisplay(candidate.canonicalTag),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              IconButton(
                onPressed: widget.onClose,
                tooltip: context.l10n.common_close,
                icon: const Icon(Icons.close, size: 16),
              ),
            ],
          ),
          if (summary?.isNotEmpty == true) ...[
            Text(
              context.l10n.promptCompletion_summary,
              style: Theme.of(context).textTheme.labelSmall,
            ),
            Text(
              summary!,
              maxLines: _expanded ? null : 4,
              overflow: _expanded ? null : TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
          ],
          if (excerpt != null) ...[
            Text(
              context.l10n.tagExpansion_wikiTitle,
              style: Theme.of(context).textTheme.labelSmall,
            ),
            Text(
              excerpt,
              maxLines: _expanded ? null : 4,
              overflow: _expanded ? null : TextOverflow.ellipsis,
            ),
          ],
          if (aliases.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              context.l10n.wiki_aliases,
              style: Theme.of(context).textTheme.labelSmall,
            ),
            Text(
              (_expanded ? aliases : aliases.take(4))
                  .map(TagNormalizer.toDisplay)
                  .join(' · '),
            ),
          ],
          if (synonyms.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              context.l10n.promptCompletion_synonyms,
              style: Theme.of(context).textTheme.labelSmall,
            ),
            Text((_expanded ? synonyms : synonyms.take(4)).join(' · ')),
          ],
          if (state.isLoading || data?.loadingOnline == true)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: LinearProgressIndicator(),
            ),
          if (data != null &&
              !data.loadingOnline &&
              data.wiki == null &&
              summary?.isNotEmpty != true)
            Text(context.l10n.tagExpansion_wikiUnavailable),
          if (state.hasError || data?.failed == true)
            TextButton.icon(
              onPressed: () =>
                  ref.invalidate(promptCompletionPreviewProvider(query)),
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(context.l10n.common_retry),
            ),
          Row(
            children: [
              if (excerpt != null ||
                  summary?.isNotEmpty == true ||
                  aliases.length > 4 ||
                  synonyms.length > 4)
                TextButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(
                    _expanded
                        ? context.l10n.common_collapse
                        : context.l10n.common_expand,
                  ),
                ),
              if (data?.wiki != null)
                TextButton.icon(
                  onPressed: () => launchUrl(
                    Uri.https(
                      'danbooru.donmai.us',
                      '/wiki_pages/${candidate.canonicalTag}',
                    ),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.open_in_new, size: 14),
                  label: Text(context.l10n.wiki_source),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
