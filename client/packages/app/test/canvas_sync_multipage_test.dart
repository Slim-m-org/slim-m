// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A catch-up that needs more than one page of the ops feed must ask for the
/// next page after the last op it applied, not for the first page again.
///
/// The fake feed follows `GET /channels/{id}/canvas/ops`: ops strictly after
/// `after_seq`, at most 100 per page, and `latest_seq` the channel head on
/// every page (`crates/slimm-server/src/store/canvas_ops.rs`).
library;

import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/screens/canvas/canvas_sync.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

const _pageLimit = 100;

Map<String, dynamic> _reorder(int seq) => {
  'seq': seq,
  'id': 'op-$seq',
  'actor_id': 'me',
  'created_at': 0,
  'kind': 'reorder',
  'object_id': 'o',
  'z_index': seq,
};

class _Feed {
  _Feed(this.head, {this.failAfter, this.stalls = false});
  final int head;
  final int? failAfter;
  final bool stalls;
  final afterSeqs = <int>[];
  var coldFetches = 0;

  late final client = api.SlimmApi(
    baseUrl: Uri.parse('http://localhost:8080'),
    session: api.SessionStore(
      tokens: const api.TokenPair(
        userId: 'me',
        accessToken: 'a',
        refreshToken: 'r',
        accessExpiresAt: 0,
      ),
    ),
    httpClient: MockClient((request) async {
      final after = int.parse(request.url.queryParameters['after_seq']!);
      afterSeqs.add(after);
      if (after == failAfter) return http.Response('{}', 500);
      if (stalls) {
        return http.Response(
          jsonEncode({
            'ops': <Object>[],
            'latest_seq': head,
            'has_more': true,
            'reset': false,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      final last = (after + _pageLimit).clamp(0, head);
      return http.Response(
        jsonEncode({
          'ops': [for (var s = after + 1; s <= last; s++) _reorder(s)],
          'latest_seq': head,
          'has_more': last < head,
          'reset': false,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  );

  CanvasSync sync() => CanvasSync(
    channelId: 'c1',
    client: client,
    document: CanvasDocument(),
    coldFetch: () async => coldFetches++,
    forgetFetchedRegion: () {},
  );
}

void main() {
  test('150 ops behind: the second request asks after the first page, with no '
      'reset', () {
    fakeAsync((async) {
      final feed = _Feed(150);
      final sync = feed.sync()..seedFromViewport(0);

      sync.catchUp();
      async.flushMicrotasks();

      expect(feed.afterSeqs, [0, 100]);
      expect(feed.coldFetches, 0);
      expect(sync.asOfSeq, 150);
    });
  });

  test('1000 ops behind: ten pages in order, no reset', () {
    fakeAsync((async) {
      final feed = _Feed(1000);
      final sync = feed.sync()..seedFromViewport(0);

      sync.catchUp();
      async.flushMicrotasks();

      expect(feed.afterSeqs, [for (var i = 0; i < 10; i++) i * 100]);
      expect(feed.coldFetches, 0);
      expect(sync.asOfSeq, 1000);
    });
  });

  test('a page that fails part way leaves the cursor where it was', () {
    fakeAsync((async) {
      final feed = _Feed(250, failAfter: 100);
      final sync = feed.sync()..seedFromViewport(0);

      sync.catchUp();
      async.flushMicrotasks();

      expect(feed.afterSeqs, [0, 100]);
      expect(feed.coldFetches, 0);
      expect(sync.asOfSeq, 0);
    });
  });

  test('a page that claims more but carries no ops is a reset, not a loop', () {
    fakeAsync((async) {
      final feed = _Feed(10, stalls: true);
      final sync = feed.sync()..seedFromViewport(0);

      sync.catchUp();
      async.flushMicrotasks();

      expect(feed.afterSeqs, [0]);
      expect(feed.coldFetches, 1);
    });
  });

  test('control: 80 ops behind is one page and lands on the head', () {
    fakeAsync((async) {
      final feed = _Feed(80);
      final sync = feed.sync()..seedFromViewport(0);

      sync.catchUp();
      async.flushMicrotasks();

      expect(feed.afterSeqs, [0]);
      expect(feed.coldFetches, 0);
      expect(sync.asOfSeq, 80);
    });
  });
}
