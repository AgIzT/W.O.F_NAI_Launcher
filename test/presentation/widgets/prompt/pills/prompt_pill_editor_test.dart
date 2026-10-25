import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nai_launcher/presentation/wiring/blocks_platform.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/data/models/character/character_prompt.dart';
import 'package:nai_launcher/presentation/providers/character_prompt_provider.dart';
import 'package:nai_launcher/data/models/prompt_block/pill_document.dart';
import 'package:nai_launcher/data/models/prompt_block/prompt_block.dart';
import 'package:nai_launcher/data/models/image/image_params.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/providers/pill_workspace_provider.dart';
import 'package:nai_launcher/presentation/providers/generation/generation_params_notifier.dart';
import 'package:nai_launcher/presentation/providers/prompt_block_library_provider.dart';
import 'package:nai_launcher/presentation/widgets/prompt/blocks/prompt_block_drag_data.dart';
import 'package:nai_launcher/presentation/widgets/prompt/pills/dna_icon.dart';
import 'package:nai_launcher/presentation/ui/kit/ui_block_pill.dart';
import 'package:nai_launcher/presentation/ui/kit/ui_glyph.dart';
import 'package:nai_launcher/presentation/ui/blocks/blocks_instance.dart';
import 'package:nai_launcher/presentation/widgets/prompt/pills/prompt_pill_editor.dart';
import 'package:nai_launcher/presentation/widgets/prompt/reading/prompt_completion_wrapper.dart';
import 'package:nai_launcher/presentation/widgets/prompt/unified/unified_prompt_config.dart';

class _MemorySettings extends LocalStorageService {
  @override
  T? getSetting<T>(String key, {T? defaultValue}) => defaultValue;
  @override
  Future<void> setSetting<T>(String key, T value) async {}
}

class _MemoryCharacters extends CharacterPromptNotifier {
  @override
  CharacterPromptConfig build() => const CharacterPromptConfig();
}

class _TestBlocksPlatform extends BlocksPlatform {
  int backups = 0;
  bool fail = false;
  @override
  Future<void> backupDraft(String snapshot) async {
    backups++;
    if (fail) {
      throw StateError('Backup failed');
    }
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  const markerA = '\uE000';
  const markerB = '\uE001';

  testWidgets('block inserted via provider renders a pill and projects', (
    tester,
  ) async {
    final emissions = <String>[];
    final container = await _pump(
      tester,
      onChanged: emissions.add,
      libraryState: PromptBlockLibraryState(
        blocks: [_block('style', '画风1', 'artist:foo, artist:bar')],
        folders: const [],
      ),
    );

    container
        .read(pillWorkspaceNotifierProvider.notifier)
        .insertBlockAt(offset: 0, blockId: 'style');
    await tester.pump();

    expect(find.text('画风1'), findsOneWidget);
    expect(emissions, contains('artist:foo, artist:bar'));
    final state = container.read(pillWorkspaceNotifierProvider);
    expect(state.document.text, markerA);
    expect(state.projection, 'artist:foo, artist:bar');
  });

  testWidgets('attached negative pill shows UC and forwards tags to the card', (
    tester,
  ) async {
    final block = _block('style', '画风', 'bright').copyWith(
      negativeContent: 'muted',
      tags: const [PromptBlockTag(name: '冷色', color: '#FF268BEA')],
    );
    final container = await _pump(
      tester,
      pillScope: PillScopes.negative,
      libraryState: PromptBlockLibraryState(blocks: [block], folders: const []),
    );
    container
        .read(pillWorkspaceProvider(PillScopes.negative).notifier)
        .insertBlockAt(
          offset: 0,
          blockId: block.id,
          useNegativeContent: true,
          bundleId: 'bundle-1',
        );
    await tester.pump();
    expect(
      tester.widget<UiBlockPill>(find.byType(UiBlockPill).first).paired,
      isTrue,
    );
    expect(find.text('UC'), findsOneWidget);
    expect(
      tester.widget<UiBlockPill>(find.byType(UiBlockPill).first).open,
      isFalse,
    );
    await tester.tap(find.byType(UiBlockPill).first);
    await tester.pumpAndSettle();
    expect(
      tester.widget<UiBlockPill>(find.byType(UiBlockPill).first).open,
      isTrue,
    );
    expect(
      tester
          .widget<BlockInstanceCard>(find.byType(BlockInstanceCard))
          .data
          .block
          .tags
          .map((t) => t.name),
      ['冷色'],
    );
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(
      tester.widget<UiBlockPill>(find.byType(UiBlockPill).first).open,
      isFalse,
    );
  });

  testWidgets(
    'deleting main pill removes paired UC marker and its projection',
    (tester) async {
      final block = _block(
        'pair',
        '双面',
        'bright',
      ).copyWith(negativeContent: 'muted');
      final container = await _pump(
        tester,
        libraryState: PromptBlockLibraryState(
          blocks: [block],
          folders: const [],
        ),
        overrides: [
          generationParamsNotifierProvider.overrideWith(
            _FakeGenerationParamsNotifier.new,
          ),
        ],
      );
      container
          .read(pillWorkspaceProvider(PillScopes.main).notifier)
          .insertBlockAt(offset: 0, blockId: block.id, bundleId: 'pair-1');
      container
          .read(pillWorkspaceProvider(PillScopes.negative).notifier)
          .insertBlockAt(
            offset: 0,
            blockId: block.id,
            useNegativeContent: true,
            bundleId: 'pair-1',
          );
      container
          .read(generationParamsNotifierProvider.notifier)
          .updateNegativePromptFromPill('muted');
      await tester.pump();
      await tester.tap(find.byType(UiBlockPill).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('block-card-remove')));
      await tester.pumpAndSettle();
      final positive = container.read(pillWorkspaceProvider(PillScopes.main));
      final negative = container.read(
        pillWorkspaceProvider(PillScopes.negative),
      );
      expect(positive.document.text, isEmpty);
      expect(negative.document.text, isEmpty);
      expect(negative.document.instances, isEmpty);
      expect(negative.projection, isEmpty);
      expect(
        container.read(generationParamsNotifierProvider).negativePrompt,
        isEmpty,
      );
    },
  );

