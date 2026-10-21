// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Edit shortcuts stay inert while the activity log hides the canvas.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'features/canvas/canvas_pane_harness.dart';

void main() {
  testWidgets('Delete does not remove a note while the activity log is open', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture()
      ..objects = [canvasNoteJson('note', x: 400)];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();
    final gesture = await tester.startGesture(
      screenFor(tester, const Offset(415, 15)),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    final document = surfaceDocument(tester);
    expect(document.selectedObjectId.value, 'note');

    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show activity log'));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.delete);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();

    expect(fixture.postedOps, isEmpty);
  });
}
