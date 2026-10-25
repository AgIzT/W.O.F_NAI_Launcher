import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/local_storage_service.dart';
import 'generation/generation_settings_notifiers.dart';

class PromptReadingPreferences {
  const PromptReadingPreferences({
    this.showReadings = true,
    this.completionEnabled = true,
  });

  final bool showReadings;
  final bool completionEnabled;
}

final promptReadingPreferencesProvider =
    NotifierProvider<
      PromptReadingPreferencesNotifier,
      PromptReadingPreferences
    >(PromptReadingPreferencesNotifier.new);

/// Display preferences are independent of the shared automatic AI preference.
class PromptReadingPreferencesNotifier
    extends Notifier<PromptReadingPreferences> {
  static const _showReadingsKey = 'prompt_show_readings';
  int _writeRevision = 0;

  @override
  PromptReadingPreferences build() {
    ref.listen(autocompleteSettingsProvider, (_, enabled) {
      state = PromptReadingPreferences(
        showReadings: state.showReadings,
        completionEnabled: enabled,
      );
    });
    return PromptReadingPreferences(
      showReadings:
          ref
              .read(localStorageServiceProvider)
              .getSetting<bool>(_showReadingsKey, defaultValue: true) ??
          true,
      completionEnabled: ref.read(autocompleteSettingsProvider),
    );
  }

  Future<void> toggleReadings() => setShowReadings(!state.showReadings);

  Future<void> setShowReadings(bool value) async {
    final previous = state.showReadings;
    final revision = ++_writeRevision;
    state = PromptReadingPreferences(
      showReadings: value,
      completionEnabled: state.completionEnabled,
    );
    try {
      await ref
          .read(localStorageServiceProvider)
          .setSetting(_showReadingsKey, value);
    } catch (_) {
      if (_writeRevision == revision) {
        state = PromptReadingPreferences(
          showReadings: previous,
          completionEnabled: state.completionEnabled,
        );
      }
      rethrow;
    }
  }

  void setCompletionEnabled(bool value) =>
      ref.read(autocompleteSettingsProvider.notifier).set(value);
}
