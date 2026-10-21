// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A slow catch-up page must not replay ops the live feed already applied.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_sync.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

Map<String, dynamic> _moveOp(int seq, String id, double x) => {
  'seq': seq,
  'id': 'op-$seq',
  'actor_id': 'me',
  'created_at': 0,
  'kind': 'move',
  'object_id': id,
  'x': x,
  'y': 0,
  'w': 10,
  'h': 10,
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
  test(
    'a slow page does not move an object back over newer live moves',
    () async {
      final gate = Completer<http.Response>();
      final client = testApi(
        (request) => gate.future,
        session: api.SessionStore(
          tokens: const api.TokenPair(
            userId: 'me',
            accessToken: 'access',
            refreshToken: 'refresh',
            accessExpiresAt: 0,
          ),
        ),
      );
      final document = CanvasDocument()..applyPlaced(_stroke('a'));
      final sync = CanvasSync(
        channelId: 'c1',
        client: client,
        document: document,
        coldFetch: () async {},
        forgetFetchedRegion: () {},
      )..seedFromViewport(5);

      final catchUp = sync.catchUp();
      sync.applyLive(6, () => document.moveObject('a', 20, 0, 10, 10));
      sync.applyLive(7, () => document.moveObject('a', 50, 0, 10, 10));
      expect(document.objectBounds('a')!.x, 50);

      gate.complete(
        http.Response(
          jsonEncode({
            'ops': [_moveOp(6, 'a', 20)],
            'latest_seq': 6,
            'has_more': false,
            'reset': false,
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      await catchUp;

      expect(sync.asOfSeq, 7);
      expect(document.objectBounds('a')!.x, 50);
    },
  );
}
