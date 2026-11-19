// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Switching from one call to another: what becomes of the call switched from.
library;

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

/// Grants a token for every channel but `full`, which is refused; records every request.
http.Client _api(List<http.Request> requests) => MockClient((request) async {
  requests.add(request);
  final path = request.url.path;
  if (path.endsWith('/voice/heartbeat')) return http.Response('', 204);
  if (path.endsWith('/voice/roster')) {
    return http.Response('{"participants":[],"call_age_ms":null}', 200);
  }
  if (!path.endsWith('/voice/token')) return http.Response('{}', 404);
  if (path.contains('/full/')) {
    return http.Response(
      jsonEncode({
        'error': {'code': 'forbidden', 'message': 'that room is full'},
      }),
      403,
      headers: {'content-type': 'application/json'},
    );
  }
  return http.Response(
    jsonEncode({
      'url': 'wss://sfu.example.com',
      'room': 'room',
      'token': 'jwt',
      'expires_at': 0,
      'can_publish': true,
    }),
    200,
    headers: {'content-type': 'application/json'},
  );
});

/// Connects its first call and fails to connect any later one, having left the room it was in.
class _SecondJoinFails extends FakeSession {
  int _joins = 0;

  @override
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
    bool canPublish = true,
  }) async {
    if (_joins++ == 0) return emitState(VoiceSessionState.connected);
    emitState(VoiceSessionState.connecting);
    emitState(VoiceSessionState.failed);
  }
}

Iterable<String> _forgotten(List<http.Request> requests) => requests
    .where(
      (r) => r.method == 'DELETE' && r.url.path.endsWith('/voice/heartbeat'),
    )
    .map((r) => r.url.pathSegments[1]);

void main() {
  final harness = VoiceHarness();

  tearDown(harness.dispose);

  test('a switch the server refuses ends the call switched from', () {
    fakeAsync((async) {
      final requests = <http.Request>[];
      final session = FakeSession();
      final controller = harness.controllerWith(session, _api(requests));

      unawaited(controller.join('lounge'));
      async.flushMicrotasks();
      session.emitState(VoiceSessionState.connected);
      async.flushMicrotasks();
      expect(session.state, VoiceSessionState.connected);

      unawaited(controller.join('full'));
      async.flushMicrotasks();

      expect(controller.state.channelId, 'full');
      expect(controller.state.state, VoiceSessionState.failed);
      expect(controller.state.error, isNotNull);
      expect(
        session.state,
        isNot(VoiceSessionState.connected),
        reason:
            'the screen shows no call, so the lounge must not still '
            'have this microphone in it',
      );
      expect(_forgotten(requests), ['lounge']);

      final beats = requests.length;
      async.elapse(const Duration(seconds: 40));
      expect(
        requests.length,
        beats,
        reason: 'nothing may keep proving a call that ended',
      );
    });
  });

  test('a switch tells the server the call switched from was left', () {
    fakeAsync((async) {
      final requests = <http.Request>[];
      final session = FakeSession();
      final controller = harness.controllerWith(session, _api(requests));

      unawaited(controller.join('lounge'));
      async.flushMicrotasks();
      session.emitState(VoiceSessionState.connected);
      async.flushMicrotasks();

      unawaited(controller.join('games'));
      async.flushMicrotasks();
      // The session leaves the old room and connects the new one.
      session.emitState(VoiceSessionState.idle);
      session.emitState(VoiceSessionState.connected);
      async.flushMicrotasks();

      expect(controller.state.channelId, 'games');
      expect(
        _forgotten(requests),
        ['lounge'],
        reason:
            'left unsaid, the server counts this member in the lounge '
            'until its sweep, and a ring started there keeps ringing',
      );
    });
  });

  test(
    'a switch that cannot connect tells the server the old call was left',
    () {
      fakeAsync((async) {
        final requests = <http.Request>[];
        final controller = harness.controllerWith(
          _SecondJoinFails(),
          _api(requests),
        );
        unawaited(controller.join('lounge'));
        async.flushMicrotasks();
        expect(controller.state.state, VoiceSessionState.connected);

        unawaited(controller.join('games'));
        async.flushMicrotasks();

        expect(controller.state.channelId, 'games');
        expect(controller.state.state, VoiceSessionState.failed);
        expect(_forgotten(requests), [
          'lounge',
        ], reason: 'the session left the lounge to try the call that failed');
      });
    },
  );

  test('a hang-up during a switch tells the server the old call was left', () {
    fakeAsync((async) {
      final requests = <http.Request>[];
      final session = FakeSession();
      final controller = harness.controllerWith(session, _api(requests));
      unawaited(controller.join('lounge'));
      async.flushMicrotasks();
      session.emitState(VoiceSessionState.connected);
      async.flushMicrotasks();

      unawaited(controller.join('games'));
      unawaited(controller.leave());
      async.flushMicrotasks();

      expect(controller.state.channelId, isNull);
      expect(_forgotten(requests), contains('lounge'));
    });
  });
}
