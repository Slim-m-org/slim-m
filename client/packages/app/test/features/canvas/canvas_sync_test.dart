// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas's cursor rules and live-frame handling, driven directly
/// against `CanvasSync` rather than through the widget tree: the two-region
/// race the cursor exists to close, the gap detector, and catch-up ordering.
/// A sibling file, `canvas_sync_reset_test.dart`, covers the two ways a bad
/// response must not become a document wipe.
library;

import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_sync.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

Map<String, dynamic> _object(String id, {int seq = 1}) => {
  'id': id,
  'kind': 'stroke',
  'z_index': seq,
  'x': 0.0,
  'y': 0.0,
  'w': 10.0,
  'h': 10.0,
  'props': {
    'points': [0.0, 0.0, 10.0, 10.0],
  },
  'author_id': 'me',
  'seq': seq,
  'created_at': 0,
};

Map<String, dynamic> _rawOp(
  int seq,
  String kind, {
  Map<String, dynamic> extra = const {},
}) => {
  'seq': seq,
  'id': 'op-$seq',
  'actor_id': 'me',
  'created_at': 0,
  'kind': kind,
  ...extra,
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// A `SlimmApi` whose `/canvas/ops` answers come from [onOpsRequest], with
/// every other path answering an empty list - nothing here exercises the
/// viewport or place routes.
api.SlimmApi fakeCanvasOpsApi(
  http.Response Function(int afterSeq) onOpsRequest,
) => api.SlimmApi(
  baseUrl: Uri.parse('http://localhost:8080'),
  session: api.SessionStore(
    tokens: const api.TokenPair(
      userId: 'me',
      accessToken: 'access',
      refreshToken: 'refresh',
      accessExpiresAt: 0,
    ),
  ),
  httpClient: MockClient((request) async {
    if (!request.url.path.endsWith('/canvas/ops')) return _json(<Object>[]);
    final afterSeq = int.parse(request.url.queryParameters['after_seq']!);
    return onOpsRequest(afterSeq);
  }),
);

CanvasStrokeInput stroke(String id, {int seq = 1}) => CanvasStrokeInput(
  id: id,
  seq: seq,
  zIndex: seq,
  x: 0,
  y: 0,
  w: 10,
  h: 10,
  points: const [0, 0, 10, 10],
  width: 3,
  colorKey: 'annotation',
);

void main() {
  test('a region refetch never advances the cursor past the first fetch', () {
    final document = CanvasDocument();
    final sync = CanvasSync(
      channelId: 'c1',
      client: fakeCanvasOpsApi(
        (afterSeq) => _json({
          'ops': <Object>[],
          'latest_seq': afterSeq,
          'has_more': false,
          'reset': false,
        }),
      ),
      document: document,
      coldFetch: () async {},
      forgetFetchedRegion: () {},
    );

    // Region one's own cold fetch establishes the baseline.
    sync.seedFromViewport(10);
    expect(sync.asOfSeq, 10);

    // Region two's own read reports a higher latest_seq; moving the cursor to it would skip whatever happened between 10 and 60.
    sync.seedFromViewport(60);
    expect(
      sync.asOfSeq,
      10,
      reason: 'a region refetch must never move the cursor on its own',
    );
  });

  test('the following catch-up still reaches a removal outside the refetched '
      'region', () {
    fakeAsync((async) {
      final document = CanvasDocument()..applyPlaced(stroke('a'));
      expect(document.knows('a'), isTrue);

      final sync = CanvasSync(
        channelId: 'c1',
        client: fakeCanvasOpsApi((afterSeq) {
          if (afterSeq == 10) {
            return _json({
              'ops': [
                _rawOp(
                  11,
                  'remove',
                  extra: {
                    'object_ids': ['a'],
                  },
                ),
              ],
              'latest_seq': 60,
              'has_more': false,
              'reset': false,
            });
          }
          return _json({
            'ops': <Object>[],
            'latest_seq': afterSeq,
            'has_more': false,
            'reset': false,
          });
        }),
        document: document,
        coldFetch: () async {},
        forgetFetchedRegion: () {},
      );

      sync.seedFromViewport(10);
      // Region two's own fetch does not move the cursor (asserted above); this catch-up runs from the cursor still at 10.
      sync.seedFromViewport(60);
      sync.catchUp();
      async.flushMicrotasks();

      // `knows` cannot see this: a removal only tombstones the id, so a refused replay is what proves it ran.
      expect(document.applyPlaced(stroke('a')), isNull);
      expect(sync.asOfSeq, 60);
    });
  });

  test('a live frame exactly one past the cursor applies and advances', () {
    final document = CanvasDocument();
    final sync = CanvasSync(
      channelId: 'c1',
      client: fakeCanvasOpsApi(
        (afterSeq) => _json({
          'ops': <Object>[],
          'latest_seq': afterSeq,
          'has_more': false,
          'reset': false,
        }),
      ),
      document: document,
      coldFetch: () async {},
      forgetFetchedRegion: () {},
    );
    sync.seedFromViewport(5);

    var applied = false;
    sync.applyLive(6, () => applied = true);

    expect(applied, isTrue);
    expect(sync.asOfSeq, 6);
  });

  test('a live frame at or below the cursor is ignored', () {
    final document = CanvasDocument();
    final sync = CanvasSync(
      channelId: 'c1',
      client: fakeCanvasOpsApi(
        (afterSeq) => _json({
          'ops': <Object>[],
          'latest_seq': afterSeq,
          'has_more': false,
          'reset': false,
        }),
      ),
      document: document,
      coldFetch: () async {},
      forgetFetchedRegion: () {},
    );
    sync.seedFromViewport(5);

    var applied = false;
    sync.applyLive(5, () => applied = true);

    expect(applied, isFalse);
    expect(sync.asOfSeq, 5);
  });

  test('a live frame ahead of the cursor triggers exactly one catch-up', () {
    fakeAsync((async) {
      final document = CanvasDocument();
      var opsGets = 0;
      final sync = CanvasSync(
        channelId: 'c1',
        client: fakeCanvasOpsApi((afterSeq) {
          opsGets++;
          return _json({
            'ops': <Object>[],
            'latest_seq': afterSeq,
            'has_more': false,
            'reset': false,
          });
        }),
        document: document,
        coldFetch: () async {},
        forgetFetchedRegion: () {},
      );
      sync.seedFromViewport(5);
      async.flushMicrotasks();
      final baseline = opsGets;

      var applied = false;
      sync.applyLive(9, () => applied = true);
      async.flushMicrotasks();

      expect(
        applied,
        isFalse,
        reason: 'the gap is closed by the catch-up page, not the frame itself',
      );
      expect(opsGets, baseline + 1);
    });
  });

  test('an unenumerable restore defers to the feed without moving the cursor '
      'past the one op that could clear those tombstones', () {
    fakeAsync((async) {
      final document = CanvasDocument();
      var opsGets = 0;
      final sync = CanvasSync(
        channelId: 'c1',
        client: fakeCanvasOpsApi((afterSeq) {
          opsGets++;
          return _json({
            'ops': <Object>[],
            'latest_seq': afterSeq,
            'has_more': false,
            'reset': false,
          });
        }),
        document: document,
        coldFetch: () async {},
        forgetFetchedRegion: () {},
      );
      sync.seedFromViewport(5);
      async.flushMicrotasks();
      final baseline = opsGets;

      sync.deferToFeed();
      async.flushMicrotasks();

      expect(opsGets, baseline + 1, reason: 'it must ask the feed');
      expect(
        sync.asOfSeq,
        5,
        reason:
            'the cursor must not advance past the restore: the frame carried '
            'no ids, so nothing cleared the tombstones, and a moved cursor '
            'would mean no later frame or cold fetch ever brings those '
            'objects back',
      );
    });
  });

  test('catch-up applies place, remove, clear and restore in order and is '
      'idempotent when replayed from a stale cursor', () {
    fakeAsync((async) {
      final document = CanvasDocument();
      final ops = [
        _rawOp(1, 'place', extra: {'object': _object('a', seq: 1)}),
        _rawOp(2, 'place', extra: {'object': _object('b', seq: 2)}),
        _rawOp(
          3,
          'remove',
          extra: {
            'object_ids': ['a'],
          },
        ),
        _rawOp(4, 'clear', extra: {'before_seq': 2}),
        _rawOp(
          5,
          'restore',
          extra: {
            'target_op': 'op-3',
            'object_ids': ['a'],
          },
        ),
      ];
      final sync = CanvasSync(
        channelId: 'c1',
        client: fakeCanvasOpsApi(
          (afterSeq) => _json({
            'ops': ops.where((o) => o['seq'] as int > afterSeq).toList(),
            'latest_seq': 5,
            'has_more': false,
            'reset': false,
          }),
        ),
        document: document,
        coldFetch: () async {},
        forgetFetchedRegion: () {},
      );

      sync.seedFromViewport(0);
      sync.catchUp();
      async.flushMicrotasks();

      // 'a' was placed, removed at seq 3, then restored at seq 5: tombstone gone, but restore never re-materializes locally.
      expect(document.applyPlaced(stroke('a')), isNotNull);
      // 'b' was placed at seq 2 and cleared at or below seq 2: still tombstoned, so a replay is refused.
      expect(document.applyPlaced(stroke('b', seq: 2)), isNull);
      expect(sync.asOfSeq, 5);

      // Replaying from a stale cursor (a duplicate reconnect) must not double-apply anything harmfully.
      sync.catchUp();
      async.flushMicrotasks();
      expect(sync.asOfSeq, 5);
    });
  });

  test('a restore read off the catch-up feed cold-fetches, not only forgets '
      'the tombstone', () {
    fakeAsync((async) {
      final document = CanvasDocument();
      var coldFetches = 0;
      var forgets = 0;
      final ops = [
        _rawOp(
          1,
          'restore',
          extra: {
            'target_op': 'op-0',
            'object_ids': ['a'],
          },
        ),
      ];
      final sync = CanvasSync(
        channelId: 'c1',
        client: fakeCanvasOpsApi(
          (afterSeq) => _json({
            'ops': ops.where((o) => o['seq'] as int > afterSeq).toList(),
            'latest_seq': 1,
            'has_more': false,
            'reset': false,
          }),
        ),
        document: document,
        coldFetch: () async {
          coldFetches++;
        },
        forgetFetchedRegion: () {
          forgets++;
        },
      );

      sync.seedFromViewport(0);
      sync.catchUp();
      async.flushMicrotasks();

      expect(
        forgets,
        1,
        reason: 'the tombstone still has to go, same as before this fix',
      );
      expect(
        coldFetches,
        1,
        reason:
            'a restored object\'s payload was freed on removal, so nothing '
            'repaints it without an actual fetch - forgetting the tombstone '
            'alone only helps the *next* camera move, which may never come',
      );
    });
  });

  test('onObjectPlaced fires for a place op read off the catch-up feed, and '
      'only for that kind', () {
    fakeAsync((async) {
      final document = CanvasDocument();
      final placed = <String>[];
      final ops = [
        _rawOp(1, 'place', extra: {'object': _object('a', seq: 1)}),
        _rawOp(
          2,
          'remove',
          extra: {
            'object_ids': ['a'],
          },
        ),
      ];
      final sync = CanvasSync(
        channelId: 'c1',
        client: fakeCanvasOpsApi(
          (afterSeq) => _json({
            'ops': ops.where((o) => o['seq'] as int > afterSeq).toList(),
            'latest_seq': 2,
            'has_more': false,
            'reset': false,
          }),
        ),
        document: document,
        coldFetch: () async {},
        forgetFetchedRegion: () {},
        onObjectPlaced: (object) => placed.add(object.id),
      );

      sync.seedFromViewport(0);
      sync.catchUp();
      async.flushMicrotasks();

      expect(placed, ['a']);
    });
  });
}
