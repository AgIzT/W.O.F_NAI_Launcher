part of 'nai_agent_block_binding.dart';

bool _hasDisplay(Map<String, dynamic> changes) =>
    const ['title', 'color', 'icon'].any(changes.containsKey);

void _validateDisplay(Map<String, dynamic> changes, {bool required = false}) {
  if (required || changes.containsKey('title')) {
    final title = changes['title'];
    if (title is! String ||
        title.trim().isEmpty ||
        title.trim().runes.length > 40) {
      throw const NaiAgentToolError(
        'invalid_arguments',
        'instance.title must contain 1..40 characters after trimming',
      );
    }
    changes['title'] = title.trim();
  }
  if (changes.containsKey('color')) {
    final color = changes['color'];
    if (color is! String ||
        !RegExp(r'^#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$').hasMatch(color)) {
      throw const NaiAgentToolError(
        'invalid_arguments',
        'instance.color must be #RRGGBB or #AARRGGBB',
      );
    }
    changes['color'] = (color.length == 7 ? '#FF${color.substring(1)}' : color)
        .toUpperCase();
  }
  if (changes.containsKey('icon') &&
      !kPromptBlockIconOptions.containsKey(changes['icon'])) {
    throw const NaiAgentToolError(
      'invalid_arguments',
      'instance.icon must be a preset key from nai-studio/references/blocks.md',
    );
  }
}

PillAnchorRange _anchor(
  Object? raw,
  PillDocument document, {
  required bool replace,
}) {
  if (raw is! Map ||
      raw.keys.any(
        (key) => !const {'text', 'occurrence', 'mode'}.contains(key),
      ) ||
      raw['text'] is! String ||
      (raw['text'] as String).isEmpty ||
      (raw.containsKey('occurrence') &&
          (raw['occurrence'] is! int || (raw['occurrence'] as int) < 0)) ||
      !(replace ? const {'replace'} : const {'before', 'after'}).contains(
        raw['mode'],
      )) {
    throw const NaiAgentToolError(
      'invalid_position',
      'anchor needs nonempty text, optional zero-based occurrence and a valid mode',
    );
  }
  try {
    return PillDocumentEditor.resolveAnchor(
      document.text,
      raw['text'] as String,
      occurrence: raw['occurrence'] as int?,
    );
  } on PillAnchorException catch (error) {
    throw NaiAgentToolError(
      error.code,
      'Anchor failed (${error.matches} matches)',
      {'matches': error.matches},
    );
  }
}

int _insertionPosition(Map<String, dynamic> params, PillDocument document) {
  if (params.containsKey('offset') && params.containsKey('anchor')) {
    throw const NaiAgentToolError(
      'invalid_position',
      'offset and anchor are mutually exclusive',
    );
  }
  if (params.containsKey('anchor')) {
    final range = _anchor(params['anchor'], document, replace: false);
    return (params['anchor'] as Map)['mode'] == 'before'
        ? range.start
        : range.end;
  }
  final offset = params['offset'];
  if (offset != null &&
      (offset is! int ||
          !PillDocumentEditor.isUtf16Boundary(document.text, offset))) {
    throw const NaiAgentToolError(
      'invalid_offset',
      'offset must be a raw document UTF-16 boundary; omit to append',
    );
  }
  return offset as int? ?? document.text.length;
}

