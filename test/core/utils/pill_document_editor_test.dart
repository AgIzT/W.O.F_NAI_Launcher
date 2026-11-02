import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/utils/pill_document_editor.dart';
import 'package:nai_launcher/data/models/prompt_block/pill_document.dart';

void main() {
  const markerA = '\uE000';
  const markerB = '\uE001';
  test('block instances require a nonempty library identity', () {
    for (final invalidId in [null, '', 1]) {
      expect(
        () => PillInstance.fromJson({'blockId': invalidId}),
        throwsFormatException,
      );
    }
  });

  group('anchor UTF-16 mapping', () {
    test('Chinese, emoji and weight syntax keep original positions', () {
      const text = '$markerA中文😀 1.2::x::$markerB结束';
      expect(PillDocumentEditor.resolveAnchor(text, '中文😀'), (
        start: 1,
        end: 5,
      ));
      expect(PillDocumentEditor.resolveAnchor(text, '1.2::x::'), (
        start: 6,
        end: 14,
      ));
      expect(PillDocumentEditor.resolveAnchor(text, '结束'), (
        start: 15,
        end: 17,
      ));
      expect(PillDocumentEditor.isUtf16Boundary(text, 4), isFalse);
      expect(
        () => PillDocumentEditor.resolveAnchor(text, '\uDE00'),
        throwsA(
          isA<PillAnchorException>().having(
            (e) => e.code,
            'code',
            'anchor_missing',
          ),
        ),
      );
    });
    test('adjacent markers are allowed, spanning markers is refused', () {
      const text = 'left${markerA}right';
      expect(PillDocumentEditor.resolveAnchor(text, 'left'), (
        start: 0,
        end: 4,
      ));
      expect(PillDocumentEditor.resolveAnchor(text, 'right'), (
        start: 5,
        end: 10,
      ));
      expect(
        () => PillDocumentEditor.resolveAnchor(text, 'leftright'),
        throwsA(
          isA<PillAnchorException>().having(
            (e) => e.code,
            'code',
            'anchor_crosses_marker',
          ),
        ),
      );
      expect(
        () => PillDocumentEditor.resolveAnchor(text, markerA),
        throwsA(
          isA<PillAnchorException>().having(
            (e) => e.code,
            'code',
            'invalid_position',
          ),
        ),
      );
    });
    test(
      'ambiguity reports count; occurrence selects original document match',
      () {
        const text = '重复$markerA重复';
        expect(
          () => PillDocumentEditor.resolveAnchor(text, '重复'),
          throwsA(
            isA<PillAnchorException>()
                .having((e) => e.matches, 'matches', 2)
                .having((e) => e.code, 'code', 'anchor_ambiguous'),
          ),
        );
        expect(PillDocumentEditor.resolveAnchor(text, '重复', occurrence: 1), (
          start: 3,
          end: 5,
        ));
        for (final occurrence in [-1, 2]) {
          expect(
            () => PillDocumentEditor.resolveAnchor(
              text,
              '重复',
              occurrence: occurrence,
            ),
            throwsA(
              isA<PillAnchorException>().having(
                (e) => e.code,
                'code',
                'anchor_missing',
              ),
            ),
          );
        }
      },
    );
  });

  group('allocateMarker / insertBlock', () {
    test(
      'negative marker survives document JSON without changing old markers',
      () {
        final negative = PillDocumentEditor.insertBlock(
          PillDocument.empty(),
          offset: 0,
          blockId: 'paired',
          useNegativeContent: true,
        );
        expect(negative.instances[markerA]!.useNegativeContent, isTrue);
        expect(
          PillDocument.fromJson(
            negative.toJson(),
          ).instances[markerA]!.useNegativeContent,
          isTrue,
        );
        expect(const PillInstance(blockId: 'old').useNegativeContent, isFalse);
      },
    );

    test('paired markers keep their shared identity and scope in JSON', () {
      final positive = PillDocumentEditor.insertBlock(
        PillDocument.empty(),
        offset: 0,
        blockId: 'pair',
        bundleId: 'insert-1',
        rollScopeMask: 2,
      );
      final negative = PillDocumentEditor.insertBlock(
        PillDocument.empty(),
        offset: 0,
        blockId: 'pair',
        useNegativeContent: true,
        bundleId: 'insert-1',
        rollScopeMask: 2,
      );
      final posRestored = PillDocument.fromJson(
        positive.toJson(),
      ).instances[markerA]!;
      final negRestored = PillDocument.fromJson(
        negative.toJson(),
      ).instances[markerA]!;
      expect(posRestored.bundleId, 'insert-1');
      expect(negRestored.bundleId, posRestored.bundleId);
      expect(posRestored.rollScopeMask, 2);
      expect(negRestored.rollScopeMask, 2);
    });

    test('allocates the smallest free private-use char', () {
      var doc = PillDocument.empty();
      doc = PillDocumentEditor.insertBlock(doc, offset: 0, blockId: 'a');
      expect(doc.text, markerA);
      expect(doc.instances[markerA]?.blockId, 'a');
      expect(doc.instances[markerA]?.enabled, isTrue);

      doc = PillDocumentEditor.insertBlock(doc, offset: 0, blockId: 'b');
      expect(doc.text, '$markerB$markerA');
      expect(doc.instances[markerB]?.blockId, 'b');
    });

    test('inserts at clamped offset inside existing text', () {
      final doc = PillDocumentEditor.insertBlock(
        const PillDocument(text: 'hello', instances: {}),
        offset: 99,
        blockId: 'a',
      );
      expect(doc.text, 'hello$markerA');

      final doc2 = PillDocumentEditor.insertBlock(doc, offset: 2, blockId: 'b');
      expect(doc2.text, 'he$markerB${'llo'}$markerA');
    });
  });

  group('moveMarker', () {
    test('moves forward with offset correction', () {
      // aAbBc → move A(0) to offset 4 → abBAc 形态
      const doc = PillDocument(
        text: 'a${markerA}b${markerB}c',
        instances: {
          markerA: PillInstance(blockId: 'a'),
          markerB: PillInstance(blockId: 'b'),
        },
      );
      final moved = PillDocumentEditor.moveMarker(
        doc,
        marker: markerA,
        occurrence: 0,
        newOffset: 4,
      );
      expect(moved.text, 'ab$markerB${markerA}c');
    });

    test('moves backward without correction', () {
      const doc = PillDocument(
        text: 'a${markerA}b${markerB}c',
        instances: {
          markerA: PillInstance(blockId: 'a'),
          markerB: PillInstance(blockId: 'b'),
        },
      );
      final moved = PillDocumentEditor.moveMarker(
        doc,
        marker: markerB,
        occurrence: 0,
        newOffset: 0,
      );
      expect(moved.text, '${markerB}a${markerA}bc');
    });

    test('moves the chosen occurrence when duplicated by paste', () {
      const doc = PillDocument(
        text: '$markerA x $markerA',
        instances: {markerA: PillInstance(blockId: 'a')},
      );
      final moved = PillDocumentEditor.moveMarker(
        doc,
        marker: markerA,
        occurrence: 1,
        newOffset: 0,
      );
      expect(moved.text, '$markerA$markerA x ');
      expect(moved.instances.length, 1);
    });

    test('missing marker is a no-op', () {
      const doc = PillDocument(
        text: 'plain',
        instances: {markerA: PillInstance(blockId: 'a')},
      );
      final moved = PillDocumentEditor.moveMarker(
        doc,
        marker: markerA,
        occurrence: 0,
        newOffset: 2,
      );
      expect(moved.text, 'plain');
    });
  });

  group('removeMarker / reconcile', () {
    test('removeMarker strips all occurrences and the instance', () {
      const doc = PillDocument(
        text: 'x$markerA y$markerA',
        instances: {markerA: PillInstance(blockId: 'a')},
      );
      final removed = PillDocumentEditor.removeMarker(doc, markerA);
      expect(removed.text, 'x y');
      expect(removed.instances, isEmpty);
    });

    test('reconcile drops instances whose marker left the text', () {
      const doc = PillDocument(
        text: 'a$markerA$markerB',
        instances: {
          markerA: PillInstance(blockId: 'a'),
          markerB: PillInstance(blockId: 'b'),
        },
      );
      // 用户删掉了 markerA 字符
      final reconciled = PillDocumentEditor.reconcile(doc, 'a$markerB');
      expect(reconciled.text, 'a$markerB');
      expect(reconciled.instances.keys, [markerB]);
    });

    test('reconcile with identical text returns the same document', () {
      const doc = PillDocument(
        text: 'a$markerA',
        instances: {markerA: PillInstance(blockId: 'a')},
      );
      expect(
        identical(PillDocumentEditor.reconcile(doc, 'a$markerA'), doc),
        isTrue,
      );
    });
  });

  group('project / stripMarkers', () {
    test('enabled instances expand, disabled and unknown vanish', () {
      const doc = PillDocument(
        text: 'pre $markerA mid $markerB post ${'\uE002'}',
        instances: {
          markerA: PillInstance(blockId: 'a'),
          markerB: PillInstance(blockId: 'b', enabled: false),
        },
      );
      final projection = PillDocumentEditor.project(doc, (instance) {
        return switch (instance.blockId) {
          'a' => 'AAA',
          'b' => 'BBB',
          _ => null,
        };
      });
      expect(projection, 'pre AAA mid  post ');
    });

    test('resolver returning null expands to empty', () {
      const doc = PillDocument(
        text: markerA,
        instances: {markerA: PillInstance(blockId: 'gone')},
      );
      expect(PillDocumentEditor.project(doc, (_) => null), '');
    });

    test('marker-aware resolver receives each marker identity', () {
      const doc = PillDocument(
        text: '$markerA$markerB',
        instances: {
          markerA: PillInstance(blockId: 'a'),
          markerB: PillInstance(blockId: 'b'),
        },
      );
      final projection = PillDocumentEditor.projectWithMarker(
        doc,
        (marker, instance) => '$marker:${instance.blockId}',
      );
      expect(projection, '$markerA:a$markerB:b');
    });

    test('stripMarkers removes every private-use marker', () {
      expect(PillDocumentEditor.stripMarkers('a$markerA\uE123b'), 'ab');
    });
  });

  group('json round trip', () {
    test('evolution defaults off and old instance json stays compatible', () {
      const instance = PillInstance(blockId: 'a');
      expect(instance.evolutionEnabled, isFalse);
      expect(PillInstance.fromJson({'blockId': 'a'}).evolutionEnabled, isFalse);
      expect(instance.toJson()['evolutionEnabled'], isFalse);
    });

    test('document survives toJson/fromJson with evolution state', () {
      const doc = PillDocument(
        text: 'x$markerA',
        instances: {
          markerA: PillInstance(
            blockId: 'a',
            enabled: false,
            evolutionEnabled: true,
          ),
        },
      );
      final restored = PillDocument.fromJson(doc.toJson());
      expect(restored, doc);
      expect(restored.instances[markerA]!.evolutionEnabled, isTrue);
    });
  });
}
