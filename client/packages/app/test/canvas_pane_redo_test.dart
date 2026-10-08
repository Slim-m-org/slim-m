// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Redo through the full pane: the keyboard chords and the button beside
/// Undo, each wired to the same ledger `canvas_ops_controller_redo_test.dart`
/// drives directly.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

import 'canvas_pane_harness.dart';

Future<CanvasPaneFixture> _drawAndUndo(WidgetTester tester) async {
  final fixture = CanvasPaneFixture();
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container);

  final gesture = await tester.startGesture(const Offset(100, 100));
  await gesture.moveTo(const Offset(160, 140));
  await gesture.up();
  await tester.pumpAndSettle();
  await tester.tap(find.bySemanticsLabel('Undo'));
  await tester.pumpAndSettle();
  expect(fixture.postedOps.single['kind'], 'remove');
  return fixture;
}

Future<void> _chord(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

AppIconButton _redoButton(WidgetTester tester) => tester.widget<AppIconButton>(
  find.ancestor(
    of: find.bySemanticsLabel('Redo'),
    matching: find.byType(AppIconButton),
  ),
);

void main() {
  testWidgets('Ctrl+Shift+Z redoes what Undo just reversed', (tester) async {
    final fixture = await _drawAndUndo(tester);

    await _chord(tester, LogicalKeyboardKey.keyZ, shift: true);

    expect(fixture.postedOps, hasLength(2));
    expect(fixture.postedOps.last['kind'], 'restore');
  });

  testWidgets('Ctrl+Y redoes what Undo just reversed', (tester) async {
    final fixture = await _drawAndUndo(tester);

    await _chord(tester, LogicalKeyboardKey.keyY);

    expect(fixture.postedOps, hasLength(2));
    expect(fixture.postedOps.last['kind'], 'restore');
  });

  testWidgets('Ctrl+Z alone still undoes and never redoes', (tester) async {
    final fixture = await _drawAndUndo(tester);

    await _chord(tester, LogicalKeyboardKey.keyZ);

    expect(fixture.postedOps, hasLength(1));
  });

  testWidgets('the Redo button is dimmed until something is undone', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    expect(_redoButton(tester).onPressed, isNull);

    final gesture = await tester.startGesture(const Offset(100, 100));
    await gesture.moveTo(const Offset(160, 140));
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Undo'));
    await tester.pumpAndSettle();
    expect(_redoButton(tester).onPressed, isNotNull);

    await tester.tap(find.bySemanticsLabel('Redo'));
    await tester.pumpAndSettle();

    expect(fixture.postedOps.last['kind'], 'restore');
    expect(_redoButton(tester).onPressed, isNull);
  });
}
