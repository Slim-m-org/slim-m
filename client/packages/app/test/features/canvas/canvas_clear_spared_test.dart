// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A clear spares locked objects: the frame and the feed name them, and a
/// frame that could not name them all sends the client back to read.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_live_event_dispatch.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_media_slot_sync.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_object_locks.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_sync.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_live_dispatch_support.dart';

CanvasStrokeInput _stroke(String id) => CanvasStrokeInput(
  id: id,
  seq: 1,
  zIndex: 1,
  x: 0,
  y: 0,
  w: 10,
  h: 10,
  points: const [0, 0, 10, 10],
  width: 3,
  colorKey: 'annotation',
);

void _dispatch(
  api.ServerEvent event,
  CanvasDocument document,
  CanvasSync sync, {
  void Function()? onForget,
}) => dispatchCanvasLiveEvent(
  event,
  paneChannelId: 'c1',
  sync: sync,
  document: document,
  relay: () => throw StateError('unused'),
  strokePreviewRelay: () => throw StateError('unused'),
  objectPreviewRelay: () => quietPreviewRelay(document),
  applyPlacedObject: (_) {},
  forgetFetchedRegion: onForget ?? () {},
  mediaSlotSync: CanvasMediaSlotSync(
    channelId: 'c1',
    client: inertCanvasApi(),
    overrides: CanvasPresenceTileOverrides(),
  ),
  objectLocks: CanvasObjectLocks(channelId: 'c1', client: inertCanvasApi()),
);

void main() {
  test('a clear frame leaves the objects it names as spared standing', () {
    final document = CanvasDocument()
      ..setViewport(const Size(200, 200))
      ..applyPlaced(_stroke('free'))
      ..applyPlaced(_stroke('locked'));

    _dispatch(
      const api.CanvasCleared(
        channelId: 'c1',
        seq: 1,
        opId: 'op',
        beforeSeq: 1,
        sparedIds: ['locked'],
        sparedCount: 1,
      ),
      document,
      inertCanvasSync(document),
    );

    expect(document.isAlive('free'), isFalse);
    expect(document.isAlive('locked'), isTrue);
  });

  test(
    'a frame that names fewer spared objects than it spared reads again',
    () {
      final document = CanvasDocument()..setViewport(const Size(200, 200));
      var fetches = 0;
      var forgets = 0;
      final sync = CanvasSync(
        channelId: 'c1',
        client: inertCanvasApi(),
        document: document,
        coldFetch: () async => fetches++,
        forgetFetchedRegion: () {},
      )..seedFromViewport(0);

      _dispatch(
        const api.CanvasCleared(
          channelId: 'c1',
          seq: 1,
          opId: 'op',
          beforeSeq: 1,
          sparedIds: ['a'],
          sparedCount: 70,
        ),
        document,
        sync,
        onForget: () => forgets++,
      );

      expect(fetches, 1);
      expect(forgets, 1);
    },
  );

  test('a clear with every spared id named does not read again', () {
    final document = CanvasDocument();
    var fetches = 0;
    final sync = CanvasSync(
      channelId: 'c1',
      client: inertCanvasApi(),
      document: document,
      coldFetch: () async => fetches++,
      forgetFetchedRegion: () {},
    )..seedFromViewport(0);

    _dispatch(
      const api.CanvasCleared(
        channelId: 'c1',
        seq: 1,
        opId: 'op',
        beforeSeq: 1,
        sparedIds: ['a'],
        sparedCount: 1,
      ),
      document,
      sync,
    );

    expect(fetches, 0);
  });

  test('a document clear can spare ids directly', () {
    final document = CanvasDocument()
      ..applyPlaced(_stroke('a'))
      ..applyPlaced(_stroke('b'));

    document.clearBelow(5, spare: {'a'});

    expect(document.isAlive('a'), isTrue);
    expect(document.isAlive('b'), isFalse);
  });
}
