// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A late placement reply must not yank the tool out from under
/// whatever the person switched to while it was in flight.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'features/canvas/canvas_pane_harness.dart';

void main() {
  testWidgets('a late shape reply leaves a tool picked meanwhile alone', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture()..placeGate = Completer<void>();
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
    await tester.pump();
    expect(fixture.posted, hasLength(1));

    await tester.tap(find.bySemanticsLabel('Pen'));
    await tester.pump();
    expect(
      tester.widget<CanvasSurface>(find.byType(CanvasSurface)).tool,
      CanvasTool.pen,
    );

    fixture.placeGate!.complete();
    await tester.pumpAndSettle();

    expect(
      tester.widget<CanvasSurface>(find.byType(CanvasSurface)).tool,
      CanvasTool.pen,
      reason: 'the reply landed after the person chose Pen',
    );
  });
}
