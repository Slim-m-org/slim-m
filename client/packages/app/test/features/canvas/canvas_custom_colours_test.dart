// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Any canvas colour: the custom tile opens the picker, the last few choices
/// are remembered per device, and they stand in for the trailing named
/// colours of the one colour row.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_pen_style.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_recent_colours.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_custom_colours.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/control_swatch_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

class _Harness extends ConsumerWidget {
  const _Harness(this.chosen, {this.selected = 'annotation'});

  final List<String> chosen;
  final String selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ControlSwatchRow(
    swatches: canvasColourRow(
      context: context,
      ref: ref,
      defaults: canvasPenColourSwatches(
        selectedKey: selected,
        onChoose: chosen.add,
      ),
      selectedKey: selected,
      onChoose: chosen.add,
    ),
    close: () {},
  );
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  List<String> chosen, {
  Map<String, Object> stored = const {},
  String selected = 'annotation',
}) async {
  SharedPreferences.setMockInitialValues(stored);
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
  );
  addTearDown(container.dispose);
  await container.read(canvasRecentColoursProvider.notifier).restore();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(body: _Harness(chosen, selected: selected)),
      ),
    ),
  );
  return container;
}

List<String> _labels(WidgetTester tester) => tester
    .widget<ControlSwatchRow>(
      find.byWidgetPredicate((w) => w is ControlSwatchRow),
    )
    .swatches
    .map((s) => s.label)
    .toList();

void main() {
  testWidgets(
    'the custom tile opens the picker and a saved hex is chosen and remembered',
    (tester) async {
      final chosen = <String>[];
      final container = await _pump(tester, chosen);

      await tester.tap(find.bySemanticsLabel('Custom colour'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.enterText(
        find.byWidgetPredicate((w) => w is EditableText),
        '#3a7bd5',
      );
      await tester.tap(find.text('Save'));
      await tester.pump(const Duration(milliseconds: 600));

      expect(chosen, ['#3a7bd5']);
      expect(container.read(canvasRecentColoursProvider), ['#3a7bd5']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(canvasRecentColoursKey), ['#3a7bd5']);
      expect(find.bySemanticsLabel('Custom #3a7bd5'), findsOneWidget);
    },
  );

  testWidgets('cancelling the picker chooses nothing', (tester) async {
    final chosen = <String>[];
    await _pump(tester, chosen);

    await tester.tap(find.bySemanticsLabel('Custom colour'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 600));

    expect(chosen, isEmpty);
  });

  testWidgets(
    'a remembered colour is a tile that chooses it, and marks the one in use',
    (tester) async {
      final chosen = <String>[];
      await _pump(
        tester,
        chosen,
        stored: {
          canvasRecentColoursKey: ['#112233', '#445566'],
        },
        selected: '#445566',
      );

      await tester.tap(find.bySemanticsLabel('Custom #112233'));
      expect(chosen, ['#112233']);
      final inUse = tester.getSemantics(
        find.bySemanticsLabel('Custom #445566'),
      );
      // ignore: deprecated_member_use
      expect(inUse.hasFlag(SemanticsFlag.isSelected), isTrue);
    },
  );

  test('recents keep the newest five, newest first, without repeats', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
    );
    addTearDown(container.dispose);
    final recents = container.read(canvasRecentColoursProvider.notifier);
    for (final hex in [
      '#000001',
      '#000002',
      '#000003',
      '#000004',
      '#000005',
      '#000006',
      '#000003',
    ]) {
      await recents.remember(hex);
    }
    expect(container.read(canvasRecentColoursProvider), [
      '#000003',
      '#000006',
      '#000005',
      '#000004',
      '#000002',
    ]);
  });

  test('unreadable stored colours are dropped on restore', () async {
    SharedPreferences.setMockInitialValues({
      canvasRecentColoursKey: ['#abcdef', 'nope', '#12345', '#ABCDEF'],
    });
    final container = ProviderContainer(
      overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
    );
    addTearDown(container.dispose);
    await container.read(canvasRecentColoursProvider.notifier).restore();
    expect(container.read(canvasRecentColoursProvider), ['#abcdef']);
  });

  testWidgets(
    'recent picks stand in for the last named colours, and the picker ends '
    'the row',
    (tester) async {
      await _pump(
        tester,
        [],
        stored: {
          canvasRecentColoursKey: ['#112233', '#445566'],
        },
      );

      expect(_labels(tester), [
        'Coral',
        'Amber',
        'Green',
        'Blue',
        'Custom #112233',
        'Custom #445566',
        'Custom colour',
      ]);
    },
  );

  testWidgets(
    'the named colour in use keeps its tile, and the next one gives way',
    (tester) async {
      await _pump(
        tester,
        [],
        stored: {
          canvasRecentColoursKey: ['#112233', '#445566'],
        },
        selected: 'pink',
      );

      expect(_labels(tester), [
        'Coral',
        'Amber',
        'Green',
        'Pink',
        'Custom #112233',
        'Custom #445566',
        'Custom colour',
      ]);
      final inUse = tester.getSemantics(find.bySemanticsLabel('Pink'));
      // ignore: deprecated_member_use
      expect(inUse.hasFlag(SemanticsFlag.isSelected), isTrue);
    },
  );

  testWidgets(
    'a full set of recents keeps the named colour in use and the row length',
    (tester) async {
      await _pump(
        tester,
        [],
        stored: {
          canvasRecentColoursKey: [
            for (var i = 1; i <= canvasRecentColoursMax; i++) '#00000$i',
          ],
        },
        selected: 'purple',
      );

      final labels = _labels(tester);
      expect(labels.take(2), ['Coral', 'Purple']);
      expect(labels, hasLength(canvasPenColors.length + 1));
    },
  );

  testWidgets('a full set of recents still leaves the first named colour', (
    tester,
  ) async {
    await _pump(
      tester,
      [],
      stored: {
        canvasRecentColoursKey: [
          for (var i = 1; i <= canvasRecentColoursMax; i++) '#00000$i',
        ],
      },
    );

    final labels = _labels(tester);
    expect(labels.first, 'Coral');
    expect(labels, hasLength(canvasPenColors.length + 1));
    expect(labels.last, 'Custom colour');
  });

  testWidgets('no recents leave the six named colours and the picker', (
    tester,
  ) async {
    await _pump(tester, []);

    expect(_labels(tester), [
      for (final c in canvasPenColors) c.label,
      'Custom colour',
    ]);
  });

  test('a pen on a hex colour paints that colour', () {
    const pen = CanvasPenStyle(colorKey: '#3a7bd5');
    expect(pen.color, const Color(0xFF3A7BD5));
    expect(
      const CanvasPenStyle(colorKey: 'bogus').color,
      AppCanvasColors.annotation,
    );
  });
}
