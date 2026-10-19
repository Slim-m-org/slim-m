// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `dispatchCanvasLiveEvent`'s own activity-log recording: every live kind
/// this client currently handles - place, remove, clear, restore, move,
/// reorder - must reach [CanvasActivityLog] the moment it lands, not only
/// through `CanvasSync`'s own catch-up path. Also covers the one kind that
/// deliberately never reaches the log at all: a media-slot frame, which
/// routes to `CanvasMediaSlotSync` instead - see the tests at the end.
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
import 'package:slimm_test_support/slimm_test_support.dart';

api.CanvasObject _object(String id, {String? authorId = 'alice'}) =>
    api.CanvasObject(
      id: id,
      kind: 'stroke',
      zIndex: 1,
      x: 0,
      y: 0,
      w: 1,
      h: 1,
      props: const {},
      authorId: authorId,
      seq: 1,
      createdAt: 0,
    );

/// A client that never actually answers: every `dispatch` call below lands
/// on the first, adjacent seq, so `CanvasSync.applyLive` never needs to
/// fetch anything - `canvas_sync_test.dart` is the suite that drives a real
/// catch-up fetch.
api.SlimmApi _inertApi() => testApi(
  (_) async => throw StateError('no request expected in this suite'),
  session: api.SessionStore(
    tokens: const api.TokenPair(
      userId: 'me',
      accessToken: 'access',
      refreshToken: 'refresh',
      accessExpiresAt: 0,
    ),
  ),
);

/// A `CanvasSync` whose `applyLive` always runs the callback immediately,
/// since these tests only exercise the dispatch switch itself and its own
/// cursor bookkeeping is `canvas_sync_test.dart`'s job, not this file's.
CanvasSync _sync(CanvasDocument document) => CanvasSync(
  channelId: 'c1',
  client: _inertApi(),
  document: document,
  coldFetch: () async {},
  forgetFetchedRegion: () {},
);

CanvasObjectPreviewRelay _previewRelay(CanvasDocument document) =>
    CanvasObjectPreviewRelay(
      previews: RemoteObjectPreviews(document),
      send: (_, _, _) {},
      isBlocked: (_) => false,
      selfId: () => null,
      isDraggingLocally: (_) => false,
    );

class _RecordingPreviewRelay extends CanvasObjectPreviewRelay {
  _RecordingPreviewRelay(CanvasDocument document)
    : super(
        previews: RemoteObjectPreviews(document),
        send: (_, _, _) {},
        isBlocked: (_) => false,
        selfId: () => null,
        isDraggingLocally: (_) => false,
      );

  final applied = <(String, String, ObjectBox, bool)>[];
  final settled = <String>[];

  @override
  void applyRemote(String userId, String objectId, ObjectBox box, bool ended) =>
      applied.add((userId, objectId, box, ended));

  @override
  void settle(String objectId) => settled.add(objectId);
}

const _preview = api.CanvasObjectPreview(
  channelId: 'c1',
  userId: 'alice',
  objectId: 'a',
  x: 1,
  y: 2,
  w: 3,
  h: 4,
  ended: false,
);

void _placeObject(CanvasDocument document) => document.applyPlaced(
  const CanvasStrokeInput(
    id: 'a',
    seq: 1,
    zIndex: 1,
    x: 0,
    y: 0,
    w: 1,
    h: 1,
    points: [],
    width: 0,
    colorKey: '',
    kind: CanvasObjectKind.image,
  ),
);

