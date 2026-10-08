// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A canvas object locked in place: a drag, a resize and an erase pass
/// through it, and the lock store follows the server and live frames.
library;

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/screens/canvas/canvas_commit_queue.dart';
import 'package:slimm_app/src/screens/canvas/canvas_object_locks.dart';
import 'package:slimm_app/src/screens/canvas/canvas_ops_controller.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class _Harness {
  _Harness() {
    final client = api.SlimmApi(
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
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        opRequests.add(body);
        _opSeq++;
        return _json({
          'op': {
            'id': 'server-op-$_opSeq',
            'seq': _opSeq,
            'kind': body['kind'],
            'affected': 1,
            'created_at': 0,
          },
          'fresh': true,
        });
      }),
    );
    commits = CanvasCommitQueue(
      client: client,
      channelId: 'c1',
      onPlaced: (_) {},
      onFailed: (_, _) {},
      onRemoved: (_) {},
      onEraseOnConfirm: (_) async {},
      timedOutUntil: () => null,
    );
    ops = CanvasOpsController(
      channelId: 'c1',
      client: client,
      document: document,
      commits: commits,
      onError: (_) {},
      isLocked: locked.contains,
    );
  }

  final CanvasDocument document = CanvasDocument()
    ..setViewport(const Size(800, 600));
  late final CanvasCommitQueue commits;
  late final CanvasOpsController ops;
  final List<Map<String, dynamic>> opRequests = [];
  final Set<String> locked = {};
  var _opSeq = 0;
}

CanvasStrokeInput _image(String id, double x, double y, double size, int z) =>
    CanvasStrokeInput(
      id: id,
      seq: z,
      zIndex: z,
      x: x,
      y: y,
      w: size,
      h: size,
      points: const [],
      width: 0,
      colorKey: 'annotation',
      authorId: 'me',
      kind: CanvasObjectKind.image,
    );

_Harness _layered() {
  final harness = _Harness();
  harness.document.applyPlaced(_image('photo', 100, 100, 200, 1));
  harness.document.applyPlaced(_image('sticker', 250, 250, 30, 2));
  harness.document.refresh();
  harness.locked.add('photo');
  return harness;
}

void main() {
  test('a drag on a locked photo passes through it and moves nothing', () {
    fakeAsync((async) {
      final harness = _layered();
      harness.ops.beginSelect(
        const Offset(150, 150),
        manageCanvas: true,
        selfId: 'me',
      );
      harness.ops.dragSelect(const Offset(190, 190), lockAspect: false);
      unawaited(harness.ops.endSelect());
      async.flushMicrotasks();
      expect(harness.document.selectedObjectId.value, isNull);
      expect(harness.opRequests, isEmpty);
    });
  });

  test('a photo layered over a locked one moves on its own', () {
    fakeAsync((async) {
      final harness = _layered();
      harness.ops.beginSelect(
        const Offset(265, 265),
        manageCanvas: true,
        selfId: 'me',
      );
      harness.ops.dragSelect(const Offset(285, 285), lockAspect: false);
      unawaited(harness.ops.endSelect());
      async.flushMicrotasks();
      expect(harness.opRequests.single['kind'], 'move');
      expect(harness.opRequests.single['object_id'], 'sticker');
      final photo = harness.document.objectBounds('photo')!;
      expect(
        (photo.x, photo.y),
        (100.0, 100.0),
        reason: 'the locked photo stays put',
      );
    });
  });

  test('a locked photo grows no resize handle even when selected', () {
    fakeAsync((async) {
      final harness = _layered();
      harness.document.selectedObjectId.value = 'photo';
      harness.ops.beginSelect(
        const Offset(300, 300),
        manageCanvas: true,
        selfId: 'me',
      );
      harness.ops.dragSelect(const Offset(340, 340), lockAspect: false);
      unawaited(harness.ops.endSelect());
      async.flushMicrotasks();
      expect(harness.opRequests, isEmpty);
      expect(harness.document.objectBounds('photo')!.w, 200);
    });
  });

  test('an erase sweeping over a locked stroke leaves it', () {
    fakeAsync((async) {
      final harness = _Harness();
      harness.document.applyPlaced(
        const CanvasStrokeInput(
          id: 'ink',
          seq: 1,
          zIndex: 1,
          x: 100,
          y: 100,
          w: 100,
          h: 4,
          points: [0, 2, 100, 2],
          width: 4,
          colorKey: 'annotation',
          authorId: 'me',
          kind: CanvasObjectKind.stroke,
        ),
      );
      harness.document.refresh();
      harness.locked.add('ink');
      harness.ops.onErasePoint(
        const Offset(150, 102),
        manageCanvas: true,
        selfId: 'me',
      );
      expect(harness.document.objectBounds('ink'), isNotNull);
    });
  });

  group('CanvasObjectLocks', () {
    CanvasObjectLocks locks(MockClient http) => CanvasObjectLocks(
      channelId: 'c1',
      client: api.SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: api.SessionStore(
          tokens: const api.TokenPair(
            userId: 'me',
            accessToken: 'a',
            refreshToken: 'r',
            accessExpiresAt: 4102444800000,
          ),
        ),
        httpClient: http,
      ),
    );

    test(
      'a live frame for this channel locks and unlocks; another channel is ignored',
      () {
        final store = locks(MockClient((_) async => http.Response('', 204)));
        store.applyRemote(
          const api.CanvasObjectLockChanged(
            channelId: 'c1',
            objectId: 'o1',
            locked: true,
          ),
        );
        store.applyRemote(
          const api.CanvasObjectLockChanged(
            channelId: 'c2',
            objectId: 'o2',
            locked: true,
          ),
        );
        expect(store.ids.value, {'o1'});
        store.applyRemote(
          const api.CanvasObjectLockChanged(
            channelId: 'c1',
            objectId: 'o1',
            locked: false,
          ),
        );
        expect(store.ids.value, isEmpty);
      },
    );

    test('a lock the server refuses is put back', () async {
      final store = locks(
        MockClient((_) async => _json({'error': 'forbidden'}, 403)),
      );
      expect(await store.setLocked('o1', true), isFalse);
      expect(store.ids.value, isEmpty);
    });

    test('fetch reads the locked ids', () async {
      final store = locks(
        MockClient(
          (_) async => _json({
            'object_ids': ['o1', 'o2'],
          }),
        ),
      );
      await store.fetch();
      expect(store.ids.value, {'o1', 'o2'});
    });
  });
}
