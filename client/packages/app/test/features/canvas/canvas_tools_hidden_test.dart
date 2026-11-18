// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The drawing tools fold away from the overflow, stay folded on this device,
/// and come back when a tool is armed another way.
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_tools_hidden.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/canvas_call_dock_fixtures.dart';
import 'canvas_pane_harness.dart';

const _menu = Duration(milliseconds: 400);

Future<ProviderContainer> _pane(WidgetTester tester, Size size) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fixture = CanvasPaneFixture();
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container);
  return container;
}

Future<void> _menuItem(WidgetTester tester, String label) async {
  await tester.tap(find.bySemanticsLabel('More canvas actions'));
  await tester.pump();
  await tester.pump(_menu);
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump(_menu);
}

void main() {
  for (final (name, width, compact) in [
    ('phone', 390.0, true),
    ('wide', 900.0, false),
  ]) {
    testWidgets('a $name dock with the tools folded has no tool strip', (
      tester,
    ) async {
      await pumpCanvasCallDock(
        tester,
        width: width,
        compact: compact,
        canvas: buildCanvasDockData(toolsHidden: true),
      );
      expect(find.bySemanticsLabel('Pen'), findsNothing);
      expect(find.bySemanticsLabel('Eraser'), findsNothing);
    });
  }

  testWidgets(
    'hiding the tools from the phone overflow folds the strip, puts the pen '
    'down and remembers it; showing brings them back',
    (tester) async {
      final container = await _pane(tester, const Size(390, 844));
      expect(find.bySemanticsLabel('Pen'), findsOneWidget);

      await _menuItem(tester, 'Hide drawing tools');

      expect(find.bySemanticsLabel('Pen'), findsNothing);
      expect(container.read(canvasToolsHiddenProvider), isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(canvasToolsHiddenKey), isTrue);
      final document = surfaceDocument(tester);
      final drag = await tester.startGesture(
        screenFor(tester, const Offset(120, 300)),
      );
      await drag.moveTo(screenFor(tester, const Offset(200, 380)));
      await drag.up();
      await tester.pump(_menu);
      expect(document.objectCount.value, 0, reason: 'a drag pans, not draws');

      await _menuItem(tester, 'Show drawing tools');
      expect(find.bySemanticsLabel('Pen'), findsOneWidget);
      expect(prefs.getBool(canvasToolsHiddenKey), isFalse);
    },
  );

  testWidgets('arming a tool by its key brings folded tools back', (
    tester,
  ) async {
    final container = await _pane(tester, const Size(1280, 800));
    await _menuItem(tester, 'Hide drawing tools');
    expect(find.bySemanticsLabel('Pen'), findsNothing);

    await tester.tap(find.bySemanticsLabel(RegExp(r'^Canvas, ')));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.pump(_menu);

    expect(container.read(canvasToolsHiddenProvider), isFalse);
    expect(find.bySemanticsLabel('Pen'), findsOneWidget);
  });

  test('a stored choice is restored', () async {
    SharedPreferences.setMockInitialValues({canvasToolsHiddenKey: true});
    final container = ProviderContainer(
      overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
    );
    addTearDown(container.dispose);
    await container.read(canvasToolsHiddenProvider.notifier).restore();
    expect(container.read(canvasToolsHiddenProvider), isTrue);
  });
}
