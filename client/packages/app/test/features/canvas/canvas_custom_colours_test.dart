// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Any canvas colour: the custom tile opens the picker, the last few choices
/// are remembered per device, and the pen menu offers them.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_pen_style.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_recent_colours.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_tool_options.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_custom_colours.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/control_swatch_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

class _Harness extends ConsumerWidget {
  const _Harness(this.chosen, {this.selected = 'annotation'});

  final List<String> chosen;
  final String selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ControlSwatchRow(
    swatches: canvasCustomColourSwatches(
      context: context,
      ref: ref,
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

  test('the pen menu carries a Custom group only when given tiles', () {
    List<ControlOptionEntry> options(List<ControlSwatch> custom) =>
        canvasToolOptions(
          CanvasTool.pen,
          pen: const CanvasPenStyle(colorKey: '#3a7bd5'),
          onPenChanged: (_) {},
          shapeKind: CanvasShapeKind.rectangle,
          onShapeKindChanged: (_) {},
          customColours: custom,
        );
    List<String> headings(List<ControlOptionEntry> e) => [
      for (final entry in e)
        if (entry is ControlSwatchGroup) entry.heading,
    ];
    expect(headings(options(const [])), ['Colour']);
    final tile = ControlSwatch(
      label: 'Custom colour',
      selected: false,
      color: const Color(0xFF3A7BD5),
      onSelected: () {},
    );
    expect(headings(options([tile])), ['Colour', 'Custom']);
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
