// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `dispatchCanvasLiveEvent` routing object previews and cursors to their relays.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_activity_log.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_live_event_dispatch.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_cursor_relay.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_media_slot_sync.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_object_locks.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_object_preview_relay.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_sync.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_live_dispatch_support.dart';

void main() {
  late CanvasDocument document;
  late CanvasSync sync;
  late CanvasActivityLog log;

  setUp(() {
    document = CanvasDocument()..setViewport(const Size(200, 200));
    sync = inertCanvasSync(document);
    log = CanvasActivityLog(isBlocked: (_) => false);
  });

  tearDown(() {
    log.dispose();
    document.dispose();
  });

  // Only for the activity-log cases below; the media-slot cases build their own.
  RemoteStrokeDrafts? strokeDrafts;

  CanvasMediaSlotSync mediaSlotSync() => CanvasMediaSlotSync(
    channelId: 'c1',
    client: inertCanvasApi(),
    overrides: CanvasPresenceTileOverrides(),
  );

  void dispatch(
    api.ServerEvent event, {
    CanvasCursorRelay? cursorRelay,
    CanvasObjectPreviewRelay? previewRelay,
    CanvasObjectLocks? locks,
  }) => dispatchCanvasLiveEvent(
    event,
    paneChannelId: 'c1',
    sync: sync,
    document: document,
    relay: () =>
        cursorRelay ?? (throw StateError('no cursor event exercised here')),
    strokePreviewRelay: () =>
        throw StateError('no stroke preview event exercised here'),
    objectPreviewRelay: () => previewRelay ?? quietPreviewRelay(document),
    applyPlacedObject: (_) {},
    forgetFetchedRegion: () {},
    activityLog: log,
    strokeDrafts: strokeDrafts,
    mediaSlotSync: mediaSlotSync(),
    objectLocks:
        locks ?? CanvasObjectLocks(channelId: 'c1', client: inertCanvasApi()),
  );

  group('object preview and cursor frames', () {
    test('an object preview for a live, unlocked object reaches the relay', () {
      placeCanvasImage(document);
      final relay = RecordingPreviewRelay(document);

      dispatch(canvasPreviewFrame, previewRelay: relay);

      expect(relay.applied, [
        ('alice', 'a', (x: 1.0, y: 2.0, w: 3.0, h: 4.0), false),
      ]);
    });

    test('an object preview for a locked object is ignored', () {
      placeCanvasImage(document);
      final relay = RecordingPreviewRelay(document);
      final locks = CanvasObjectLocks(channelId: 'c1', client: inertCanvasApi())
        ..applyRemote(
          const api.CanvasObjectLockChanged(
            channelId: 'c1',
            objectId: 'a',
            locked: true,
          ),
        );

      dispatch(canvasPreviewFrame, previewRelay: relay, locks: locks);

      expect(relay.applied, isEmpty);
    });

    test('an object preview for an object not in the document is ignored', () {
      final relay = RecordingPreviewRelay(document);

      dispatch(canvasPreviewFrame, previewRelay: relay);

      expect(relay.applied, isEmpty);
    });

    test('a cursor frame with left removes that user cursor', () {
      final cursors = CanvasCursors();
      addTearDown(cursors.dispose);
      final relay = CanvasCursorRelay(
        cursors: cursors,
        paletteSize: 6,
        send: (_, _) {},
        resolveLabel: (_) => 'Alice',
        isBlocked: (_) => false,
        selfId: () => 'me',
      );
      addTearDown(relay.dispose);
      const moved = api.CanvasCursorMoved(
        channelId: 'c1',
        userId: 'alice',
        x: 5,
        y: 6,
      );
      dispatch(moved, cursorRelay: relay);
      expect(cursors.all, hasLength(1));

      dispatch(
        const api.CanvasCursorMoved(
          channelId: 'c1',
          userId: 'alice',
          x: 5,
          y: 6,
          left: true,
        ),
        cursorRelay: relay,
      );

      expect(cursors.all, isEmpty);
    });

    test('a committed move settles the preview of that object', () {
      final relay = RecordingPreviewRelay(document);

      dispatch(
        const api.CanvasObjectMoved(
          channelId: 'c1',
          seq: 1,
          opId: 'op-1',
          objectId: 'a',
          x: 1,
          y: 1,
          w: 1,
          h: 1,
        ),
        previewRelay: relay,
      );

      expect(relay.settled, ['a']);
    });
  });
}
