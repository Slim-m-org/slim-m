// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What live frames, region reads and the catch-up feed do to connections (decision 0137): a remove names only what was erased and the client cascades from its own end index, a clear drops only edges whose held end it cleared, and a region read never drops a live edge a silent hull refresh moved.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/providers/canvas_edge_inputs.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_activity_log.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_live_event_dispatch.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_media_slot_sync.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_object_locks.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_sync.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_live_dispatch_support.dart';

api.CanvasObject _note(String id, double x, int seq) => api.CanvasObject(
  id: id,
  kind: 'note',
  zIndex: seq,
  x: x,
  y: 0,
  w: 100,
  h: 50,
  props: {'text': id},
  authorId: 'alice',
  seq: seq,
  createdAt: 0,
);

api.CanvasObject _edge(
  String id,
  String a,
  String b,
  int seq, {
  Map<String, dynamic>? props,
}) => api.CanvasObject(
  id: id,
  kind: 'edge',
  zIndex: seq,
  x: 0,
  y: 0,
  w: 400,
  h: 50,
  props:
      props ??
      {
        'from': {'object_id': a},
        'to': {'object_id': b},
      },
  authorId: 'alice',
  seq: seq,
  createdAt: 0,
);

void main() {
  late CanvasDocument document;
  late CanvasSync sync;
  late CanvasActivityLog log;

  setUp(() {
    document = CanvasDocument()..setViewport(const Size(800, 600));
    sync = inertCanvasSync(document);
    log = CanvasActivityLog(isBlocked: (_) => false);
    for (final object in [
      _note('a', 0, 1),
      _note('b', 300, 2),
      _note('c', 600, 3),
    ]) {
      document.applyPlaced(canvasStrokeInputFrom(object)!);
    }
    document.edges
      ..applyPlaced(canvasEdgeInputFrom(_edge('ab', 'a', 'b', 4))!)
      ..applyPlaced(canvasEdgeInputFrom(_edge('bc', 'b', 'c', 5))!);
  });

  tearDown(() {
    log.dispose();
    document.dispose();
  });

  void dispatch(api.ServerEvent event) => dispatchCanvasLiveEvent(
    event,
    paneChannelId: 'c1',
    sync: sync,
    document: document,
    relay: () => throw StateError('unused'),
    strokePreviewRelay: () => throw StateError('unused'),
    objectPreviewRelay: () => quietPreviewRelay(document),
    applyPlacedObject: (object) => applyWireEdge(document, object),
    forgetFetchedRegion: () {},
    activityLog: log,
    mediaSlotSync: CanvasMediaSlotSync(
      channelId: 'c1',
      client: inertCanvasApi(),
      overrides: CanvasPresenceTileOverrides(),
    ),
    objectLocks: CanvasObjectLocks(channelId: 'c1', client: inertCanvasApi()),
  );

  test(
    'a remove that names only a note takes its edges from the end index',
    () {
      dispatch(
        const api.CanvasObjectsRemoved(
          channelId: 'c1',
          seq: 1,
          opId: 'op',
          objectIds: ['a'],
        ),
      );
      expect(document.edges.isAlive('ab'), isFalse);
      expect(document.edges.isAlive('bc'), isTrue);
      expect(document.edges.wasRemoved('ab'), isTrue);
    },
  );

  test('a restore frame naming the revived edge lets it come back', () {
    dispatch(
      const api.CanvasObjectsRemoved(
        channelId: 'c1',
        seq: 1,
        opId: 'op',
        objectIds: ['a'],
      ),
    );
    dispatch(
      const api.CanvasObjectsRestored(
        channelId: 'c1',
        seq: 2,
        opId: 'op2',
        objectIds: ['a', 'ab'],
      ),
    );
    expect(document.edges.wasRemoved('ab'), isFalse);
  });

  test(
    'a scoped clear of notes drops the edges that lost a held end and no others',
    () {
      document.edges.applyPlaced(
        canvasEdgeInputFrom(
          _edge(
            'free',
            'z',
            'y',
            9,
            props: {
              'from': {'object_id': 'unheld'},
              'to': {'x': 5.0, 'y': 5.0},
            },
          ),
        )!,
      );
      dispatch(
        const api.CanvasCleared(
          channelId: 'c1',
          seq: 1,
          opId: 'op',
          beforeSeq: 1,
          scope: api.CanvasClearScope(kinds: ['note']),
        ),
      );
      expect(document.isAlive('a'), isFalse);
      expect(document.edges.isAlive('ab'), isFalse);
      expect(document.edges.isAlive('bc'), isTrue);
      expect(
        document.edges.isAlive('free'),
        isTrue,
        reason:
            'its end is not held, so a clear is not guessed to have taken it',
      );
    },
  );

  test('a scoped clear of connections drops them and leaves the notes', () {
    dispatch(
      const api.CanvasCleared(
        channelId: 'c1',
        seq: 1,
        opId: 'op',
        beforeSeq: 10,
        scope: api.CanvasClearScope(kinds: ['edge']),
      ),
    );
    expect(document.edges.liveCount, 0);
    expect(document.isAlive('a'), isTrue);
  });

  test(
    'an edit frame merges onto the held connection and a stray text prop is ignored',
    () {
      dispatch(
        const api.CanvasObjectEdited(
          channelId: 'c1',
          seq: 1,
          opId: 'op',
          objectId: 'ab',
          props: {'label': 'needs', 'arrow': 'both'},
        ),
      );
      final spec = document.edges.liveEdge('ab')!.spec;
      expect((spec.label, spec.arrow), ('needs', EdgeArrow.both));
      dispatch(
        const api.CanvasObjectEdited(
          channelId: 'c1',
          seq: 2,
          opId: 'op2',
          objectId: 'ab',
          props: {'label': null},
        ),
      );
      expect(document.edges.liveEdge('ab')!.spec.label, isNull);
    },
  );

  test('a reorder frame restacks the connection among connections', () {
    dispatch(
      const api.CanvasObjectReordered(
        channelId: 'c1',
        seq: 1,
        opId: 'op',
        objectId: 'ab',
        zIndex: 99,
      ),
    );
    expect(document.edges.inPaintOrder.last.id, 'ab');
  });

  test('the activity log names a placed connection', () {
    log.recordPlacedLive(_edge('x', 'a', 'b', 6));
    final sentences = [
      for (final e in log.entries) describeCanvasActivityEntry(e),
    ];
    expect(sentences.single, 'Someone placed a connection.');
  });

  CanvasSync caughtUp() => inertCanvasSync(document, seededAt: 5);

  test('a complete region read that omits a held connection drops it', () {
    final page = api.CanvasViewport(
      objects: [_note('a', 0, 1), _note('b', 300, 2), _note('c', 600, 3)],
      hasMore: false,
      latestSeq: 5,
    );
    caughtUp().applyViewport(page, const Rect.fromLTWH(0, 0, 800, 600));
    expect(document.edges.isAlive('ab'), isFalse);
  });

  test(
    'a region read reports the hull of the held ends, not the stored one',
    () {
      document.moveObject('b', 300, 500, 100, 50);
      final box = document.liveObjects().firstWhere((o) => o.id == 'ab').box;
      expect(box, const Rect.fromLTWH(0, 0, 400, 550));
    },
  );

  test(
    'a viewport page places an edge through the same reducer as any object',
    () {
      final page = api.CanvasViewport(
        objects: [
          _note('a', 0, 1),
          _note('b', 300, 2),
          _edge('new', 'a', 'b', 4),
        ],
        hasMore: false,
        latestSeq: 5,
      );
      caughtUp().applyViewport(page, const Rect.fromLTWH(0, 0, 800, 600));
      expect(document.edges.isAlive('new'), isTrue);
    },
  );
}
