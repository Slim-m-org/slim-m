// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasMediaSlotSync]: the cold fetch applies every slot the server
/// answers with, [CanvasMediaSlotSync.commit] sends the right kind and
/// participant for a tile key, and [CanvasMediaSlotSync.applyRemote] only
/// ever touches its own channel.
library;

import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_media_slot_sync.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

api.SlimmApi _apiWith(Future<http.Response> Function(http.Request) handler) =>
    api.SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: api.SessionStore(
        tokens: const api.TokenPair(
          userId: 'me',
          accessToken: 'access',
          refreshToken: 'refresh',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient(handler),
    );

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  test('fetch applies every slot the server answers with', () async {
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);
    final client = _apiWith((request) async {
      expect(request.url.path, '/channels/c1/canvas/media-slots');
      return _json({
        'slots': [
          {
            'kind': 'screen',
            'user_id': 'alice',
            'x': 10.0,
            'y': 20.0,
            'w': 360.0,
            'h': 203.0,
            'locked': false,
            'sent_to_back': true,
            'updated_at': 1000,
          },
        ],
      });
    });
    final sync = CanvasMediaSlotSync(
      channelId: 'c1',
      client: client,
      overrides: overrides,
    );

    await sync.fetch();

    final state = overrides.stateFor('screen:alice');
    expect(state.rect, const Rect.fromLTWH(10, 20, 360, 203));
    expect(state.locked, isFalse);
    expect(state.sentToBack, isTrue);
  });

  test('a failed fetch leaves every tile at its default arrangement', () async {
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);
    final client = _apiWith((request) async => http.Response('nope', 500));
    final sync = CanvasMediaSlotSync(
      channelId: 'c1',
      client: client,
      overrides: overrides,
    );

    await sync.fetch();

    expect(overrides.stateFor('camera:alice').rect, isNull);
  });

  test('commit sends the tile key\'s own kind, participant and rect', () async {
    final overrides = CanvasPresenceTileOverrides()
      ..setLocked('camera:alice', true);
    addTearDown(overrides.dispose);
    String? capturedPath;
    Map<String, dynamic>? capturedBody;
    final client = _apiWith((request) async {
      capturedPath = request.url.path;
      capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
      return _json({
        'kind': 'camera',
        'user_id': 'alice',
        'x': 1.0,
        'y': 2.0,
        'w': 220.0,
        'h': 160.0,
        'locked': true,
        'sent_to_back': false,
        'updated_at': 1000,
      });
    });
    final sync = CanvasMediaSlotSync(
      channelId: 'c1',
      client: client,
      overrides: overrides,
    );

    await sync.commit('camera:alice', const Rect.fromLTWH(1, 2, 220, 160));

    expect(capturedPath, '/channels/c1/canvas/media-slots/camera/alice');
    expect(capturedBody, {
      'x': 1.0,
      'y': 2.0,
      'w': 220.0,
      'h': 160.0,
      'locked': true,
      'sent_to_back': false,
    });
  });

  test('a failed commit does not throw', () async {
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);
    final client = _apiWith((request) async => http.Response('nope', 500));
    final sync = CanvasMediaSlotSync(
      channelId: 'c1',
      client: client,
      overrides: overrides,
    );

    await sync.commit('camera:alice', const Rect.fromLTWH(0, 0, 1, 1));
  });

  test('applyRemote ignores a frame for a different channel', () {
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);
    final sync = CanvasMediaSlotSync(
      channelId: 'c1',
      client: _apiWith((_) async => _json(const {})),
      overrides: overrides,
    );

    sync.applyRemote(
      const api.CanvasMediaSlotChanged(
        channelId: 'other-channel',
        kind: 'camera',
        userId: 'alice',
        x: 5,
        y: 5,
        w: 100,
        h: 100,
        locked: false,
        sentToBack: false,
      ),
    );

    expect(overrides.stateFor('camera:alice').rect, isNull);
  });

  test('applyRemote applies a frame naming its own channel', () {
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);
    final sync = CanvasMediaSlotSync(
      channelId: 'c1',
      client: _apiWith((_) async => _json(const {})),
      overrides: overrides,
    );

    sync.applyRemote(
      const api.CanvasMediaSlotChanged(
        channelId: 'c1',
        kind: 'camera',
        userId: 'alice',
        x: 5,
        y: 6,
        w: 100,
        h: 90,
        locked: true,
        sentToBack: true,
      ),
    );

    final state = overrides.stateFor('camera:alice');
    expect(state.rect, const Rect.fromLTWH(5, 6, 100, 90));
    expect(state.locked, isTrue);
    expect(state.sentToBack, isTrue);
  });
}
