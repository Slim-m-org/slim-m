// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A pan that stays inside the already fetched region refetches nothing, so
/// an image the bitmap cache evicted while it was off screen has to be
/// brought back by the pan itself.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';
import 'support/async_wait.dart';

void main() {
  testWidgets('panning an evicted image into view inside the fetched region '
      'hydrates it again', (tester) async {
    final fixture = CanvasPaneFixture()
      ..objects = [
        canvasImageJson('near', x: 10),
        canvasImageJson('far', x: 900, seq: 2),
      ];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await tester.runAsync(() async {
      await pumpCanvasPane(tester, container);
    });
    final document = surfaceDocument(tester);
    await waitUntil(
      tester,
      () => document.hasImageBitmap('near') && document.hasImageBitmap('far'),
      reason: 'both images hydrate on open',
    );
    final viewportGets = fixture.viewportGets;
    final fetches = fixture.attachmentFetches;

    document.evictImageBitmap('far');
    document.setCamera(const Camera(x: 300));
    await tester.pump(const Duration(milliseconds: 200));
    await waitUntil(
      tester,
      () => document.hasImageBitmap('far'),
      reason: 'the evicted image never came back',
    );

    expect(fixture.viewportGets, viewportGets, reason: 'no region refetch');
    expect(fixture.attachmentFetches, fetches + 1);
  });
}
