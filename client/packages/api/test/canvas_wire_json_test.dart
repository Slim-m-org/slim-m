// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Canvas frames and REST bodies parsed from JSON text, the way they arrive,
/// including a body of the wrong shape.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

const _object = {
  'id': 'o1',
  'channel_id': 'c1',
  'author_id': 'u1',
  'kind': 'stroke',
  'x': 1.5,
  'y': 2,
  'w': 30,
  'h': 40,
  'z_index': 3,
  'props': {
    'points': [0, 0, 5, 5],
  },
  'seq': 9,
  'created_at': 1000,
};

ServerEvent? _parse(Map<String, Object?> frame) =>
    ServerEvent.parse(jsonEncode(frame));

SlimmApi _api(Object? body) => SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'u1',
          accessToken: 'access',
          refreshToken: 'refresh',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

void main() {
  group('frames', () {
    test('canvas.object.placed carries the object and its seq', () {
      final event = _parse({
        'type': 'canvas.object.placed',
        'channel_id': 'c1',
        'object': _object,
      });

      expect(event, isA<CanvasObjectPlaced>());
      expect((event! as CanvasObjectPlaced).seq, 9);
    });

    test('canvas.objects.removed and restored carry their ids', () {
      final removed = _parse({
        'type': 'canvas.objects.removed',
        'channel_id': 'c1',
        'seq': 4,
        'op_id': 'op',
        'object_ids': ['a', 'b'],
      });
      final restored = _parse({
        'type': 'canvas.objects.restored',
        'channel_id': 'c1',
        'seq': 5,
        'op_id': 'op2',
        'object_ids': <String>[],
      });

      expect((removed! as CanvasObjectsRemoved).objectIds, ['a', 'b']);
      expect((restored! as CanvasObjectsRestored).objectIds, isEmpty);
    });

    test('canvas.object.lock_changed carries the new state', () {
      final event = _parse({
        'type': 'canvas.object.lock_changed',
        'channel_id': 'c1',
        'object_id': 'o1',
        'locked': true,
      });

      expect((event! as CanvasObjectLockChanged).locked, isTrue);
    });

    test('a frame of the wrong type is dropped, not thrown', () {
      expect(
        _parse({
          'type': 'canvas.objects.removed',
          'channel_id': 'c1',
          'seq': 'four',
          'op_id': 'op',
          'object_ids': ['a'],
        }),
        isNull,
      );
      expect(
        _parse({
          'type': 'canvas.object.placed',
          'channel_id': 'c1',
          'object': {...(_object), 'x': 'left'},
        }),
        isNull,
      );
    });
  });

  group('bodies', () {
    test('an ops page parses every op kind', () async {
      final page = await _api({
        'ops': [
          {
            'seq': 1,
            'id': 'a',
            'actor_id': 'u1',
            'created_at': 1,
            'kind': 'place',
            'object': _object,
          },
          {
            'seq': 2,
            'id': 'b',
            'actor_id': 'u1',
            'created_at': 1,
            'kind': 'remove',
            'object_ids': ['o1'],
          },
          {
            'seq': 3,
            'id': 'c',
            'actor_id': 'u1',
            'created_at': 1,
            'kind': 'restore',
            'target_op': 'b',
            'object_ids': ['o1'],
          },
          {
            'seq': 4,
            'id': 'd',
            'actor_id': 'u1',
            'created_at': 1,
            'kind': 'move',
            'object_id': 'o1',
            'x': 1,
            'y': 2,
            'w': 3,
            'h': 4,
          },
          {
            'seq': 5,
            'id': 'e',
            'actor_id': 'u1',
            'created_at': 1,
            'kind': 'reorder',
            'object_id': 'o1',
            'z_index': 7,
          },
          {
            'seq': 6,
            'id': 'f',
            'actor_id': 'u1',
            'created_at': 1,
            'kind': 'edit',
            'object_id': 'o1',
            'props': {'text': 'hi'},
          },
        ],
        'latest_seq': 6,
        'has_more': false,
        'reset': false,
      }).canvasOps('c1', afterSeq: 0);

      expect(page.ops.map((op) => op.runtimeType), [
        CanvasPlaceOp,
        CanvasRemoveOp,
        CanvasRestoreOp,
        CanvasMoveOp,
        CanvasReorderOp,
        CanvasEditOp,
      ]);
    });

    test('a viewport page reads the total the server may add', () async {
      final page = await _api({
        'objects': [_object],
        'has_more': true,
        'latest_seq': 9,
        'total_objects': 4200,
      }).canvasViewport(
        'c1',
        region: const CanvasRect(minX: 0, minY: 0, maxX: 1, maxY: 1),
      );

      expect(page.totalObjects, 4200);
      expect(page.hasMore, isTrue);
    });

    test('a viewport page without a total still parses', () async {
      final page = await _api({
        'objects': <Object>[],
        'has_more': false,
        'latest_seq': 1,
      }).canvasViewport(
        'c1',
        region: const CanvasRect(minX: 0, minY: 0, maxX: 1, maxY: 1),
      );

      expect(page.totalObjects, isNull);
    });

    test('a lock list parses', () async {
      final ids = await _api({
        'object_ids': ['a', 'b'],
      }).canvasObjectLocks('c1');

      expect(ids, {'a', 'b'});
    });

    test('a body of the wrong shape is a transport error, not a TypeError', () {
      final bad = _api({'objects': 'none', 'has_more': false});

      expect(
        bad.canvasViewport(
          'c1',
          region: const CanvasRect(minX: 0, minY: 0, maxX: 1, maxY: 1),
        ),
        throwsA(isA<TransportException>()),
      );
      expect(
        _api(['not', 'a', 'map']).canvasOps('c1', afterSeq: 0),
        throwsA(isA<TransportException>()),
      );
      expect(
        _api({'object_ids': 7}).canvasObjectLocks('c1'),
        throwsA(isA<TransportException>()),
      );
    });
  });
}
