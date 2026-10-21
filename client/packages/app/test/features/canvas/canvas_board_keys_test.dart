// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The board is drivable from the keyboard: it holds focus when the pane
/// opens, arrows pan, ] and [ step the selection, Enter opens the selected
/// object's menu or places with the armed tool (C-091).
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'canvas_pane_harness.dart';

Future<CanvasPaneFixture> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fixture = CanvasPaneFixture()
    ..objects = [
      canvasNoteJson('a', x: 40, text: 'first'),
      canvasNoteJson('b', x: 300, seq: 2, text: 'second'),
    ];
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container);
  await tester.pumpAndSettle();
  return fixture;
}

void main() {
  testWidgets('] steps the selection through the objects in view', (
    tester,
  ) async {
    await _pump(tester);
    final document = surfaceDocument(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    final first = document.selectedObjectId.value;
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    final second = document.selectedObjectId.value;
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);

    expect({first, second}, {'a', 'b'});
    expect(document.selectedObjectId.value, first);
  });

  testWidgets('Enter opens the selected object\'s menu', (tester) async {
    await _pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.text('Bring to front'), findsOneWidget);
  });

  testWidgets('arrow keys pan the board', (tester) async {
    await _pump(tester);
    final document = surfaceDocument(tester);
    final before = document.camera.x;

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    expect(document.camera.x, greaterThan(before));
  });

  testWidgets('with the note tool armed, Enter opens the note sheet', (
    tester,
  ) async {
    await _pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.text('Add a note'), findsWidgets);
  });
}
