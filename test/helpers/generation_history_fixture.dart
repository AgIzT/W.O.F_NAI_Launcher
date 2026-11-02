import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

import 'light_theme_contrast.dart' show InMemoryLocalStorageService;
import 'package:nai_launcher/core/utils/image_share_sanitizer.dart';
import 'package:nai_launcher/core/utils/nai_resolution_adapter.dart';
import 'package:nai_launcher/data/models/image/image_operation.dart';
import 'package:nai_launcher/presentation/providers/history_click_behavior_provider.dart';
import 'package:nai_launcher/presentation/providers/image_generation_provider.dart';

class HistoryCaptureStorage extends InMemoryLocalStorageService {
  @override
  String getHistoryClickBehavior() =>
      HistoryClickBehavior.selectPreview.storageValue;
}

// Layout tests use prototype assets when present, otherwise deterministic
// synthetic images. No external workspace or user gallery is required.
final _syntheticImages = <String, Uint8List>{};
Uint8List generationFixtureImage(String name) {
  final file = File('../../mockups/generation/assets/$name.jpg');
  if (file.existsSync()) return file.readAsBytesSync();
  return _syntheticImages.putIfAbsent(name, () {
    final seed = name.codeUnits.fold(0, (a, b) => a + b);
    final image = img.Image(width: 832, height: 1216);
    img.fill(image, color: img.ColorRgb8(40 + seed % 100, 75, 110));
    img.fillRect(
      image,
      x1: 80,
      y1: 160,
      x2: 750,
      y2: 1040,
      color: img.ColorRgb8(120, 100 + seed % 100, 160),
    );
    return Uint8List.fromList(img.encodePng(image));
  });
}

List<GeneratedImage> historyCaptureImages({bool mixed = false}) {
  final now = DateTime.now();
  final names = mixed
      ? ['canvas', 'g19', 'g07', 'g18']
      : ['canvas', 'h1', 'h2', 'g18'];
  final counts = mixed ? [1, 2, 2, 1] : [1, 2, 4, 2];
  final minutes = [42, 38, 31, 20];
  return [
    for (var batch = 0; batch < names.length; batch++)
      for (var index = 0; index < counts[batch]; index++)
        () {
          final bytes = generationFixtureImage(names[batch]);
          final dimensions = NaiResolutionAdapter.readImageSize(bytes)!;
          return GeneratedImage(
            id: 'capture-${mixed ? 'mixed' : 'prototype'}-$batch-$index',
            bytes: bytes,
            width: dimensions.$1,
            height: dimensions.$2,
            createdAt: DateTime(
              now.year,
              now.month,
              now.day,
              16,
              minutes[batch],
            ),
            generationRunId: batch + 1,
            batchIndex: index,
            operation: batch == 0 ? ImageOperation.upscale : null,
            kind: mixed && batch == 3
                ? GeneratedImageKind.failedStreamSnapshot
                : GeneratedImageKind.completed,
          );
        }(),
  ];
}

Future<void> prepareHistoryCaptureImages(List<GeneratedImage> images) async {
  final service = ShareImagePreparationService.instance;
  for (final image in images.where((image) => image.canDrag)) {
    final batch = image.generationRunId! - 1;
    final mixed = image.id.contains('mixed');
    final names = mixed
        ? ['canvas', 'g19', 'g07', 'g18']
        : ['canvas', 'h1', 'h2', 'g18'];
    service.enqueue(
      imageId: image.id,
      imageBytes: image.bytes,
      fileName: '${image.id}.jpg',
      stripMetadata: false,
      sourceFilePath:
          File(
            '../../mockups/generation/assets/${names[batch]}.jpg',
          ).existsSync()
          ? File(
              '../../mockups/generation/assets/${names[batch]}.jpg',
            ).absolute.path
          : null,
    );
    await service
        .waitUntilReady(image.id, stripMetadata: false)
        .timeout(const Duration(seconds: 5));
  }
}
