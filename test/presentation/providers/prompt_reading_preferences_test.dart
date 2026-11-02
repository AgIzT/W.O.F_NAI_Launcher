import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/constants/storage_keys.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/presentation/providers/generation/generation_settings_notifiers.dart';
import 'package:nai_launcher/presentation/providers/prompt_reading_preferences_provider.dart';

class _MemoryStorage extends LocalStorageService {
  final values = <String, Object>{};
  bool fail = false;

  @override
  T? getSetting<T>(String key, {T? defaultValue}) =>
      values[key] as T? ?? defaultValue;

  @override
  Future<void> setSetting<T>(String key, T value) async {
    if (fail) throw StateError('write failed');
    values[key] = value as Object;
  }
}

void main() {
  test(
    'display and completion are independent and use existing completion key',
    () async {
      final storage = _MemoryStorage();
      final container = ProviderContainer(
        overrides: [localStorageServiceProvider.overrideWith((ref) => storage)],
      );
      addTearDown(container.dispose);
      expect(
        container.read(promptReadingPreferencesProvider).showReadings,
        isTrue,
      );
      final notifier = container.read(
        promptReadingPreferencesProvider.notifier,
      );
      await notifier.setShowReadings(false);
      notifier.setCompletionEnabled(false);
      expect(
        container.read(promptReadingPreferencesProvider).showReadings,
        isFalse,
      );
      expect(
        container.read(promptReadingPreferencesProvider).completionEnabled,
        isFalse,
      );
      expect(storage.values[StorageKeys.enableAutocomplete], isFalse);
      container.read(autocompleteSettingsProvider.notifier).set(true);
      expect(
        container.read(promptReadingPreferencesProvider).completionEnabled,
        isTrue,
      );
      expect(
        container.read(promptReadingPreferencesProvider).showReadings,
        isFalse,
      );
      expect(storage.values['prompt_show_readings'], isFalse);
    },
  );

  test(
    'a failed display save restores the last displayed preference',
    () async {
      final storage = _MemoryStorage()..fail = true;
      final container = ProviderContainer(
        overrides: [localStorageServiceProvider.overrideWith((ref) => storage)],
      );
      addTearDown(container.dispose);
      await expectLater(
        container
            .read(promptReadingPreferencesProvider.notifier)
            .setShowReadings(false),
        throwsStateError,
      );
      expect(
        container.read(promptReadingPreferencesProvider).showReadings,
        isTrue,
      );
    },
  );
}