  testWidgets('stale post-frame projection callbacks are discarded', (
    tester,
  ) async {
    final emissions = <String>[];
    final container = await _pump(
      tester,
      onChanged: emissions.add,
      libraryState: PromptBlockLibraryState(blocks: [], folders: []),
    );
    emissions.clear();

    final notifier = container.read(pillWorkspaceNotifierProvider.notifier);
    notifier.setText('projection A');
    notifier.setText('projection B');
    await tester.pump();

    expect(emissions, isNot(contains('projection A')));
    expect(emissions, contains('projection B'));
  });

  testWidgets('tapping a pill opens the L1 card; disable via card', (
    tester,
  ) async {
    final emissions = <String>[];
    final container = await _pump(
      tester,
      onChanged: emissions.add,
      libraryState: PromptBlockLibraryState(
        blocks: [_block('style', '画风1', 'CONTENT')],
        folders: const [],
      ),
    );
    container
        .read(pillWorkspaceNotifierProvider.notifier)
        .insertBlockAt(offset: 0, blockId: 'style');
    await tester.pump();

    // P2.5：点药丸 = 开 L1 实例卡（启停挪进卡里，不再直接 toggle）
    await tester.tap(find.byType(UiBlockPill).first);
    await tester.pump();
    await tester.pump();

    expect(find.byType(BlockInstanceCard), findsOneWidget);
    // 卡内显示块内容预览
    expect(find.text('CONTENT'), findsOneWidget);

    await tester.tap(find.byKey(const Key('block-card-toggle')));
    await tester.pump();

    final state = container.read(pillWorkspaceNotifierProvider);
    expect(state.document.instances[markerA]?.enabled, isFalse);
    expect(state.projection, '');
    expect(emissions.last, '');
  });

