// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `rejoining` covers an automatic attempt in flight, not only the wait
/// before it: a surface that keys off it (the canvas dock's call controls,
/// the call stage) must not lose them for the length of every retry.
library;

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

class _HeldSession extends FakeSession {
  Completer<void>? hold;
  int joins = 0;

  @override
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
  }) async {
    joins++;
    lastDisconnect = null;
    final gate = hold;
    if (gate != null) await gate.future;
    await super.join(
      url: url,
      token: token,
      microphoneEnabled: microphoneEnabled,
      cameraEnabled: cameraEnabled,
    );
    emitState(VoiceSessionState.connected);
  }
}

/// A voice api whose token route can be flipped to a permanent refusal.
class _FlippableApi {
  bool refuse = false;

  late final http.Client client = MockClient((request) async {
    if (!request.url.path.endsWith('/voice/token')) {
      return http.Response('', 204);
    }
    if (refuse) {
      return http.Response(
        jsonEncode({
          'error': {'code': 'forbidden', 'message': 'no'},
        }),
        403,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response(
      jsonEncode({
        'url': 'wss://sfu.example.com',
        'room': 'channel-1',
        'token': 'jwt',
        'expires_at': 0,
        'can_publish': true,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final harness = VoiceHarness();

  tearDown(harness.dispose);

  const delays = [Duration(seconds: 2), Duration(seconds: 5)];

  test('rejoining stays true while an automatic attempt is in flight', () {
    fakeAsync((async) {
      final session = _HeldSession();
      final controller = harness.controllerWith(
        session,
        voiceApi(),
        autoRejoinDelays: delays,
      );
      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();
      session.dropWith(VoiceDisconnect.connectionLost);
      async.flushMicrotasks();

      session.hold = Completer<void>();
      async.elapse(delays.first);
      async.flushMicrotasks();

      expect(session.joins, 2, reason: 'the attempt must be in flight');
      expect(controller.state.joining, isTrue);
      expect(
        controller.state.rejoining,
        isTrue,
        reason: 'a retry in flight is still the same reconnecting window',
      );

      session.hold!.complete();
      async.flushMicrotasks();
      expect(controller.state.state, VoiceSessionState.connected);
      expect(controller.state.rejoining, isFalse);
    });
  });

  test('a first join in flight is not a rejoin', () {
    fakeAsync((async) {
      final session = _HeldSession()..hold = Completer<void>();
      final controller = harness.controllerWith(
        session,
        voiceApi(),
        autoRejoinDelays: delays,
      );
      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();

      expect(controller.state.joining, isTrue);
      expect(controller.state.rejoining, isFalse);
    });
  });

  test('a manual join in flight while a retry is queued is not a rejoin', () {
    fakeAsync((async) {
      final session = _HeldSession();
      final controller = harness.controllerWith(
        session,
        voiceApi(),
        autoRejoinDelays: delays,
      );
      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();
      session.dropWith(VoiceDisconnect.connectionLost);
      async.flushMicrotasks();
      expect(controller.state.rejoining, isTrue);

      session.hold = Completer<void>();
      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();

      expect(controller.state.rejoining, isFalse);
    });
  });

  test('an attempt the server refuses for good clears rejoining', () {
    fakeAsync((async) {
      final session = _HeldSession();
      final api = _FlippableApi();
      final controller = harness.controllerWith(
        session,
        api.client,
        autoRejoinDelays: delays,
      );
      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();
      expect(session.joins, 1);
      session.dropWith(VoiceDisconnect.connectionLost);
      async.flushMicrotasks();
      api.refuse = true;

      async.elapse(delays.first);
      async.flushMicrotasks();

      expect(controller.state.state, VoiceSessionState.failed);
      expect(controller.state.retryable, isFalse);
      expect(
        controller.state.rejoining,
        isFalse,
        reason: 'nothing is retrying, so the manual surface must take over',
      );
    });
  });
}
