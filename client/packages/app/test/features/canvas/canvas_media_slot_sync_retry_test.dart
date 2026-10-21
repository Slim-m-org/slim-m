// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tile writes retry, run in order per tile, and tell the person when a
/// change had to be put back.
library;

import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_media_slot_sync.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

api.SlimmApi _client(Future<http.Response> Function(http.Request) handler) =>
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

http.Response _slot(http.Request request) => http.Response(
  jsonEncode({
    ...(jsonDecode(request.body) as Map<String, dynamic>),
    'kind': 'screen',
    'user_id': 'alice',
    'updated_at': 1,
  }),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  test('a transient failure is retried and the tile stays put', () async {
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);
    var calls = 0;
    final errors = <String>[];
    final sync = CanvasMediaSlotSync(
      channelId: 'c1',
      client: _client((request) async {
        calls++;
        if (calls == 1) return http.Response('{}', 503);
        return _slot(request);
      }),
      overrides: overrides,
      onError: errors.add,
    );
    const dropped = Rect.fromLTWH(400, 300, 360, 203);

    overrides.setRect('screen:alice', dropped);
    await sync.commit('screen:alice', dropped);

    expect(calls, 2);
    expect(errors, isEmpty);
    expect(overrides.stateFor('screen:alice').rect, dropped);
  });

  test('a refused write is reported and the lock flips back', () async {
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);
    overrides.applyServer(
      'screen:alice',
      rect: const Rect.fromLTWH(10, 20, 360, 203),
      locked: false,
      sentToBack: false,
    );
    final errors = <String>[];
    final sync = CanvasMediaSlotSync(
      channelId: 'c1',
      client: _client((request) async => http.Response('{}', 403)),
      overrides: overrides,
      onError: errors.add,
    );

    overrides.setLocked('screen:alice', true);
    await sync.commit('screen:alice', const Rect.fromLTWH(10, 20, 360, 203));

    expect(overrides.stateFor('screen:alice').locked, isFalse);
    expect(errors, hasLength(1));
  });

  test('two writes for one tile reach the server in order', () async {
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);
    final xs = <double>[];
    final sync = CanvasMediaSlotSync(
      channelId: 'c1',
      client: _client((request) async {
        xs.add(
          ((jsonDecode(request.body) as Map<String, dynamic>)['x'] as num)
              .toDouble(),
        );
        return _slot(request);
      }),
      overrides: overrides,
    );

    final first = sync.commit(
      'screen:alice',
      const Rect.fromLTWH(1, 0, 10, 10),
    );
    final second = sync.commit(
      'screen:alice',
      const Rect.fromLTWH(2, 0, 10, 10),
    );
    await Future.wait([first, second]);

    expect(xs, [1, 2]);
  });
}
