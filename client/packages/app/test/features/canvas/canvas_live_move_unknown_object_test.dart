// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// C-042: a live move naming an object this client never fetched must make
/// the client refetch, else an object moved into the fetched region never
/// appears.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_live_event_dispatch.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_cursor_relay.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_media_slot_sync.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_object_locks.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_live_dispatch_support.dart';

void main() {
  test('a move of an unheld object into view forgets the fetched region', () {
    final document = CanvasDocument()..setViewport(const Size(200, 200));
    addTearDown(document.dispose);
    var forgotten = 0;

    dispatchCanvasLiveEvent(
      const api.CanvasObjectMoved(
        channelId: 'c1',
        seq: 1,
        opId: 'op-1',
        objectId: 'never-fetched',
        x: 10,
        y: 10,
        w: 20,
        h: 20,
      ),
      paneChannelId: 'c1',
      sync: inertCanvasSync(document),
      document: document,
      relay: () => throw StateError('unused'),
      strokePreviewRelay: () => throw StateError('unused'),
      objectPreviewRelay: () => quietPreviewRelay(document),
      applyPlacedObject: (_) {},
      forgetFetchedRegion: () => forgotten++,
      mediaSlotSync: CanvasMediaSlotSync(
        channelId: 'c1',
        client: inertCanvasApi(),
        overrides: CanvasPresenceTileOverrides(),
      ),
      objectLocks: CanvasObjectLocks(channelId: 'c1', client: inertCanvasApi()),
    );

    expect(document.isAlive('never-fetched'), isFalse);
    expect(forgotten, greaterThan(0));
  });
}
