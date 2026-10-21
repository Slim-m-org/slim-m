// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// C-075: the object menu's long-press must not fire for a held mouse button.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import 'features/canvas/canvas_pane_harness.dart';

void main() {
  testWidgets('a mouse button held still for 600 ms does not open the menu', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture()
      ..objects = [
        canvasObjectJson('a', seq: 1),
        canvasNoteJson('b', x: 50, seq: 2),
      ];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container, tool: null);
    await tester.pumpAndSettle();

    final point = screenFor(tester, const Offset(60, 20));
    final gesture = await tester.startGesture(
      point,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('Send to back'), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
  });
}
