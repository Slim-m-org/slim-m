// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A live frame landing before the first viewport read must not move the
/// cursor, or the ops between the snapshot and that frame are never replayed.
library;

import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/canvas/screens/canvas_sync.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_sync_test.dart' show fakeCanvasOpsApi, stroke;

http.Response _page(List<Object> ops, int latest) => http.Response(
  jsonEncode({
    'ops': ops,
    'latest_seq': latest,
    'has_more': false,
    'reset': false,
  }),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  test('a live frame before the seed does not hide the ops before it', () {
    fakeAsync((async) {
      final document = CanvasDocument()..applyPlaced(stroke('a'));
      final asked = <int>[];
      final sync = CanvasSync(
        channelId: 'c1',
        client: fakeCanvasOpsApi((afterSeq) {
          asked.add(afterSeq);
          if (afterSeq == 5) {
            return _page([
              {
                'seq': 6,
                'id': 'op-6',
                'actor_id': 'me',
                'created_at': 0,
                'kind': 'remove',
                'object_ids': ['a'],
              },
            ], 7);
          }
          return _page(<Object>[], 7);
        }),
        document: document,
        coldFetch: () async {},
        forgetFetchedRegion: () {},
      );

      // Seq 7 arrives live while the cursor is still null.
      sync.applyLive(7, () => document.applyPlaced(stroke('b', seq: 7)));
      // Then the older snapshot page (as of seq 5) lands, and catch-up runs.
      sync.seedFromViewport(5);
      sync.catchUp();
      async.flushMicrotasks();

      expect(
        asked,
        contains(5),
        reason: 'catch-up must replay from the snapshot seq, not the frame',
      );
      expect(
        document.applyPlaced(stroke('a')),
        isNull,
        reason: 'the remove at seq 6 must have been replayed',
      );
    });
  });
}