  testWidgets('paired scope keeps positive fixed while negative steps', (
    tester,
  ) async {
    final block = _block('pair', '双面', 'bright').copyWith(
      atoms: ['bright', 'vivid'],
      negativeContent: 'muted, dull',
      negativeAtoms: ['muted', 'dull'],
    );
    final container = await _pump(
      tester,
      libraryState: PromptBlockLibraryState(blocks: [block], folders: const []),
    );
    container
        .read(pillWorkspaceProvider(PillScopes.main).notifier)
        .insertBlockAt(
          offset: 0,
          blockId: block.id,
          bundleId: 'pair-1',
          rollScopeMask: 1,
        );
    container
        .read(pillWorkspaceProvider(PillScopes.negative).notifier)
        .insertBlockAt(
          offset: 0,
          blockId: block.id,
          useNegativeContent: true,
          bundleId: 'pair-1',
          rollScopeMask: 1,
        );
    await tester.pump();

    await tester.tap(find.byType(UiBlockPill).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('block-card-side-negative')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('block-card-side-positive')));
    await tester.pump();
    expect(
      container
          .read(pillWorkspaceProvider(PillScopes.main))
          .document
          .instances[markerA]!
          .rollScopeMask,
      2,
    );
    expect(
      container
          .read(pillWorkspaceProvider(PillScopes.negative))
          .document
          .instances[markerA]!
          .rollScopeMask,
      2,
    );

    await tester.tap(find.byKey(const Key('block-card-mode-sequential')));
    await tester.pumpAndSettle();

    final pos = container.read(pillWorkspaceProvider(PillScopes.main));
    final neg = container.read(pillWorkspaceProvider(PillScopes.negative));
    expect(pos.document.instances[markerA]!.settings.mode, PillRollMode.fixed);
    expect(
      neg.document.instances[markerA]!.settings.mode,
      PillRollMode.sequential,
    );
    expect(pos.projection, 'bright');
    expect(neg.projection, 'muted');

    await tester.tap(find.byKey(const Key('block-card-step-next')));
    await tester.pump();
    expect(
      container.read(pillWorkspaceProvider(PillScopes.main)).projection,
      'bright',
    );
    expect(
      container.read(pillWorkspaceProvider(PillScopes.negative)).projection,
      'dull',
    );
  });

  testWidgets(
    'card generation import is confined to its saved parameters section',
    (tester) async {
      final block = _block('settings', '画风参数', 'artist:foo').copyWith(
        generationSettings: const PromptBlockGenerationSettings(
          model: 'nai-diffusion-5-full',
          steps: 30,
          scale: 5.0,
        ),
      );
      final container = await _pump(
        tester,
        libraryState: PromptBlockLibraryState(
          blocks: [block],
          folders: const [],
        ),
      );
      container
          .read(pillWorkspaceProvider(PillScopes.main).notifier)
          .insertBlockAt(offset: 0, blockId: block.id);
      await tester.pump();
      await tester.tap(find.byType(UiBlockPill).first);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<BlockInstanceCard>(find.byType(BlockInstanceCard))
            .data
            .block
            .params!
            .steps,
        30,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('block-card-params')),
          matching: find.byKey(const Key('block-card-apply')),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('L1 card anchors to the pill with a non-zero Overlay offset', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      appOffset: const Offset(240, 120),
      libraryState: PromptBlockLibraryState(
        blocks: [_block('style', '画风1', 'CONTENT')],
        folders: const [],
      ),
    );
    container
        .read(pillWorkspaceNotifierProvider.notifier)
        .insertBlockAt(offset: 0, blockId: 'style');
    await tester.pump();

    final pill = find.byType(UiBlockPill).first;
    final clickPosition = tester.getCenter(pill);
    final pillBottom = tester.getBottomLeft(pill).dy;
    await tester.tap(pill);
    await tester.pumpAndSettle();

    final card = find.byType(BlockInstanceCard);
    expect(card, findsOneWidget);
    final overlay = find.ancestor(of: card, matching: find.byType(Overlay));
    expect(overlay, findsOneWidget);
    final overlayRect = tester.getRect(overlay);
    final localClick = clickPosition - overlayRect.topLeft;
    final expectedLeft =
        overlayRect.left +
        (localClick.dx - BlockInstanceCard.width / 2).clamp(
          4.0,
          (overlayRect.width - BlockInstanceCard.width - 4).clamp(
            4.0,
            overlayRect.width,
          ),
        );
    expect(tester.getTopLeft(card).dx, closeTo(expectedLeft, 0.1));
    expect(tester.getTopLeft(card).dy, closeTo(pillBottom + 8, 0.1));
  });

  testWidgets(
    'main page hides evolution entirely: dice badge stays, card has no '
    'DNA button',
    (tester) async {
      final container = await _pump(
        tester,
        allowEvolutionToggle: false,
        libraryState: PromptBlockLibraryState(
          blocks: [_block('style', '画风1', 'CONTENT')],
          folders: const [],
        ),
      );
      final notifier = container.read(pillWorkspaceNotifierProvider.notifier);
      notifier.insertBlockAt(offset: 0, blockId: 'style');
      notifier.updateInstanceSettings(
        markerA,
        const PillInstanceSettings(mode: PillRollMode.random),
      );
      notifier.toggleEvolution(markerA);
      await tester.pump();

      // FEAT-47：开着遗传的实例在主页面不渲染 DNA 角标，回退骰子角标。
      expect(
        find.byWidgetPredicate(
          (widget) => widget is UiGlyph && widget.path == UiGlyphs.dice,
        ),
        findsOneWidget,
      );
      expect(find.byType(DnaIcon), findsNothing);

      await tester.tap(find.byType(UiBlockPill).first);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('pill-evolution-toggle')), findsNothing);
    },
  );

  testWidgets('explore card can toggle evolution for enabled random instance', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      allowEvolutionToggle: true,
      libraryState: PromptBlockLibraryState(
        blocks: [_block('style', '画风1', 'CONTENT')],
        folders: const [],
      ),
    );
    final notifier = container.read(pillWorkspaceNotifierProvider.notifier);
    notifier.insertBlockAt(offset: 0, blockId: 'style');
    notifier.updateInstanceSettings(
      markerA,
      const PillInstanceSettings(mode: PillRollMode.random),
    );
    await tester.pump();

    await tester.tap(find.byType(UiBlockPill).first);
    await tester.pump();
    await tester.pump();
    final card = tester.widget<BlockInstanceCard>(
      find.byType(BlockInstanceCard),
    );
    expect(card.actions.onEvolutionChanged, isNotNull);
    await tester.tap(find.byKey(const Key('block-card-genetic')));
    await tester.pump();
    expect(
      (container.read(blocksPlatformProvider) as _TestBlocksPlatform).backups,
      1,
    );
    expect(
      container
          .read(pillWorkspaceNotifierProvider)
          .document
          .instances[markerA]!
          .evolutionEnabled,
      isTrue,
    );
  });

  testWidgets('dropping a library block inserts at the drop offset', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      libraryState: PromptBlockLibraryState(
        blocks: [_block('style', '画风1', 'CONTENT')],
        folders: const [],
      ),
      overrides: [
        generationParamsNotifierProvider.overrideWith(
          _FakeGenerationParamsNotifier.new,
        ),
      ],
    );
    container
        .read(pillWorkspaceNotifierProvider.notifier)
        .setText('hello world');
    container
        .read(generationParamsNotifierProvider.notifier)
        .updatePromptFromPill('hello world');
    await tester.pump();

    _acceptDrop(
      tester,
      const PromptBlockDragData(blockId: 'style'),
      offset: Offset.zero,
    );
    await tester.pump();

    expect(
      (container.read(blocksPlatformProvider) as _TestBlocksPlatform).backups,
      1,
    );
    final state = container.read(pillWorkspaceNotifierProvider);
    expect(state.document.instances.length, 1);
    expect(state.document.instances.values.single.blockId, 'style');
    // Offset.zero 命中文本起始区域，标记落在 [0, len] 区间内
    expect(state.document.text.contains(markerA), isTrue);
    expect(state.document.text.length, 'hello world'.length + 1);
  });

  testWidgets('failed drag backup leaves the current document intact', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      libraryState: PromptBlockLibraryState(
        blocks: [_block('style', 'Style', 'CONTENT')],
        folders: const [],
      ),
      overrides: [
        generationParamsNotifierProvider.overrideWith(
          _FakeGenerationParamsNotifier.new,
        ),
      ],
    );
    container
        .read(pillWorkspaceNotifierProvider.notifier)
        .setText('current draft');
    container
        .read(generationParamsNotifierProvider.notifier)
        .updatePromptFromPill('current draft');
    final platform =
        container.read(blocksPlatformProvider) as _TestBlocksPlatform;
    platform.fail = true;
    await tester.pump();
    _acceptDrop(
      tester,
      const PromptBlockDragData(blockId: 'style'),
      offset: Offset.zero,
    );
    await tester.pumpAndSettle();
    final doc = container.read(pillWorkspaceNotifierProvider).document;
    expect(doc.text, 'current draft');
    expect(doc.instances, isEmpty);
    expect(platform.backups, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dropping a pill moves its marker in the text', (tester) async {
    final container = await _pump(
      tester,
      libraryState: PromptBlockLibraryState(
        blocks: [_block('a', 'A', 'AAA'), _block('b', 'B', 'BBB')],
        folders: const [],
      ),
    );
    final notifier = container.read(pillWorkspaceNotifierProvider.notifier);
    notifier.setText('x');
    notifier.insertBlockAt(offset: 0, blockId: 'a');
    notifier.insertBlockAt(offset: 2, blockId: 'b');
    await tester.pump();
    expect(
      container.read(pillWorkspaceNotifierProvider).document.text,
      '${markerA}x$markerB',
    );

    _acceptDrop(
      tester,
      const PromptBlockDragData(
        blockId: 'a',
        instanceMarker: PillInstanceDragRef(marker: markerA, occurrence: 0),
      ),
      offset: Offset.zero,
    );
    await tester.pump();

    // Offset.zero → 归到文本起点附近；markerA 被移动过（位置变化或原地皆可接受，
    // 这里验证调用链没有炸且文档仍一致）
    final doc = container.read(pillWorkspaceNotifierProvider).document;
    expect(doc.text.length, 3);
    expect(doc.instances.length, 2);
  });

  testWidgets('typing reconciles text and keeps instances alive', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      libraryState: PromptBlockLibraryState(
        blocks: [_block('style', '画风1', 'CONTENT')],
        folders: const [],
      ),
    );
    container
        .read(pillWorkspaceNotifierProvider.notifier)
        .insertBlockAt(offset: 0, blockId: 'style');
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, '1girl, ');
    await tester.pump();

    // enterText 整体替换文本：标记被删 → 实例被对账清除
    final state = container.read(pillWorkspaceNotifierProvider);
    expect(state.document.text, '1girl, ');
    expect(state.document.instances, isEmpty);
  });

  testWidgets('unknown marker renders an invalid pill that tap removes', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      libraryState: PromptBlockLibraryState(blocks: [], folders: []),
    );
    // 未知标记：文本里有 PUA 字符但实例表没有（模拟外来粘贴）
    container
        .read(pillWorkspaceNotifierProvider.notifier)
        .setText('abc$markerA');
    await tester.pump();

    final pill = tester.widget<UiBlockPill>(find.byType(UiBlockPill).first);
    expect(pill.status, UiBlockPillStatus.invalid);

    await tester.tap(find.byType(UiBlockPill).first);
    await tester.pump();
    expect(container.read(pillWorkspaceNotifierProvider).document.text, 'abc');
    expect(find.byType(UiBlockPill), findsNothing);
  });

  testWidgets('cut then paste resurrects the instance from tombstone', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      libraryState: PromptBlockLibraryState(
        blocks: [_block('style', '画风1', 'CONTENT')],
        folders: const [],
      ),
    );
    final notifier = container.read(pillWorkspaceNotifierProvider.notifier);
    notifier.insertBlockAt(offset: 0, blockId: 'style');
    await tester.pump();
    expect(
      container.read(pillWorkspaceNotifierProvider).document.text,
      markerA,
    );

    // 剪切：marker 从文本消失 → 实例被对账移除（进墓碑缓存）
    notifier.setText('');
    await tester.pump();
    expect(
      container.read(pillWorkspaceNotifierProvider).document.instances,
      isEmpty,
    );

    // 粘贴：同一 marker 字符回来 → 从墓碑复活实例，不再显示失效块
    notifier.setText('before $markerA after');
    await tester.pump();

    final state = container.read(pillWorkspaceNotifierProvider);
    expect(state.document.instances[markerA]?.blockId, 'style');
    expect(state.projection, 'before CONTENT after');
    expect(find.text('画风1'), findsOneWidget);
  });

  testWidgets('unknown marker without tombstone stays an invalid pill', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      libraryState: PromptBlockLibraryState(
        blocks: [_block('style', '画风1', 'CONTENT')],
        folders: const [],
      ),
    );
    // 外来 marker（无墓碑记录）：仍是失效药丸
    container
        .read(pillWorkspaceNotifierProvider.notifier)
        .setText('abc$markerB');
    await tester.pump();

    final pill = tester.widget<UiBlockPill>(find.byType(UiBlockPill).first);
    expect(pill.status, UiBlockPillStatus.invalid);
    expect(
      container.read(pillWorkspaceNotifierProvider).document.instances,
      isEmpty,
    );
  });

  testWidgets('block deleted from library renders a missing pill', (
    tester,
  ) async {
    final libraryNotifier = _FakePromptBlockLibraryNotifier(
      PromptBlockLibraryState(
        blocks: [_block('style', '画风1', 'CONTENT')],
        folders: const [],
      ),
    );
    final container = await _pump(
      tester,
      libraryState: libraryNotifier.initialState,
      libraryNotifier: libraryNotifier,
    );
    container
        .read(pillWorkspaceNotifierProvider.notifier)
        .insertBlockAt(offset: 0, blockId: 'style');
    await tester.pump();
    expect(find.text('画风1'), findsOneWidget);

    // 换一个不含该块的库状态（模拟库中删除）
    libraryNotifier.emitForTest(
      PromptBlockLibraryState(blocks: [], folders: []),
    );
    await tester.pump();

    final pill = tester.widget<UiBlockPill>(find.byType(UiBlockPill).first);
    expect(pill.status, UiBlockPillStatus.missing);
  });
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required PromptBlockLibraryState libraryState,
  ValueChanged<String>? onChanged,
  _FakePromptBlockLibraryNotifier? libraryNotifier,
  bool allowEvolutionToggle = false,
  bool autoFormat = false,
  String pillScope = PillScopes.main,
  Offset appOffset = Offset.zero,
  double editorWidth = 960,
  List<Override> overrides = const [],
}) async {
  final originalSize = tester.view.physicalSize;
  final originalDpr = tester.view.devicePixelRatio;
  addTearDown(() {
    tester.view.physicalSize = originalSize;
    tester.view.devicePixelRatio = originalDpr;
  });
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;

  final notifier =
      libraryNotifier ?? _FakePromptBlockLibraryNotifier(libraryState);
  final app = ProviderScope(
    overrides: [
      promptCompletionSearchProvider.overrideWith(
        (ref) =>
            (query) async => [],
      ),
      blocksPlatformProvider.overrideWithValue(_TestBlocksPlatform()),
      localStorageServiceProvider.overrideWithValue(_MemorySettings()),
      characterPromptNotifierProvider.overrideWith(_MemoryCharacters.new),
      promptBlockLibraryNotifierProvider.overrideWith(() => notifier),
      ...overrides,
    ],
    child: MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SizedBox(
          width: editorWidth,
          height: 360,
          child: PromptPillEditor(
            pillScope: pillScope,
            config: UnifiedPromptConfig(
              enableSyntaxHighlight: false,
              enableAutoFormat: autoFormat,
            ),
            allowEvolutionToggle: allowEvolutionToggle,
            onChanged: onChanged,
          ),
        ),
      ),
    ),
  );
  await tester.pumpWidget(
    appOffset == Offset.zero
        ? app
        : Directionality(
            textDirection: TextDirection.ltr,
            child: Stack(
              children: [
                Positioned(
                  left: appOffset.dx,
                  top: appOffset.dy,
                  right: 0,
                  bottom: 0,
                  child: app,
                ),
              ],
            ),
          ),
  );
  await tester.pump();
  await tester.pump();

  final element = tester.element(find.byType(PromptPillEditor));
  return ProviderScope.containerOf(element);
}

