// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The board needs a keyboard and screen-reader route. Content must
/// reach the semantics tree without a pointer selection, and the zoom keys
/// must move the camera.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'features/canvas/canvas_pane_harness.dart';

void main() {
  testWidgets('an unselected note is readable through the semantics tree', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture()
      ..objects = [canvasNoteJson('note', text: 'standup agenda')];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    final handle = tester.ensureSemantics();
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    expect(surfaceDocument(tester).selectedObjectId.value, isNull);
    expect(find.bySemanticsLabel(RegExp('standup agenda')), findsWidgets);
    handle.dispose();
  });

  testWidgets('the plus key zooms the board in', (tester) async {
    final fixture = CanvasPaneFixture()..objects = [canvasNoteJson('note')];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();
    final document = surfaceDocument(tester);
    final before = document.camera.zoom;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.equal);
    await tester.pumpAndSettle();

    expect(document.camera.zoom, greaterThan(before));
  });
}
