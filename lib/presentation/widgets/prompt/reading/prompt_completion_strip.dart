import 'package:flutter/material.dart';

import '../../../../core/autocomplete/completion_models.dart';
import '../../../../core/utils/localization_extension.dart';
import '../../../../core/utils/tag_normalizer.dart';
import '../../../ui/kit/ui_colors.dart';
import '../../../ui/kit/ui_text.dart';
import '../../autocomplete/tag_category_visuals.dart';
import 'prompt_completion_controller.dart';
import 'prompt_completion_preview.dart';

typedef PromptCompletionNameLookup = String? Function(String canonicalTag);
typedef PromptCompletionRowKey = GlobalKey Function(String stableId);

String promptCompletionCount(int count) => count >= 1000000
    ? '${(count / 1000000).toStringAsFixed(1)}m'
    : count >= 1000
    ? '${(count / 1000).toStringAsFixed(1)}k'
    : '$count';

String promptCompletionGroupLabel(
  BuildContext context,
  PromptCompletionGroup group,
) => switch (group) {
  PromptCompletionGroup.all => context.l10n.promptCompletion_all,
  PromptCompletionGroup.tags => context.l10n.promptCompletion_tags,
  PromptCompletionGroup.characters =>
    context.l10n.autocomplete_categoryCharacter,
  PromptCompletionGroup.works => context.l10n.promptCompletion_works,
};

/// Shared frame of both forms. The transparent Material hosts ink and chips.
Widget _surface(
  BuildContext context, {
  required Key key,
  required double radius,
  double? height,
  required Widget child,
}) {
  final c = context.ui;
  return Container(
    key: key,
    height: height,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: c.raised,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: c.line),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: c.dark ? .32 : .08),
          blurRadius: 10,
          offset: const Offset(0, 3),
        ),
      ],
    ),
    child: Material(type: MaterialType.transparency, child: child),
  );
}

/// Collapsed form: one row of candidates docked to the editor edge. Click
/// inserts; right-click or the trailing button opens the full list.
class PromptCompletionStrip extends StatelessWidget {
  const PromptCompletionStrip({
    super.key,
    required this.session,
    required this.nameFor,
    required this.rowKey,
    required this.scroll,
    required this.onPreview,
  });

  static const height = 46.0;