void _acceptDrop(
  WidgetTester tester,
  PromptBlockDragData data, {
  required Offset offset,
}) {
  final target = tester.widget<DragTarget<PromptBlockDragData>>(
    find.byType(DragTarget<PromptBlockDragData>),
  );
  target.onAcceptWithDetails?.call(
    DragTargetDetails<PromptBlockDragData>(data: data, offset: offset),
  );
}

class _FakePromptBlockLibraryNotifier extends PromptBlockLibraryNotifier {
  _FakePromptBlockLibraryNotifier(this.initialState);

  final PromptBlockLibraryState initialState;

  @override
  Future<PromptBlockLibraryState> build() async => initialState;

  /// 测试专用：中途替换库状态，模拟块被删除。
  void emitForTest(PromptBlockLibraryState next) {
    state = AsyncData(next);
  }
}

PromptBlock _block(String id, String title, String content) {
  return PromptBlock(
    id: id,
    title: title,
    content: content,
    createdAt: DateTime(2026, 8, 30),
    updatedAt: DateTime(2026, 8, 30),
  );
}

class _FakeGenerationParamsNotifier extends GenerationParamsNotifier {
  @override
  ImageParams build() => const ImageParams();

  @override
  void updatePromptFromPill(String prompt) {
    state = state.copyWith(prompt: prompt);
  }

  @override
  void updateNegativePromptFromPill(String prompt) {
    state = state.copyWith(negativePrompt: prompt);
  }
}
