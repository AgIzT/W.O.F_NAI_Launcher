import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../prompt_assistant/services/prompt_assistant_service.dart';

/// Explicit, read-only translation of a complete prompt in an image viewer.
/// The returned text is never written to an editor or generation document.
final promptTextReadingTranslatorProvider =
    Provider<Future<String> Function(String, String)>(
      (ref) =>
          (source, sessionId) => ref
              .read(promptAssistantServiceProvider)
              .translatePromptReading(source, sessionId: sessionId),
    );