  final PromptCompletionController session;
  final PromptCompletionNameLookup nameFor;
  final PromptCompletionRowKey rowKey;
  final ScrollController scroll;
  final ValueChanged<CompletionCandidate> onPreview;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final candidates = session.candidates;
    return _surface(
      context,
      key: const Key('prompt-completion-strip'),
      radius: 8,
      height: height,
      child: Row(
        children: [
          Expanded(
            child: session.failed && candidates.isEmpty
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: session.retry,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: Text(context.l10n.common_retry),
                    ),
                  )
                : AnimatedOpacity(
                    opacity: session.stale ? .5 : 1,
                    duration: const Duration(milliseconds: 120),
                    child: ListView.separated(
                      controller: scroll,
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(5, 5, 5, 5),
                      itemCount: candidates.length,
                      separatorBuilder: (context, index) =>
                          PromptCompletionController.groupFor(
                                candidates[index].category,
                              ) ==
                              PromptCompletionController.groupFor(
                                candidates[index + 1].category,
                              )
                          ? const SizedBox(width: 4)
                          : Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 7,
                              ),
                              child: VerticalDivider(
                                width: 1,
                                thickness: 1,
                                color: c.line,
                              ),
                            ),
                      itemBuilder: (context, index) => _chip(
                        context,
                        candidates[index],
                        index == session.selectedIndex,
                      ),
                    ),
                  ),
          ),
          Container(width: 1, height: 22, color: c.line),
          IconButton(
            key: const Key('prompt-completion-expand'),
            tooltip: context.l10n.promptCompletion_expand,
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            color: c.muted,
            onPressed: () => session.setExpanded(true),
            icon: const Icon(Icons.unfold_more_rounded),
          ),
        ],
      ),
    );
  }

  Widget _chip(
    BuildContext context,
    CompletionCandidate candidate,
    bool selected,
  ) {
    final c = context.ui;
    final reading = nameFor(candidate.canonicalTag);
    return Material(
      key: rowKey(candidate.stableId),
      color: selected ? c.accent.withValues(alpha: .12) : c.control,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(
          color: selected ? c.accent.withValues(alpha: .7) : Colors.transparent,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('prompt-completion-chip-${candidate.stableId}'),
        onTap: () => session.apply(candidate),
        onSecondaryTap: () => onPreview(candidate),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      TagCategoryVisuals.icon(candidate.category),
                      size: 12,
                      color: TagCategoryVisuals.color(
                        context,
                        candidate.category,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        TagNormalizer.toDisplay(candidate.canonicalTag),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: UiText.sans(
                          12.5,
                          weight: FontWeight.w600,
                          color: c.ink,
                          height: 1.2,
                        ),
                      ),
                    ),
                    if (candidate.postCount > 0) ...[
                      const SizedBox(width: 5),
                      Text(
                        promptCompletionCount(candidate.postCount),
                        style: UiText.mono(9.5, color: c.faint, height: 1.2),
                      ),
                    ],
                  ],
                ),
                if (reading?.isNotEmpty == true)
                  Text(
                    reading!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: UiText.sans(10.5, color: c.muted, height: 1.25),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Expanded form, opened on demand: category filters, every candidate as a
/// row, and the Wiki/alias preview in place of the list.
class PromptCompletionPanel extends StatelessWidget {
  const PromptCompletionPanel({
    super.key,
    required this.session,
    required this.nameFor,
    required this.rowKey,
    required this.scroll,
    required this.preview,
    required this.onPreview,
    required this.onClosePreview,
  });

  final PromptCompletionController session;
  final PromptCompletionNameLookup nameFor;
  final PromptCompletionRowKey rowKey;
  final ScrollController scroll;
  final CompletionCandidate? preview;
  final ValueChanged<CompletionCandidate> onPreview;
  final VoidCallback onClosePreview;

  @override
  Widget build(BuildContext context) {
    return _surface(
      context,
      key: const Key('prompt-completion-panel'),
      radius: 10,
      child: switch (preview) {
        final candidate? => SingleChildScrollView(
          child: PromptCompletionPreview(
            key: ValueKey(candidate.stableId),
            candidate: candidate,
            onClose: onClosePreview,
          ),
        ),
        null => _list(context),
      },
    );
  }

  Widget _list(BuildContext context) {
    final c = context.ui;
    final candidates = session.candidates;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 4, 4),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    spacing: 4,
                    children: [
                      for (final group in PromptCompletionGroup.values)
                        ChoiceChip(
                          label: Text(
                            promptCompletionGroupLabel(context, group),
                          ),
                          selected: session.group == group,
                          showCheckmark: false,
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          labelStyle: UiText.sans(12, height: 1.2),
                          onSelected: (_) => session.setGroup(group),
                        ),
                    ],
                  ),
                ),
              ),
              IconButton(
                key: const Key('prompt-completion-collapse'),
                tooltip: context.l10n.common_collapse,
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                color: c.muted,
                onPressed: () => session.setExpanded(false),
                icon: const Icon(Icons.unfold_less_rounded),
              ),
            ],
          ),
        ),
        Divider(height: 1, thickness: 1, color: c.line),
        if (session.loading) const LinearProgressIndicator(minHeight: 2),
        if (session.failed)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: session.retry,
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(context.l10n.common_retry),
            ),
          ),
        if (!session.loading && !session.failed && candidates.isEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              context.l10n.tagExpansion_noResults,
              style: UiText.sans(12, color: c.muted),
            ),
          ),
        Flexible(
          child: AnimatedOpacity(
            opacity: session.stale ? .5 : 1,
            duration: const Duration(milliseconds: 120),
            child: ListView.builder(
              controller: scroll,
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: candidates.length,
              itemBuilder: (context, index) => _row(context, candidates, index),
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(
    BuildContext context,
    List<CompletionCandidate> candidates,
    int index,
  ) {
    final c = context.ui;
    final candidate = candidates[index];
    final group = PromptCompletionController.groupFor(candidate.category);
    final startsGroup =
        session.group == PromptCompletionGroup.all &&
        (index == 0 ||
            PromptCompletionController.groupFor(
                  candidates[index - 1].category,
                ) !=
                group);
    final reading = nameFor(candidate.canonicalTag);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (startsGroup)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
            child: Text(
              promptCompletionGroupLabel(context, group),
              style: UiText.sans(11, color: c.faint, height: 1.2),
            ),
          ),
        MouseRegion(
          onEnter: (_) => session.select(index),
          child: Material(
            key: rowKey(candidate.stableId),
            color: index == session.selectedIndex ? c.hover : c.raised,
            child: InkWell(
              onTap: () => session.apply(candidate),
              onSecondaryTap: () => onPreview(candidate),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
                child: Row(
                  children: [
                    Icon(
                      TagCategoryVisuals.icon(candidate.category),
                      size: 15,
                      color: TagCategoryVisuals.color(
                        context,
                        candidate.category,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          text: TagNormalizer.toDisplay(candidate.canonicalTag),
                          style: UiText.sans(13, color: c.ink, height: 1.3),
                          children: [
                            if (reading?.isNotEmpty == true)
                              TextSpan(
                                text: '  $reading',
                                style: UiText.sans(
                                  12,
                                  color: c.muted,
                                  height: 1.3,
                                ),
                              ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (candidate.postCount > 0)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(
                          promptCompletionCount(candidate.postCount),
                          style: UiText.mono(11, color: c.faint, height: 1.2),
                        ),
                      ),
                    IconButton(
                      key: ValueKey(
                        'prompt-completion-info-${candidate.stableId}',
                      ),
                      tooltip: context.l10n.tagExpansion_wikiTitle,
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      color: c.muted,
                      onPressed: () => onPreview(candidate),
                      icon: const Icon(Icons.info_outline),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
