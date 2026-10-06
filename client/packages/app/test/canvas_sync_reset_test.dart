// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two ways a bad answer from the ops feed must not become a document
/// wipe - a rate limit, retried with backoff - and the two ways it correctly
/// must - an unknown op kind, or the server's own `reset` - each rate-limited
/// so a stream of either cannot turn a stale client into a refetch loop.
/// A sibling file, `canvas_sync_test.dart`, covers the cursor rules and the
/// live-frame gap detector.
library;

import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/screens/canvas/canvas_sync.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

Map<String, dynamic> _rawOp(int seq, String kind) => {
  'seq': seq,
  'id': 'op-$seq',
  'actor_id': 'me',
  'created_at': 0,
  'kind': kind,
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

api.SlimmApi _fakeApi(http.Response Function(int afterSeq) onOpsRequest) =>
    api.SlimmApi(
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

void main() {
  test('an unknown op kind resets, at most once per five seconds', () {
    fakeAsync((async) {
      final document = CanvasDocument()..applyPlaced(_stroke('a'));
      var coldFetches = 0;
      final sync = CanvasSync(
        channelId: 'c1',
        client: _fakeApi(
          (afterSeq) => _json({
            'ops': [_rawOp(afterSeq + 1, 'teleport')],
            'latest_seq': afterSeq + 1,
            'has_more': false,
            'reset': false,
          }),
        ),
        document: document,
        coldFetch: () async {
          coldFetches++;
        },
        forgetFetchedRegion: () {},
      );
      sync.seedFromViewport(0);

      sync.catchUp();
      async.flushMicrotasks();
      expect(coldFetches, 1);
      expect(
        document.knows('a'),
        isFalse,
        reason: 'a hard reset empties the document',
      );

      // A second trigger arrives immediately - inside the five-second floor.
      sync.catchUp();
      async.flushMicrotasks();
      expect(coldFetches, 1);

      async.elapse(const Duration(seconds: 6));
      sync.catchUp();
      async.flushMicrotasks();
      expect(coldFetches, 2);
    });
  });

  test(
    'the server-reported reset also resets, past its own five-second floor',
    () {
      fakeAsync((async) {
        final document = CanvasDocument();
        var coldFetches = 0;
        final sync = CanvasSync(
          channelId: 'c1',
          client: _fakeApi(
            (afterSeq) => _json({
              'ops': <Object>[],
              'latest_seq': 0,
              'has_more': false,
              'reset': true,
            }),
          ),
          document: document,
          coldFetch: () async {
            coldFetches++;
          },
          forgetFetchedRegion: () {},
        );
        sync.seedFromViewport(500);

        sync.catchUp();
        async.flushMicrotasks();
        expect(coldFetches, 1);
        expect(sync.asOfSeq, isNull);
      });
    },
  );

  test('a 429 during catch-up retries with backoff and does not reset', () {
    fakeAsync((async) {
      final document = CanvasDocument();
      var attempts = 0;
      var coldFetches = 0;
      final sync = CanvasSync(
        channelId: 'c1',
        client: _fakeApi((afterSeq) {
          attempts++;
          if (attempts < 3) {
            return _json({'error': 'slow down'}, 429);
          }
          return _json({
            'ops': <Object>[],
            'latest_seq': afterSeq,
            'has_more': false,
            'reset': false,
          });
        }),
        document: document,
        coldFetch: () async {
          coldFetches++;
        },
        forgetFetchedRegion: () {},
      );
      sync.seedFromViewport(0);

      sync.catchUp();
      async.elapse(const Duration(seconds: 2));

      expect(attempts, 3);
      expect(
        coldFetches,
        0,
        reason: 'a rate limit must never be treated as a reset',
      );
    });
  });

  test('exhausting every retry abandons the attempt rather than resetting', () {
    fakeAsync((async) {
      final document = CanvasDocument();
      var coldFetches = 0;
      final sync = CanvasSync(
        channelId: 'c1',
        client: _fakeApi((afterSeq) => _json({'error': 'slow down'}, 429)),
        document: document,
        coldFetch: () async {
          coldFetches++;
        },
        forgetFetchedRegion: () {},
      );
      sync.seedFromViewport(0);

      sync.catchUp();
      async.elapse(const Duration(seconds: 5));

      expect(coldFetches, 0);
    });
  });

  test(
    'a hard reset clears the document, the cursor, and the fetched region',
    () {
      fakeAsync((async) {
        final document = CanvasDocument()..applyPlaced(_stroke('a'));
        var forgotten = 0;
        final sync = CanvasSync(
          channelId: 'c1',
          client: _fakeApi(
            (afterSeq) => _json({
              'ops': [_rawOp(afterSeq + 1, 'teleport')],
              'latest_seq': afterSeq + 1,
              'has_more': false,
              'reset': false,
            }),
          ),
          document: document,
          coldFetch: () async {},
          forgetFetchedRegion: () {
            forgotten++;
          },
        );
        sync.seedFromViewport(0);

        sync.catchUp();
        async.flushMicrotasks();

        expect(document.objectCount.value, 0);
        expect(sync.asOfSeq, isNull);
        expect(forgotten, 1);
      });
    },
  );

  test(
    'more pages than the catch-up ceiling is a reset, after paging forward',
    () {
      fakeAsync((async) {
        final document = CanvasDocument();
        final asked = <int>[];
        var coldFetches = 0;
        final sync = CanvasSync(
          channelId: 'c1',
          client: _fakeApi((afterSeq) {
            asked.add(afterSeq);
            return _json({
              'ops': [
                {
                  ..._rawOp(afterSeq + 1, 'reorder'),
                  'object_id': 'o',
                  'z_index': 1,
                },
              ],
              'latest_seq': 1000,
              'has_more': true,
              'reset': false,
            });
          }),
          document: document,
          coldFetch: () async {
            coldFetches++;
          },
          forgetFetchedRegion: () {},
        );
        sync.seedFromViewport(0);

        sync.catchUp();
        async.flushMicrotasks();

        expect(asked, [for (var i = 0; i < maxCatchUpPages; i++) i]);
        expect(coldFetches, 1);
      });
    },
  );
}
