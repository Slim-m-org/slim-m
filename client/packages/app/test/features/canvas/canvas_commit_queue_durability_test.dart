// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Queued ink survives disconnects and deploys, and a bad reply never wedges
/// the queue behind it.
library;

import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_commit_queue.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

http.Response _ok(String id) => _json({
  'id': id,
  'kind': 'stroke',
  'x': 0.0,
  'y': 0.0,
  'w': 10.0,
  'h': 10.0,
  'props': <String, dynamic>{},
  'z_index': 1,
  'author_id': 'me',
  'seq': 1,
  'created_at': 0,
});

CanvasCommit _commit(String id) => CanvasCommit(
  id: id,
  x: 0,
  y: 0,
  w: 10,
  h: 10,
  props: const {
    'points': [0.0, 0.0, 10.0, 10.0],
  },
);

class _Rig {
  _Rig(http.Response Function(http.Request request, int attempt) reply) {
    final client = testApi(
      (request) async {
        sent.add(request);
        return reply(request, sent.length);
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
    queue = CanvasCommitQueue(
      client: client,
      channelId: 'c1',
      onPlaced: (object) => placed.add(object.id),
      onFailed: (id, message) => failed.add(id),
      onRemoved: (_) {},
      onEraseOnConfirm: (_) {},
      timedOutUntil: () => null,
    );
  }

  late final CanvasCommitQueue queue;
  final List<http.Request> sent = [];
  final List<String> placed = [];
  final List<String> failed = [];

  String idOf(http.Request r) => _idOf(r);
}

void main() {
  test('a 502 and a 504 from the proxy are retried with the same id', () {
    fakeAsync((async) {
      final rig = _Rig(
        (request, n) => n <= 2
            ? _json({'error': 'bad gateway'}, n == 1 ? 502 : 504)
            : _ok('a'),
      );
      rig.queue.add(_commit('a'));
      async.elapse(const Duration(seconds: 20));

      expect(rig.placed, ['a']);
      expect(rig.failed, isEmpty);
      expect(rig.sent.map(rig.idOf).toSet(), {'a'});
    });
  });

  test('a long outage keeps retrying and lands the stroke afterwards', () {
    fakeAsync((async) {
      final rig = _Rig(
        (request, n) => n < 12 ? _json({'error': 'down'}, 503) : _ok('a'),
      );
      rig.queue.add(_commit('a'));
      async.elapse(const Duration(minutes: 2));

      expect(rig.placed, ['a']);
      expect(rig.failed, isEmpty);
    });
  });

  test('a refusal that no retry can change fails at once', () {
    fakeAsync((async) {
      final rig = _Rig((request, n) => _json({'error': 'no'}, 403));
      rig.queue.add(_commit('a'));
      async.elapse(const Duration(seconds: 1));

      expect(rig.failed, ['a']);
      expect(rig.sent, hasLength(1));
    });
  });

  test('a throttle waits as long as the server asked', () {
    fakeAsync((async) {
      final rig = _Rig(
        (request, n) => n == 1
            ? http.Response(
                '{}',
                429,
                headers: {
                  'retry-after': '6',
                  'content-type': 'application/json',
                },
              )
            : _ok('a'),
      );
      rig.queue.add(_commit('a'));
      async.elapse(const Duration(seconds: 5));
      expect(rig.sent, hasLength(1), reason: 'the server said wait 6 s');

      async.elapse(const Duration(seconds: 2));
      expect(rig.placed, ['a']);
    });
  });

  test('an unreadable reply does not wedge the strokes behind it', () {
    fakeAsync((async) {
      final rig = _Rig(
        (request, n) =>
            _isA(request) ? http.Response('not json', 201) : _ok('b'),
      );
      rig.queue
        ..add(_commit('a'))
        ..add(_commit('b'));
      async.elapse(const Duration(seconds: 30));

      expect(rig.placed, ['b']);
      expect(rig.failed, isEmpty, reason: 'a keeps retrying behind b');
    });
  });

  test('closing keeps sending what is queued, without reporting', () {
    fakeAsync((async) {
      final rig = _Rig((request, n) => _ok(_idOf(request)));
      rig.queue
        ..add(_commit('a'))
        ..add(_commit('b'))
        ..add(_commit('c'))
        ..close();
      async.elapse(const Duration(seconds: 10));

      expect(rig.sent.map(rig.idOf), ['a', 'b', 'c']);
      expect(rig.placed, isEmpty);
    });
  });

  test('a closed queue stops retrying after its grace period', () {
    fakeAsync((async) {
      final rig = _Rig((request, n) => _json({'error': 'down'}, 503));
      rig.queue
        ..add(_commit('a'))
        ..close();
      async.elapse(const Duration(minutes: 5));
      final settled = rig.sent.length;
      async.elapse(const Duration(minutes: 5));

      expect(rig.sent, hasLength(settled));
      expect(async.pendingTimers, isEmpty);
    });
  });
}

bool _isA(http.Request r) =>
    (jsonDecode(r.body) as Map<String, dynamic>)['id'] == 'a';

String _idOf(http.Request r) =>
    (jsonDecode(r.body) as Map<String, dynamic>)['id'] as String;
