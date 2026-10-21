// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The commit queue: retry, the distinct "removed while sending" failure,
/// and the cancel/arm split undo needs from a placement that has not landed
/// yet.
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

Map<String, dynamic> _objectFor(Map<String, dynamic> body) => {
  ...body,
  'kind': 'stroke',
  'z_index': 1,
  'author_id': 'me',
  'seq': 1,
  'created_at': 0,
};

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

/// A `SlimmApi` whose `POST .../canvas/objects` answers come from
/// [onPlace], called once per request in send order.
api.SlimmApi _fakeApi(http.Response Function() onPlace) => testApi(
  (request) async => onPlace(),
  session: api.SessionStore(
    tokens: const api.TokenPair(
      userId: 'me',
      accessToken: 'access',
      refreshToken: 'refresh',
      accessExpiresAt: 0,
    ),
  ),
);

class _Harness {
  _Harness(this.client, {int? Function()? timedOutUntil}) {
    queue = CanvasCommitQueue(
      client: client,
      channelId: 'c1',
      onPlaced: (object) => placed.add(object),
      onFailed: (id, message) => failed.add((id, message)),
      onRemoved: (id) => removed.add(id),
      onEraseOnConfirm: (id) => armedLanded.add(id),
      timedOutUntil: timedOutUntil ?? () => null,
    );
  }

  final api.SlimmApi client;
  late final CanvasCommitQueue queue;
  final List<api.CanvasObject> placed = [];
  final List<(String, String)> failed = [];
  final List<String> removed = [];
  final List<String> armedLanded = [];
}

