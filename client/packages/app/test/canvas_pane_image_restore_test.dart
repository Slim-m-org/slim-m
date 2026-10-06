// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Deleting an image and undoing it, or someone else's remove and restore
/// arriving over the socket, brings the picture back: the restored object is
/// a new stroke with no bitmap, and the hydrator has to fetch for it again.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';
import 'support/async_wait.dart';

bool _hasBitmap(WidgetTester tester) {
  final document = surfaceDocument(tester);
  final order = document.paintOrder;
  if (order.length != 1) return false;
  return document.strokeIfAlive(order.single)?.image != null;
}

void main() {
  testWidgets('Delete then Undo of a hydrated image repaints the image', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture()..objects = [canvasImageJson('img')];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await tester.runAsync(() async {
      await pumpCanvasPane(tester, container);
    });
    await waitUntil(tester, () => _hasBitmap(tester), reason: 'first hydrate');
    expect(fixture.attachmentFetches, 1);

    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();
    final tap = await tester.startGesture(
      screenFor(tester, const Offset(15, 15)),
    );
    await tap.up();
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(fixture.postedOps.single['kind'], 'remove');
    expect(surfaceDocument(tester).objectCount.value, 0);
    // The server echoes the author's own ops back as live frames.
    fixture.events.add(
      const api.CanvasObjectsRemoved(
        channelId: 'c1',
        seq: 2,
        opId: 'server-op-1',
        objectIds: ['img'],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Undo'));
    await tester.pumpAndSettle();
    expect(fixture.postedOps.last['kind'], 'restore');
    fixture.events.add(
      const api.CanvasObjectsRestored(
        channelId: 'c1',
        seq: 3,
        opId: 'server-op-2',
        objectIds: ['img'],
      ),
    );

    // The restore's cold fetch re-adds the object; give it and any hydrate real time.
    await waitUntil(
      tester,
      () => surfaceDocument(tester).objectCount.value == 1,
      reason: 'restored object back in the document',
    );
    await waitUntil(
      tester,
      () => _hasBitmap(tester),
      reason: 'the restored image never got its bitmap back',
    );

    expect(surfaceDocument(tester).objectCount.value, 1);
    expect(
      _hasBitmap(tester),
      isTrue,
      reason:
          'the restored image is a fresh stroke with image == null; '
          'attachment fetches so far: ${fixture.attachmentFetches}',
    );
  });

  testWidgets('a remote remove then restore frame repaints the image', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture()
      ..objects = [canvasImageJson('img', authorId: 'someone-else')];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await tester.runAsync(() async {
      await pumpCanvasPane(tester, container);
    });
    await waitUntil(tester, () => _hasBitmap(tester), reason: 'first hydrate');

    fixture.events.add(
      const api.CanvasObjectsRemoved(
        channelId: 'c1',
        seq: 2,
        opId: 'op-2',
        objectIds: ['img'],
      ),
    );
    await tester.pumpAndSettle();
    expect(surfaceDocument(tester).objectCount.value, 0);

    fixture.events.add(
      const api.CanvasObjectsRestored(
        channelId: 'c1',
        seq: 3,
        opId: 'op-3',
        objectIds: ['img'],
      ),
    );
    await waitUntil(
      tester,
      () => surfaceDocument(tester).objectCount.value == 1,
      reason: 'restored object back in the document',
    );
    await waitUntil(
      tester,
      () => _hasBitmap(tester),
      reason: 'the restored image never got its bitmap back',
    );

    expect(
      _hasBitmap(tester),
      isTrue,
      reason: 'fetches: ${fixture.attachmentFetches}',
    );
  });
}
