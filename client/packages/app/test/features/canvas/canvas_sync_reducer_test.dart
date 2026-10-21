// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sequenced reducer: live frames, catch-up pages and viewport pages all
/// go through one cursor, so none of them can undo what another already did.
library;

import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_sync.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_sync_test.dart' show fakeCanvasOpsApi, stroke;

const _everything = Rect.fromLTRB(-1000, -1000, 1000, 1000);

http.Response _emptyPage(int afterSeq) => http.Response(
  jsonEncode({
    'ops': <Object>[],
    'latest_seq': afterSeq,
    'has_more': false,
    'reset': false,
  }),
  200,
  headers: {'content-type': 'application/json'},
);

CanvasSync _sync(CanvasDocument document, {int? seededAt}) {
  final sync = CanvasSync(
    channelId: 'c1',
    client: fakeCanvasOpsApi(_emptyPage),
    document: document,
    coldFetch: () async {},
    forgetFetchedRegion: () {},
  );
  if (seededAt != null) sync.seedFromViewport(seededAt);
  return sync;
}

api.CanvasObject _wire(String id, {int seq = 1, double x = 0}) =>
    api.CanvasObject(
      id: id,
      authorId: 'a',
      kind: 'stroke',
      zIndex: seq,
      x: x,
      y: 0,
      w: 10,
      h: 10,
      props: const {
        'points': [0, 0, 10, 10],
      },
      seq: seq,
      createdAt: 0,
    );

api.CanvasViewport _page(List<api.CanvasObject> objects, int head) =>
    api.CanvasViewport(objects: objects, hasMore: false, latestSeq: head);

api.CanvasMoveOp _move(int seq, String id, double x) => api.CanvasMoveOp(
  seq: seq,
  id: 'op-$seq',
  actorId: null,
  createdAt: 0,
  objectId: id,
  x: x,
  y: 0,
  w: 10,
  h: 10,
);

void main() {
  test('a frame that skips ahead waits, and applies once the gap closes', () {
    final document = CanvasDocument()..applyPlaced(stroke('a'));
    final sync = _sync(document, seededAt: 1);
    final order = <int>[];

    sync
      ..applyLive(3, () => order.add(3))
      ..applyLive(2, () => order.add(2));

    expect(order, [2, 3], reason: 'in seq order, with no request in between');
    expect(sync.asOfSeq, 3);
  });

  test('a frame at or below the cursor is ignored, even for a new object', () {
    final document = CanvasDocument();
    final sync = _sync(document, seededAt: 5);
    var applied = false;

    sync.applyLive(4, () => applied = true);

    expect(applied, isFalse);
  });

  test('a catch-up with no cursor to start from does nothing', () {
    fakeAsync((async) {
      var requests = 0;
      final sync = CanvasSync(
        channelId: 'c1',
        client: fakeCanvasOpsApi((afterSeq) {
          requests++;
          return _emptyPage(afterSeq);
        }),
        document: CanvasDocument(),
        coldFetch: () async {},
        forgetFetchedRegion: () {},
      );

      sync.catchUp();
      async.flushMicrotasks();

      expect(requests, 0);
    });
  });

  group('a viewport page older than the document', () {
    test('is brought forward from the ops already applied', () {
      final document = CanvasDocument()..applyPlaced(stroke('a'));
      final sync = _sync(document, seededAt: 5)
        ..applyLive(
          6,
          () => document.moveObject('a', 40, 0, 10, 10),
          replay: _move(6, 'a', 40),
        );

      final outcome = sync.applyViewport(
        _page([_wire('a', seq: 1)], 5),
        _everything,
      );

      expect(outcome, CanvasPageOutcome.applied);
      expect(document.objectBounds('a')!.x, 40);
    });

    test('is refused when the log no longer reaches back to it', () {
      final document = CanvasDocument();
      final sync = _sync(document, seededAt: 100);

      final outcome = sync.applyViewport(_page([], 40), _everything);

      expect(outcome, CanvasPageOutcome.stale);
    });

    test('is refused when a restore landed after it', () {
      final document = CanvasDocument();
      final sync = _sync(document, seededAt: 5)
        ..applyLive(
          6,
          () {},
          replay: const api.CanvasRestoreOp(
            seq: 6,
            id: 'op-6',
            actorId: null,
            createdAt: 0,
            targetOp: 'x',
            objectIds: ['a'],
          ),
        );

      expect(
        sync.applyViewport(_page([], 5), _everything),
        CanvasPageOutcome.stale,
      );
    });
  });

  group('a viewport page at the cursor', () {
    test('repairs the box of an object the document had wrong', () {
      final document = CanvasDocument()..applyPlaced(stroke('a'));
      final sync = _sync(document, seededAt: 5);

      sync.applyViewport(_page([_wire('a', x: 70)], 5), _everything);

      expect(document.objectBounds('a')!.x, 70);
    });

    test('drops what it shows inside the region but the page lacks', () {
      final document = CanvasDocument()
        ..applyPlaced(stroke('gone'))
        ..applyPlaced(stroke('kept', seq: 2));
      final sync = _sync(document, seededAt: 5);

      sync.applyViewport(_page([_wire('kept', seq: 2)], 5), _everything);

      expect(document.isAlive('gone'), isFalse);
      expect(document.isAlive('kept'), isTrue);
    });

    test('leaves an object being dragged where the drag put it', () {
      final document = CanvasDocument()..applyPlaced(stroke('a'));
      final sync = CanvasSync(
        channelId: 'c1',
        client: fakeCanvasOpsApi(_emptyPage),
        document: document,
        coldFetch: () async {},
        forgetFetchedRegion: () {},
        isShownOffPlace: (id) => id == 'a',
      )..seedFromViewport(5);

      sync.applyViewport(_page([], 5), _everything);

      expect(document.isAlive('a'), isTrue);
    });
  });

  test('a page of a document still behind keeps what the feed will fix', () {
    final document = CanvasDocument()..applyPlaced(stroke('a'));
    final sync = _sync(document, seededAt: 5);

    sync.applyViewport(_page([], 9), _everything);

    expect(document.isAlive('a'), isTrue, reason: 'ops 6..9 are still to come');
  });

  test('a clear already applied sweeps a placement that was still pending', () {
    final document = CanvasDocument();
    final sync = _sync(document, seededAt: 5)
      ..applyLive(
        6,
        () {},
        replay: const api.CanvasClearOp(
          seq: 6,
          id: 'op-6',
          actorId: null,
          createdAt: 0,
          beforeSeq: 6,
          scope: api.CanvasClearScope.everything,
        ),
      );

    expect(sync.clearedSincePlacement(_wire('late', seq: 4)), isTrue);
    expect(sync.clearedSincePlacement(_wire('after', seq: 7)), isFalse);
  });
}