void main() {
  late CanvasDocument document;
  late CanvasSync sync;
  late CanvasActivityLog log;

  setUp(() {
    document = CanvasDocument()..setViewport(const Size(200, 200));
    sync = _sync(document);
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
    client: _inertApi(),
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
    objectPreviewRelay: () => previewRelay ?? _previewRelay(document),
    applyPlacedObject: (_) {},
    forgetFetchedRegion: () {},
    activityLog: log,
    strokeDrafts: strokeDrafts,
    mediaSlotSync: mediaSlotSync(),
    objectLocks:
        locks ?? CanvasObjectLocks(channelId: 'c1', client: _inertApi()),
  );

  test('the committed stroke replaces its author finished live draft', () {
    final drafts = strokeDrafts = RemoteStrokeDrafts();
    addTearDown(drafts.dispose);
    drafts.appendOrCreate(
      objectId: 'd1',
      authorId: 'alice',
      points: const [0.0, 0.0],
      colorIndex: 0,
    );
    drafts.finish('d1');

    dispatch(api.CanvasObjectPlaced(channelId: 'c1', object: _object('a')));

    expect(drafts.all, isEmpty);
  });

  test('a live placement records with its own actor', () {
    dispatch(api.CanvasObjectPlaced(channelId: 'c1', object: _object('a')));

    expect(log.entries.single.kind, CanvasActivityKind.placed);
    expect(log.entries.single.actorId, 'alice');
  });

  test('a live removal records with no actor - the frame carries none', () {
    dispatch(
      const api.CanvasObjectsRemoved(
        channelId: 'c1',
        seq: 1,
        opId: 'op-1',
        objectIds: ['a', 'b'],
      ),
    );

    expect(log.entries.single.kind, CanvasActivityKind.removed);
    expect(log.entries.single.actorId, isNull);
    expect(log.entries.single.count, 2);
  });

  test('a live clear records with no actor', () {
    dispatch(
      const api.CanvasCleared(
        channelId: 'c1',
        seq: 1,
        opId: 'op-1',
        beforeSeq: 5,
      ),
    );

    expect(log.entries.single.kind, CanvasActivityKind.cleared);
    expect(log.entries.single.actorId, isNull);
  });

  test('a live restore (non-empty ids) records with no actor', () {
    dispatch(
      const api.CanvasObjectsRestored(
        channelId: 'c1',
        seq: 1,
        opId: 'op-1',
        objectIds: ['a'],
      ),
    );

    expect(log.entries.single.kind, CanvasActivityKind.restored);
    expect(log.entries.single.actorId, isNull);
  });

  test('a live restore cold-fetches, not only forgets the tombstone', () {
    var coldFetches = 0;
    final countingSync = CanvasSync(
      channelId: 'c1',
      client: _inertApi(),
      document: document,
      coldFetch: () async {
        coldFetches++;
      },
      forgetFetchedRegion: () {},
    );

    dispatchCanvasLiveEvent(
      const api.CanvasObjectsRestored(
        channelId: 'c1',
        seq: 1,
        opId: 'op-1',
        objectIds: ['a'],
      ),
      paneChannelId: 'c1',
      sync: countingSync,
      document: document,
      relay: () => throw StateError('no cursor event exercised here'),
      strokePreviewRelay: () =>
          throw StateError('no stroke preview event exercised here'),
      objectPreviewRelay: () => _previewRelay(document),
      applyPlacedObject: (_) {},
      forgetFetchedRegion: () {},
      activityLog: log,
      mediaSlotSync: mediaSlotSync(),
      objectLocks: CanvasObjectLocks(channelId: 'c1', client: _inertApi()),
    );

    expect(
      coldFetches,
      1,
      reason:
          'a restored object\'s payload was freed on removal and the '
          'camera-move guard only checks on an actual pan, so nothing '
          'repaints it on the actor\'s own screen without this',
    );
  });

  test('an empty-id restore defers to the feed and records nothing here - '
      'the feed will record it once it actually applies', () {
    dispatch(
      const api.CanvasObjectsRestored(
        channelId: 'c1',
        seq: 1,
        opId: 'op-1',
        objectIds: [],
      ),
    );

    expect(log.entries, isEmpty);
  });

  test('a live move records with no actor', () {
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
    );

    expect(log.entries.single.kind, CanvasActivityKind.moved);
    expect(log.entries.single.actorId, isNull);
  });

  test('a live reorder records with no actor', () {
    document.applyPlaced(
      const CanvasStrokeInput(
        id: 'a',
        seq: 1,
        zIndex: 1,
        x: 0,
        y: 0,
        w: 1,
        h: 1,
        points: [],
        width: 0,
        colorKey: '',
        kind: CanvasObjectKind.image,
      ),
    );
    dispatch(
      const api.CanvasObjectReordered(
        channelId: 'c1',
        seq: 1,
        opId: 'op-1',
        objectId: 'a',
        zIndex: 5,
      ),
    );

    expect(log.entries.single.kind, CanvasActivityKind.reordered);
    expect(log.entries.single.actorId, isNull);
  });

  test('a live edit replaces the note text and records with no actor', () {
    document.applyPlaced(
      const CanvasStrokeInput(
        id: 'n',
        seq: 1,
        zIndex: 1,
        x: 0,
        y: 0,
        w: 100,
        h: 60,
        points: [],
        width: 0,
        colorKey: 'note',
        kind: CanvasObjectKind.note,
        text: 'before',
      ),
    );
    sync.seedFromViewport(0);
    dispatch(
      const api.CanvasObjectEdited(
        channelId: 'c1',
        seq: 1,
        opId: 'op-1',
        objectId: 'n',
        props: {'text': 'after **bold**'},
      ),
    );

    expect(document.noteTextOf('n'), 'after **bold**');
    expect(log.entries.single.kind, CanvasActivityKind.edited);
    expect(log.entries.single.actorId, isNull);
  });

  test('an edit for a different channel changes nothing', () {
    document.applyPlaced(
      const CanvasStrokeInput(
        id: 'n',
        seq: 1,
        zIndex: 1,
        x: 0,
        y: 0,
        w: 100,
        h: 60,
        points: [],
        width: 0,
        colorKey: 'note',
        kind: CanvasObjectKind.note,
        text: 'before',
      ),
    );
    dispatch(
      const api.CanvasObjectEdited(
        channelId: 'other',
        seq: 1,
        opId: 'op-1',
        objectId: 'n',
        props: {'text': 'after'},
      ),
    );

    expect(document.noteTextOf('n'), 'before');
    expect(log.entries, isEmpty);
  });

  test('an event for a different channel records nothing', () {
    dispatch(api.CanvasObjectPlaced(channelId: 'other', object: _object('a')));

    expect(log.entries, isEmpty);
  });

  test('a live media-slot frame for this pane\'s own channel reaches '
      'mediaSlotSync, never sync.applyLive - it carries no seq', () {
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);
    final slotSync = CanvasMediaSlotSync(
      channelId: 'c1',
      client: _inertApi(),
      overrides: overrides,
    );

    dispatchCanvasLiveEvent(
      const api.CanvasMediaSlotChanged(
        channelId: 'c1',
        kind: 'camera',
        userId: 'alice',
        x: 5,
        y: 6,
        w: 100,
        h: 90,
        locked: true,
        sentToBack: false,
      ),
      paneChannelId: 'c1',
      sync: sync,
      document: document,
      relay: () => throw StateError('no cursor event exercised here'),
      strokePreviewRelay: () =>
          throw StateError('no stroke preview event exercised here'),
      objectPreviewRelay: () => _previewRelay(document),
      applyPlacedObject: (_) =>
          throw StateError('a media slot never places an object'),
      forgetFetchedRegion: () {},
      activityLog: log,
      mediaSlotSync: slotSync,
      objectLocks: CanvasObjectLocks(channelId: 'c1', client: _inertApi()),
    );

    final state = overrides.stateFor('camera:alice');
    expect(state.rect, const Rect.fromLTWH(5, 6, 100, 90));
    expect(state.locked, isTrue);
    expect(log.entries, isEmpty, reason: 'a slot is never an activity');
  });

  test('a live media-slot frame for a different pane never reaches this '
      'pane\'s own mediaSlotSync', () {
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);
    final slotSync = CanvasMediaSlotSync(
      channelId: 'c1',
      client: _inertApi(),
      overrides: overrides,
    );

    dispatchCanvasLiveEvent(
      const api.CanvasMediaSlotChanged(
        channelId: 'other',
        kind: 'camera',
        userId: 'alice',
        x: 5,
        y: 6,
        w: 100,
        h: 90,
        locked: true,
        sentToBack: false,
      ),
      paneChannelId: 'c1',
      sync: sync,
      document: document,
      relay: () => throw StateError('no cursor event exercised here'),
      strokePreviewRelay: () =>
          throw StateError('no stroke preview event exercised here'),
      objectPreviewRelay: () => _previewRelay(document),
      applyPlacedObject: (_) =>
          throw StateError('a media slot never places an object'),
      forgetFetchedRegion: () {},
      activityLog: log,
      mediaSlotSync: slotSync,
      objectLocks: CanvasObjectLocks(channelId: 'c1', client: _inertApi()),
    );

    expect(overrides.stateFor('camera:alice').rect, isNull);
  });

  group('object preview and cursor frames', () {
    test('an object preview for a live, unlocked object reaches the relay', () {
      _placeObject(document);
      final relay = _RecordingPreviewRelay(document);

      dispatch(_preview, previewRelay: relay);

      expect(relay.applied, [
        ('alice', 'a', (x: 1.0, y: 2.0, w: 3.0, h: 4.0), false),
      ]);
    });

    test('an object preview for a locked object is ignored', () {
      _placeObject(document);
      final relay = _RecordingPreviewRelay(document);
      final locks = CanvasObjectLocks(channelId: 'c1', client: _inertApi())
        ..applyRemote(
          const api.CanvasObjectLockChanged(
            channelId: 'c1',
            objectId: 'a',
            locked: true,
          ),
        );

      dispatch(_preview, previewRelay: relay, locks: locks);

      expect(relay.applied, isEmpty);
    });

    test('an object preview for an object not in the document is ignored', () {
      final relay = _RecordingPreviewRelay(document);

      dispatch(_preview, previewRelay: relay);

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
      final relay = _RecordingPreviewRelay(document);

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
