// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Lock and media-slot state is ordered by the server's version, so a late
/// frame, an older read or a failed optimistic change cannot undo newer state.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_media_slot_sync.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_object_locks.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

api.SlimmApi _apiWith(Future<http.Response> Function(http.Request) handler) =>
    testApi(
      handler,
      session: api.SessionStore(
        tokens: const api.TokenPair(
          userId: 'me',
          accessToken: 'access',
          refreshToken: 'refresh',
          accessExpiresAt: 0,
        ),
      ),
    );

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

api.CanvasObjectLockChanged _lock(String id, bool locked, int version) =>
    api.CanvasObjectLockChanged(
      channelId: 'c1',
      objectId: id,
      locked: locked,
      version: version,
    );

api.CanvasMediaSlotChanged _slot(double x, int version) =>
    api.CanvasMediaSlotChanged(
      channelId: 'c1',
      kind: 'camera',
      userId: 'alice',
      x: x,
      y: 0,
      w: 100,
      h: 80,
      locked: false,
      sentToBack: false,
      version: version,
    );

void main() {
  group('object locks', () {
    CanvasObjectLocks locks(
      Future<http.Response> Function(http.Request) handler,
    ) => CanvasObjectLocks(channelId: 'c1', client: _apiWith(handler));

    test('a lock frame older than the one already applied is ignored', () {
      final store = locks((_) async => _json({}));
      store.applyRemote(_lock('o1', false, 7));
      store.applyRemote(_lock('o1', true, 5));
      expect(store.ids.value, isEmpty);
    });

    test(
      'a frame at the same version as a read is already in the read',
      () async {
        final store = locks(
          (_) async => _json({'object_ids': <String>[], 'version': 9}),
        );
        await store.fetch();
        store.applyRemote(_lock('o1', true, 9));
        expect(store.ids.value, isEmpty);
        store.applyRemote(_lock('o1', true, 10));
        expect(store.ids.value, {'o1'});
      },
    );

    test('a read taken before a newer frame does not undo it', () async {
      final reply = Completer<http.Response>();
      final store = locks((_) => reply.future);
      final fetching = store.fetch();
      store.applyRemote(_lock('o1', true, 8));
      reply.complete(_json({'object_ids': <String>[], 'version': 6}));
      await fetching;
      expect(store.ids.value, {'o1'});
    });

    test('a refused lock puts back only its own object', () async {
      final reply = Completer<http.Response>();
      final store = locks((_) => reply.future);
      final locking = store.setLocked('o1', true);
      store.applyRemote(_lock('o2', true, 4));
      reply.complete(_json({'error': 'forbidden'}, 403));
      expect(await locking, isFalse);
      expect(store.ids.value, {'o2'});
    });
  });

  group('media slots', () {
    CanvasMediaSlotSync sync(
      Future<http.Response> Function(http.Request) handler,
      CanvasPresenceTileOverrides overrides,
    ) => CanvasMediaSlotSync(
      channelId: 'c1',
      client: _apiWith(handler),
      overrides: overrides,
    );

    test('a slot frame older than the one already applied is ignored', () {
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);
      final slots = sync((_) async => _json({}), overrides);
      slots.applyRemote(_slot(50, 8));
      slots.applyRemote(_slot(10, 6));
      expect(overrides.stateFor('camera:alice').rect?.left, 50);
    });

    test('a read taken before a newer frame does not undo it', () async {
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);
      final reply = Completer<http.Response>();
      final slots = sync((_) => reply.future, overrides);
      final fetching = slots.fetch();
      slots.applyRemote(_slot(50, 8));
      reply.complete(
        _json({
          'version': 6,
          'slots': [
            {
              'kind': 'camera',
              'user_id': 'alice',
              'x': 10.0,
              'y': 0.0,
              'w': 100.0,
              'h': 80.0,
              'locked': false,
              'sent_to_back': false,
              'updated_at': 1,
            },
          ],
        }),
      );
      await fetching;
      expect(
        overrides.stateFor('camera:alice').rect,
        const Rect.fromLTWH(50, 0, 100, 80),
      );
    });

    test('frames from a server that sends no version still apply in order', () {
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);
      final slots = sync((_) async => _json({}), overrides);
      slots.applyRemote(_slot(50, 0));
      slots.applyRemote(_slot(10, 0));
      expect(overrides.stateFor('camera:alice').rect?.left, 10);
    });
  });
}
