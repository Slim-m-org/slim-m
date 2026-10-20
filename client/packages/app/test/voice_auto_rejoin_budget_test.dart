// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Auto-rejoin gives up on refusals that cannot change, and a flapping link
/// spends one budget across its connects instead of getting a fresh one each time.
library;

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import 'features/voice/voice_controller_harness.dart';

class _Session extends FakeSession {
  int joins = 0;

  @override
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
    bool canPublish = true,
  }) async {
    joins++;
    lastDisconnect = null;
    await super.join(
      url: url,
      token: token,
      microphoneEnabled: microphoneEnabled,
      cameraEnabled: cameraEnabled,
    );
    emitState(VoiceSessionState.connected);
  }
}

http.Client _api({
  required bool Function() refuse,
  required int status,
  void Function()? onToken,
}) => MockClient((request) async {
  if (request.url.path.endsWith('/voice/heartbeat')) {
    return http.Response('', 204);
  }
  if (request.url.path.endsWith('/voice/token')) onToken?.call();
  if (refuse()) {
    return http.Response(
      jsonEncode({
        'error': {'code': 'nope', 'message': 'refused'},
      }),
      status,
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final harness = VoiceHarness();
  tearDown(harness.dispose);

  const delays = [Duration(seconds: 2), Duration(seconds: 5)];
  const wholeBudget = Duration(seconds: 8);

  test('a refusal that can never succeed is not retried', () {
    fakeAsync((async) {
      var refuse = false;
      var tokenRequests = 0;
      final session = _Session();
      final controller = harness.controllerWith(
        session,
        _api(refuse: () => refuse, status: 403, onToken: () => tokenRequests++),
        autoRejoinDelays: delays,
      );
      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();
      refuse = true;
      session.dropWith(VoiceDisconnect.connectionLost);
      async.flushMicrotasks();

      async.elapse(wholeBudget);
      async.flushMicrotasks();

      expect(
        tokenRequests,
        2,
        reason: 'the first attempt learns it is forbidden',
      );
      expect(controller.state.retryable, isFalse);
      expect(controller.state.rejoining, isFalse);
    });
  });

  test('a link that connects and drops at once runs out of attempts', () {
    fakeAsync((async) {
      final session = _Session();
      final controller = harness.controllerWith(
        session,
        _api(refuse: () => false, status: 200),
        autoRejoinDelays: delays,
      );
      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();

      for (var i = 0; i < 6; i++) {
        session.dropWith(VoiceDisconnect.connectionLost);
        async.flushMicrotasks();
        async.elapse(delays.last + const Duration(seconds: 1));
        async.flushMicrotasks();
      }

      expect(session.joins, lessThanOrEqualTo(1 + delays.length + 1));
      expect(controller.state.rejoining, isFalse);
    });
  });

  test('a connection that held for a minute earns a fresh budget', () {
    fakeAsync((async) {
      final session = _Session();
      final controller = harness.controllerWith(
        session,
        _api(refuse: () => false, status: 200),
        autoRejoinDelays: delays,
      );
      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();

      for (var i = 0; i < 4; i++) {
        session.dropWith(VoiceDisconnect.connectionLost);
        async.flushMicrotasks();
        async.elapse(delays.last + const Duration(seconds: 1));
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 2));
      }

      expect(session.joins, 1 + 4);
      expect(controller.state.state, VoiceSessionState.connected);
    });
  });
}
