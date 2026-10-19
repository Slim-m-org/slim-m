// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The catch-up never wedges: a request that hangs, a failed page and an op
/// that throws each leave the next change able to reach the document.
library;

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_sync.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _removeOp(int seq, String id) => {
  'seq': seq,
  'id': 'op-$seq',
  'actor_id': 'me',
  'created_at': 0,
  'kind': 'remove',
  'object_ids': [id],
};

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

CanvasSync _sync(
  CanvasDocument document,
  Future<http.Response> Function(int requestNumber, int afterSeq) answer,
) {
  var requests = 0;
  final api.SlimmApi client = testApi(
    (request) {
      final afterSeq = int.parse(request.url.queryParameters['after_seq']!);
      return answer(++requests, afterSeq);
    },
    session: api.SessionStore(
      tokens: const api.TokenPair(
        userId: 'me',
        accessToken: 'access',
        refreshToken: 'refresh',
        accessExpiresAt: 0,
      ),
    ),
  );
  return CanvasSync(
    channelId: 'c1',
    client: client,
    document: document,
    coldFetch: () async {},
    forgetFetchedRegion: () {},
  );
}

Future<http.Response> _page(int afterSeq, List<Object> ops, int latest) async =>
    _json({
      'ops': ops,
      'latest_seq': latest,
      'has_more': false,
      'reset': false,
    });

void main() {
  test(
    'a catch-up request that never answers times out and frees the slot',
    () {
      fakeAsync((async) {
        final document = CanvasDocument()..applyPlaced(_stroke('a'));
        final sync = _sync(document, (n, afterSeq) {
          if (n == 1) return Completer<http.Response>().future;
          return _page(afterSeq, [_removeOp(8, 'a')], 8);
        });
        sync.seedFromViewport(5);

        unawaited(sync.catchUp());
        async.elapse(catchUpDeadline + const Duration(seconds: 1));
        sync.applyLive(9, () {});
        async.elapse(const Duration(seconds: 5));

        expect(document.applyPlaced(_stroke('a')), isNull);
        expect(sync.asOfSeq, 8);
      });
    },
  );

  test('a failed catch-up page retries by itself', () {
    fakeAsync((async) {
      final document = CanvasDocument()..applyPlaced(_stroke('a'));
      final sync = _sync(document, (n, afterSeq) async {
        if (n == 1) return _json({'error': 'down'}, 503);
        return _page(afterSeq, [_removeOp(6, 'a')], 6);
      });
      sync.seedFromViewport(5);

      unawaited(sync.catchUp());
      async.elapse(const Duration(seconds: 3));

      expect(document.applyPlaced(_stroke('a')), isNull);
      expect(sync.asOfSeq, 6);
    });
  });

  test('a live change that throws does not wedge the cursor', () {
    fakeAsync((async) {
      final document = CanvasDocument()..applyPlaced(_stroke('a'));
      final sync = _sync(
        document,
        (n, afterSeq) => _page(afterSeq, [_removeOp(6, 'a')], 6),
      );
      sync.seedFromViewport(5);

      sync.applyLive(6, () => throw StateError('bad object'));
      async.elapse(const Duration(seconds: 1));

      expect(document.applyPlaced(_stroke('a')), isNull);
      expect(sync.asOfSeq, 6);
    });
  });
}
