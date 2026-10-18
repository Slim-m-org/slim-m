// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Ctrl+Z takes back a placed shape, note or pasted image, not only a stroke.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'features/canvas/canvas_pane_harness.dart';

void main() {
  testWidgets('Ctrl+Z removes a shape that was just placed', (tester) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Shape'));
    await tester.pump();
    final gesture = await tester.startGesture(
      screenFor(tester, const Offset(50, 50)),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    final placedId = fixture.posted.single['id'] as String;
    expect(surfaceDocument(tester).isAlive(placedId), isTrue);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(fixture.postedOps, hasLength(1));
    expect(fixture.postedOps.single['kind'], 'remove');
    expect(fixture.postedOps.single['object_ids'], [placedId]);
    expect(surfaceDocument(tester).isAlive(placedId), isFalse);
  });
}