List<PillInlineEdit> _inlinePlan(
  Map<String, dynamic> params,
  PillDocument document,
) {
  final convert = params['action'] == 'instance_convert';
  final segments = convert ? params['segments'] : [params];
  if (segments is! List || segments.isEmpty || segments.length > 64) {
    throw const NaiAgentToolError(
      'invalid_arguments',
      'Provide 1..64 segments',
    );
  }
  final edits = <PillInlineEdit>[];
  for (var index = 0; index < segments.length; index++) {
    try {
      final raw = segments[index];
      if (raw is! Map ||
          (convert &&
              raw.keys.any(
                (key) => !const {'anchor', 'kind', 'instance'}.contains(key),
              ))) {
        throw const NaiAgentToolError(
          'invalid_arguments',
          'Invalid segment object',
        );
      }
      final part = Map<String, dynamic>.from(raw);
      final kind = part['kind'];
      if (kind != 'temporary') {
        throw const NaiAgentToolError(
          'unsupported_kind',
          'kind must be temporary',
        );
      }
      final changes = _instanceChanges(
        part['instance'],
        optional: true,
        inline: true,
      );
      if (changes.containsKey('negative_content')) {
        throw const NaiAgentToolError(
          'unsupported_bundle',
          'Inline creation/conversion does not support negative_content; create a separate negative-scope instance',
        );
      }
      final PillAnchorRange range;
      String? selectedContent;
      if (convert) {
        range = _anchor(part['anchor'], document, replace: true);
        selectedContent = document.text.substring(range.start, range.end);
      } else {
        final offset = _insertionPosition(part, document);
        range = (start: offset, end: offset);
      }
      final selected = convert
          ? selectedContent ?? document.text.substring(range.start, range.end)
          : null;
      if (edits.any(
        (other) => range.start < other.end && other.start < range.end,
      )) {
        throw const NaiAgentToolError(
          'overlapping_segments',
          'Segments must not overlap',
        );
      }
      if (convert && changes['enabled'] == false) {
        throw const NaiAgentToolError(
          'projection_changed',
          'Converted segments must remain enabled',
        );
      }
      PillTempContent? temp;
      if (kind == 'temporary') {
        _validateDisplay(changes, required: true);
        final content = selected ?? changes['content'];
        if (content is! String ||
            PillDocumentEditor.stripMarkers(content) != content) {
          throw const NaiAgentToolError(
            'invalid_arguments',
            'instance.content is required and must not contain markers',
          );
        }
        if (convert &&
            changes.containsKey('content') &&
            changes['content'] != selected) {
          throw const NaiAgentToolError(
            'invalid_arguments',
            'Converted content must equal the selected text',
          );
        }
        temp = PillTempContent(
          content: content,
          originalContent: '',
          editedAt: DateTime.now(),
          editedBy: 'agent',
          title: changes['title'] as String,
          color: changes['color'] as String?,
          iconName: changes['icon'] as String?,
        );
      }
      edits.add(
        PillInlineEdit(
          start: range.start,
          end: range.end,
          temp: temp!,
          enabled: changes['enabled'] as bool? ?? true,
        ),
      );
    } on NaiAgentToolError catch (error) {
      if (!convert) rethrow;
      throw NaiAgentToolError(
        error.code,
        'Segment ${index + 1}: ${error.message}',
        {...error.details, 'segment': index + 1},
      );
    }
  }
  return edits;
}

void _validateExisting(Map<String, dynamic> params, PillInstance instance) {
  final action = params['action'];
  if (action == 'instance_update') {
    final changes = _instanceChanges(params['instance'], optional: false);
    if (_hasDisplay(changes) &&
        (instance.blockId.isNotEmpty || !instance.temporary)) {
      throw const NaiAgentToolError(
        'unsupported_kind',
        'Display fields can only edit library-free temporary blocks',
      );
    }
    if (instance.blockId.isEmpty && !instance.temporary) {
      throw const NaiAgentToolError(
        'unsupported_kind',
        'Invalid empty block instance',
      );
    }
    if (instance.blockId.isEmpty && changes.containsKey('negative_content')) {
      throw const NaiAgentToolError(
        'unsupported_bundle',
        'Library-free instances do not support negative_content',
      );
    }
  } else if (action == 'instance_promote') {
    if (instance.temp == null) {
      throw const NaiAgentToolError(
        'unsupported_kind',
        'Only temporary blocks can be promoted',
      );
    }
    final raw = params['changes'] ?? <String, dynamic>{};
    if (raw is! Map ||
        raw.keys.any(
          (key) =>
              !const {'title', 'folderId', 'color', 'iconName'}.contains(key),
        )) {
      throw const NaiAgentToolError(
        'invalid_changes',
        'Promote accepts title/folderId/color/iconName',
      );
    }
    validateNaiAgentBlockChanges({
      'title': instance.temp!.title,
      ...Map<String, dynamic>.from(raw),
    });
  }
}

