// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A remote drag preview must not snap an object back after its move was recognised.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_live_event_dispatch.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_media_slot_sync.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_object_locks.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_live_dispatch_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an already-reflected move frame still settles the remote preview', () {
    final document = CanvasDocument()..setViewport(const Size(200, 200));
    addTearDown(document.dispose);
    placeCanvasImage(document);
    final sync = inertCanvasSync(document)..seedFromViewport(5);
    final relay = quietPreviewRelay(document);
    addTearDown(relay.dispose);

    void dispatch(api.ServerEvent event) => dispatchCanvasLiveEvent(
      event,
      paneChannelId: 'c1',
      sync: sync,
      document: document,
      relay: () => throw StateError('unused'),
      strokePreviewRelay: () => throw StateError('unused'),
      objectPreviewRelay: () => relay,
      applyPlacedObject: (_) {},
      forgetFetchedRegion: () {},
      mediaSlotSync: CanvasMediaSlotSync(
        channelId: 'c1',
        client: inertCanvasApi(),
        overrides: CanvasPresenceTileOverrides(),
      ),
      objectLocks: CanvasObjectLocks(channelId: 'c1', client: inertCanvasApi()),
    );

    dispatch(canvasPreviewFrame);
    // Catch-up already applied the committed move at seq 3.
    document.moveObject('a', 10, 10, 1, 1);
    dispatch(
      const api.CanvasObjectMoved(
        channelId: 'c1',
        seq: 3,
        opId: 'op-3',
        objectId: 'a',
        x: 10,
        y: 10,
        w: 1,
        h: 1,
      ),
    );

    relay.previews.expire(DateTime.now().add(const Duration(minutes: 1)));

    expect(document.objectBounds('a'), (x: 10.0, y: 10.0, w: 1.0, h: 1.0));
  });
}
