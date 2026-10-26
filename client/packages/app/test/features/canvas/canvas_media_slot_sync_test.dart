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
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_media_slot_sync.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

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

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  _c055();
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

  test(
    'fetch stacks the tile moved last on top, whatever order the server lists',
    () async {
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);
      Map<String, Object> slot(String user, int at) => {
        'kind': 'camera',
        'user_id': user,
        'x': 0.0,
        'y': 0.0,
        'w': 220.0,
        'h': 160.0,
        'locked': false,
        'sent_to_back': false,
        'updated_at': at,
      };
      final client = _apiWith(
        (request) async => _json({
          'slots': [slot('zed', 2000), slot('amy', 1000)],
        }),
      );

      await CanvasMediaSlotSync(
        channelId: 'c1',
        client: client,
        overrides: overrides,
      ).fetch();

      expect(
        overrides.zFor('camera:zed'),
        greaterThan(overrides.zFor('camera:amy')!),
      );
    },
  );

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

  test('a failed commit tells the viewer and puts the tile back', () async {
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);
    final client = _apiWith((request) async => http.Response('nope', 500));
    String? explained;
    final sync = CanvasMediaSlotSync(
      channelId: 'c1',
      client: client,
      overrides: overrides,
      onError: (message) => explained = message,
    );

    await sync.commit('camera:alice', const Rect.fromLTWH(0, 0, 1, 1));

    expect(explained, 'That tile change could not be saved.');
    expect(overrides.stateFor('camera:alice').rect, isNull);
  });

  test('commit error explains locked tile on 409 conflict', () async {
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);
    final client = _apiWith(
      (request) async =>
          http.Response('{"error": "that object is locked in place"}', 409),
    );
    String? explained;
    final sync = CanvasMediaSlotSync(
      channelId: 'c1',
      client: client,
      overrides: overrides,
      onError: (message) => explained = message,
    );

    await sync.commit('camera:alice', const Rect.fromLTWH(0, 0, 1, 1));

    expect(explained, 'That tile is locked in place.');
    expect(overrides.stateFor('camera:alice').rect, isNull);
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

void _c055() {
  test('a rejected commit does not leave the tile only this viewer '
      'sees where it was dropped', () async {
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);
    const server = Rect.fromLTWH(10, 20, 360, 203);
    const dropped = Rect.fromLTWH(400, 300, 360, 203);
    overrides.applyServer(
      'screen:alice',
      rect: server,
      locked: false,
      sentToBack: false,
    );
    final client = _apiWith(
      (request) async => http.Response(
        jsonEncode({'error': 'locked'}),
        403,
        headers: {'content-type': 'application/json'},
      ),
    );
    final sync = CanvasMediaSlotSync(
      channelId: 'c1',
      client: client,
      overrides: overrides,
    );

    overrides.setRect('screen:alice', dropped);
    await sync.commit('screen:alice', dropped);

    expect(
      overrides.stateFor('screen:alice').rect,
      server,
      reason: 'the server refused the write, so the tile must roll back',
    );
  });

  test(
    'a commit while timed out is refused before sending and rolls back',
    () async {
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);
      const server = Rect.fromLTWH(10, 20, 360, 203);
      const dropped = Rect.fromLTWH(400, 300, 360, 203);
      overrides.applyServer(
        'screen:alice',
        rect: server,
        locked: false,
        sentToBack: false,
      );
      var requestSent = false;
      final client = _apiWith((request) async {
        requestSent = true;
        return _json({'status': 'ok'});
      });
      String? reportedError;
      final sync = CanvasMediaSlotSync(
        channelId: 'c1',
        client: client,
        overrides: overrides,
        onError: (message) => reportedError = message,
        timedOutUntil: () => DateTime.now()
            .add(const Duration(minutes: 5))
            .millisecondsSinceEpoch,
      );

      overrides.setRect('screen:alice', dropped);
      await sync.commit('screen:alice', dropped);

      expect(requestSent, isFalse);
      expect(overrides.stateFor('screen:alice').rect, server);
      expect(
        reportedError,
        contains("You're timed out and can't draw for another"),
      );
    },
  );

  test('drag preview while timed out is suppressed', () {
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);
    var previewSent = false;
    final sync = CanvasMediaSlotSync(
      channelId: 'c1',
      client: _apiWith((request) async => _json({})),
      overrides: overrides,
      sendPreview: (key, rect, {required ended}) => previewSent = true,
      timedOutUntil: () =>
          DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch,
    );

    sync.reportDrag('screen:alice', const Rect.fromLTWH(400, 300, 360, 203));
    expect(previewSent, isFalse);
  });

  test('a commit after timeout lapses sends normally', () async {
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);
    const server = Rect.fromLTWH(10, 20, 360, 203);
    const dropped = Rect.fromLTWH(400, 300, 360, 203);
    overrides.applyServer(
      'screen:alice',
      rect: server,
      locked: false,
      sentToBack: false,
    );
    var requestSent = false;
    final client = _apiWith((request) async {
      requestSent = true;
      return _json({
        'kind': 'screen',
        'user_id': 'alice',
        'x': dropped.left,
        'y': dropped.top,
        'w': dropped.width,
        'h': dropped.height,
        'locked': false,
        'sent_to_back': false,
        'updated_at': 1000,
      });
    });
    final sync = CanvasMediaSlotSync(
      channelId: 'c1',
      client: client,
      overrides: overrides,
      timedOutUntil: () => DateTime.now()
          .subtract(const Duration(minutes: 1))
          .millisecondsSinceEpoch,
    );

    overrides.setRect('screen:alice', dropped);
    await sync.commit('screen:alice', dropped);

    expect(requestSent, isTrue);
    expect(overrides.stateFor('screen:alice').rect, dropped);
  });
}