Set<String> _affectedScopes(
  Map<String, dynamic> params,
  BridgeDraftSnapshot draft,
  String scope,
) {
  final scopes = <String>{scope};
  if (_document(draft, scope).instances[params['marker']]?.bundleId != null) {
    if (scope == PillScopes.main || scope == PillScopes.negative) {
      scopes.addAll([PillScopes.main, PillScopes.negative]);
    } else {
      final match = RegExp(r'^char:(.+):(pos|neg)$').firstMatch(scope)!;
      scopes.addAll([
        PillScopes.charPos(match[1]!),
        PillScopes.charNeg(match[1]!),
      ]);
    }
  }
  return scopes;
}

String _draftProjection(BridgeDraftSnapshot draft, String scope) {
  if (scope == PillScopes.main) return draft.fields['prompt'] as String;
  if (scope == PillScopes.negative) {
    return draft.fields['negative_prompt'] as String;
  }
  final match = RegExp(r'^char:(.+):(pos|neg)$').firstMatch(scope)!;
  final character = (draft.fields['characters'] as List)
      .cast<Map>()
      .singleWhere((c) => c['id'] == match[1]);
  return character[match[2] == 'pos' ? 'prompt' : 'uc'] as String;
}

List<String> _applyInline(
  Ref ref,
  Map<String, dynamic> params,
  String scope,
  PillDocument document,
  String projection,
) {
  final provider = pillWorkspaceProvider(scope);
  final edits = _inlinePlan(params, document);
  final lane = ref.read(provider.notifier);
  final convert = params['action'] == 'instance_convert';
  final tail = document.text.trimRight();
  final prefix =
      !convert &&
          !params.containsKey('offset') &&
          !params.containsKey('anchor') &&
          tail.isNotEmpty &&
          !tail.endsWith(',')
      ? ', '
      : '';
  return lane.applyInlineEdits(
    edits,
    prefix: prefix,
    document: document,
    afterApply: convert
        ? () {
            if (ref.read(provider).projection != projection) {
              throw const NaiAgentToolError(
                'projection_changed',
                'Conversion changed the generation projection; operation rolled back',
              );
            }
          }
        : null,
  );
}

void _removeInline(Ref ref, Map<String, dynamic> params, String scope) {
  final lane = ref.read(pillWorkspaceProvider(scope).notifier);
  var marker = params['marker'] as String;
  if (params['action'] == 'instance_delete') {
    if (params.containsKey('occurrence')) {
      marker = lane.isolateMarkerOccurrence(
        marker,
        occurrence: params['occurrence'] as int,
      );
    }
    lane.removeMarker(marker);
  } else {
    lane.expandMarker(marker, occurrence: params['occurrence'] as int? ?? 0);
  }
}

Map<String, dynamic> _readback(
  Ref ref,
  Set<String> scopes,
  Map<String, Set<String>> priorMarkers,
) {
  final result = <String, dynamic>{};
  for (final key in scopes) {
    final actual = ref.read(pillWorkspaceProvider(key));
    if (key == PillScopes.main) {
      ref
          .read(generationParamsNotifierProvider.notifier)
          .updatePromptImmediately(actual.projection);
    } else if (key == PillScopes.negative) {
      ref
          .read(generationParamsNotifierProvider.notifier)
          .updateNegativePromptImmediately(actual.projection);
    } else {
      ref
          .read(pillRollCoordinatorProvider)
          .syncLaneProjection(key, actual.projection);
    }
    result[key] = {
      'document': actual.document.toJson(),
      'projection': actual.projection,
      'inserted_markers': actual.document.instances.keys
          .where(
            (m) =>
                !(priorMarkers[key] ?? actual.document.instances.keys.toSet())
                    .contains(m),
          )
          .toList(),
    };
  }
  return result;
}
