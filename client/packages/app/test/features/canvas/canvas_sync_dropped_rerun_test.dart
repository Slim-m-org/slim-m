// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A catch-up requested while one runs is not lost: the last op of a burst
/// still reaches the document.
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

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
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

Map<String, dynamic> _page(List<Object> ops, int latest) => {
  'ops': ops,
  'latest_seq': latest,
  'has_more': false,
  'reset': false,
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

void main() {
  test('a gap frame during a running catch-up still fetches its op', () {
    fakeAsync((async) {
      final document = CanvasDocument()
        ..applyPlaced(_stroke('a'))
        ..applyPlaced(_stroke('b'));
      final first = Completer<http.Response>();
      var requests = 0;
      final api.SlimmApi client = testApi(
        (request) {
          final afterSeq = int.parse(request.url.queryParameters['after_seq']!);
          if (++requests == 1) return first.future;
          return Future.value(
            _json(_page(afterSeq < 9 ? [_removeOp(9, 'b')] : [], 9)),
          );
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
      final sync = CanvasSync(
        channelId: 'c1',
        client: client,
        document: document,
        coldFetch: () async {},
        forgetFetchedRegion: () {},
      )..seedFromViewport(5);

      unawaited(sync.catchUp());
      async.flushMicrotasks();
      // Seq 9 skips 6..8, so this reads as a gap while the first page is in flight.
      sync.applyLive(9, () {});
      first.complete(_json(_page([_removeOp(6, 'a')], 6)));
      async.elapse(const Duration(seconds: 5));

      expect(
        sync.asOfSeq,
        9,
        reason: 'the op behind the gap was never fetched',
      );
      expect(document.applyPlaced(_stroke('b')), isNull);
    });
  });
}
