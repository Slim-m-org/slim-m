// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A viewport read that was answered before a live clear must not bring the
/// cleared ink back when it lands after the clear.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';

import 'features/canvas/canvas_pane_harness.dart';
import 'support/async_wait.dart';

void main() {
  testWidgets('a stale viewport page does not resurrect ink cleared meanwhile', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture()..objects = [canvasObjectJson('a')];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await tester.runAsync(() async {
      await pumpCanvasPane(tester, container);
    });
    await waitUntil(
      tester,
      () => surfaceDocument(tester).objectCount.value == 1,
      reason: 'first page applied',
    );

    final engine = container.read(canvasEngineProvider('c1').notifier);
    await waitUntil(
      tester,
      () => container.read(canvasEngineProvider('c1')).paging == null,
      reason: 'the rest of the board is in',
    );

    // A second region holds ink the document has never seen, so a clear cannot tombstone it.
    fixture.objects = [canvasObjectJson('b', x: 5000)];
    fixture.viewportGate = Completer<void>();
    final readsBefore = fixture.viewportGets;
    final inFlight = engine.fetch();
    await waitUntil(
      tester,
      () => fixture.viewportGets == readsBefore + 1,
      reason: 'fetch sent',
    );

    fixture.events.add(
      const api.CanvasCleared(
        channelId: 'c1',
        seq: 2,
        opId: 'op-clear',
        beforeSeq: 2,
      ),
    );
    await tester.pump();
    expect(surfaceDocument(tester).objectCount.value, 0);

    fixture.viewportGate!.complete();
    await tester.runAsync(() async => inFlight);
    await tester.pump();

    expect(
      surfaceDocument(tester).objectCount.value,
      0,
      reason: 'the page answered before the clear brought cleared ink back',
    );
  });
}