void main() {
  test('a successful placement calls onPlaced', () {
    fakeAsync((async) {
      final harness = _Harness(
        _fakeApi(
          () => _json(
            _objectFor({
              'id': 'a',
              'x': 0.0,
              'y': 0.0,
              'w': 10.0,
              'h': 10.0,
              'props': <String, dynamic>{},
            }),
          ),
        ),
      );
      harness.queue.add(_commit('a'));
      async.flushMicrotasks();

      expect(harness.placed.map((o) => o.id), ['a']);
      expect(harness.failed, isEmpty);
    });
  });

  test('a non-retryable failure calls onFailed with an explanation', () {
    fakeAsync((async) {
      final harness = _Harness(_fakeApi(() => _json({'error': 'no'}, 403)));
      harness.queue.add(_commit('a'));
      async.flushMicrotasks();

      expect(harness.failed, [
        ('a', "You don't have permission to draw here right now."),
      ]);
      expect(harness.placed, isEmpty);
    });
  });

  test('a timed-out caller gets the freeze named, not the generic refusal', () {
    fakeAsync((async) {
      // A little past the exact minute so a later real-clock read cannot truncate this down a bucket.
      final until = DateTime.now()
          .add(const Duration(minutes: 5, seconds: 30))
          .millisecondsSinceEpoch;
      final harness = _Harness(
        _fakeApi(() => _json({'error': 'no'}, 403)),
        timedOutUntil: () => until,
      );
      harness.queue.add(_commit('a'));
      async.flushMicrotasks();

      expect(harness.failed, hasLength(1));
      final (id, message) = harness.failed.single;
      expect(id, 'a');
      expect(message, contains("You're timed out"));
      expect(message, contains('5m'));
      expect(
        message,
        isNot(contains("don't have permission")),
        reason:
            'a real timeout deadline names itself, not the generic '
            'permission wording',
      );
    });
  });

  test(
    'a retry finding its own id already removed calls onRemoved, not onFailed',
    () {
      fakeAsync((async) {
        final harness = _Harness(
          _fakeApi(() => _json({'error': 'that object was removed'}, 409)),
        );
        harness.queue.add(_commit('a'));
        async.flushMicrotasks();

        expect(harness.removed, ['a']);
        expect(
          harness.failed,
          isEmpty,
          reason: 'a removed object is not a failed placement',
        );
      });
    },
  );

  test('an ordinary conflict still calls onFailed, not onRemoved', () {
    fakeAsync((async) {
      final harness = _Harness(
        _fakeApi(() => _json({'error': 'canvas object id already used'}, 409)),
      );
      harness.queue.add(_commit('a'));
      async.flushMicrotasks();

      expect(harness.removed, isEmpty);

      /// Matches canvas_quick_placement.dart/canvas_image_paste.dart's own
      /// ConflictException wording, dropping the id-collision detail nobody
      /// typed and cannot act on.
      expect(harness.failed, [('a', 'This canvas is full.')]);
    });
  });

  test('a rate limit retries with backoff and eventually succeeds', () {
    fakeAsync((async) {
      var calls = 0;
      final harness = _Harness(
        _fakeApi(() {
          calls++;
          if (calls < 3) return _json({'error': 'slow down'}, 429);
          return _json(
            _objectFor({
              'id': 'a',
              'x': 0.0,
              'y': 0.0,
              'w': 10.0,
              'h': 10.0,
              'props': <String, dynamic>{},
            }),
          );
        }),
      );
      harness.queue.add(_commit('a'));
      async.elapse(const Duration(seconds: 5));

      expect(calls, 3);
      expect(harness.placed.map((o) => o.id), ['a']);
      expect(harness.failed, isEmpty);
    });
  });

  test(
    'undoPlacement cancels a still-unsent commit outright: no request is sent',
    () {
      fakeAsync((async) {
        var calls = 0;
        final harness = _Harness(
          _fakeApi(() {
            calls++;
            return _json(
              _objectFor({
                'id': 'held',
                'x': 0.0,
                'y': 0.0,
                'w': 10.0,
                'h': 10.0,
                'props': <String, dynamic>{},
              }),
            );
          }),
        );
        // A held commit occupies the one in-flight slot so 'a' is still pending.
        harness.queue.add(_commit('held'));
        harness.queue.add(_commit('a'));

        final outcome = harness.queue.undoPlacement('a');
        expect(outcome, UndoPlacementOutcome.cancelled);

        async.flushMicrotasks();
        expect(
          calls,
          1,
          reason: 'only the held commit should ever have been sent',
        );
        expect(harness.placed.map((o) => o.id), ['held']);
      });
    },
  );

  test(
    'undoPlacement arms the in-flight commit: onEraseOnConfirm fires instead of onPlaced',
    () {
      fakeAsync((async) {
        final harness = _Harness(
          _fakeApi(
            () => _json(
              _objectFor({
                'id': 'a',
                'x': 0.0,
                'y': 0.0,
                'w': 10.0,
                'h': 10.0,
                'props': <String, dynamic>{},
              }),
            ),
          ),
        );
        harness.queue.add(_commit('a'));

        final outcome = harness.queue.undoPlacement('a');
        expect(outcome, UndoPlacementOutcome.armed);

        async.flushMicrotasks();
        expect(harness.armedLanded, ['a']);
        expect(
          harness.placed,
          isEmpty,
          reason: 'an armed id must not also reach the ordinary placed path',
        );
      });
    },
  );

  test('a brief outage does not kill queued ink (C-007)', () {
    fakeAsync((async) {
      var outage = true;
      final harness = _Harness(
        _fakeApi(() {
          if (outage) return _json({'error': 'down'}, 503);
          return _json(
            _objectFor({
              'id': 'a',
              'x': 0.0,
              'y': 0.0,
              'w': 10.0,
              'h': 10.0,
              'props': <String, dynamic>{},
            }),
          );
        }),
      );
      harness.queue.add(_commit('a'));
      async.elapse(const Duration(seconds: 3));
      outage = false;
      async.elapse(const Duration(seconds: 30));

      expect(
        harness.failed,
        isEmpty,
        reason: 'a 3 s blip must leave the stroke pending, not kill it',
      );
    });
  });

  test('undoPlacement on an id this queue never held is unresolved', () {
    final harness = _Harness(_fakeApi(() => _json(<Object>[])));
    expect(
      harness.queue.undoPlacement('never-seen'),
      UndoPlacementOutcome.unresolved,
    );
  });
}
