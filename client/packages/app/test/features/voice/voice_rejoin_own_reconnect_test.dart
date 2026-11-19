// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The SFU ends a connection as "joined from another device" for this client's own reconnect
/// overtaking its old connection too; only the room's list says which of the two it was.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

class _RejoiningSession extends FakeSession {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final harness = VoiceHarness();

  tearDown(harness.dispose);

  const delays = [Duration(seconds: 2), Duration(seconds: 5)];

  ({VoiceController controller, _RejoiningSession session}) inCallThenBlamed(
    FakeAsync async,
    http.Client api,
  ) {
    final session = _RejoiningSession();
    final controller = harness.controllerWith(
      session,
      api,
      autoRejoinDelays: delays,
    );
    unawaited(controller.join('channel-1'));
    async.flushMicrotasks();
    expect(controller.state.state, VoiceSessionState.connected);
    session.dropWith(VoiceDisconnect.replacedByOtherDevice);
    async.flushMicrotasks();
    return (controller: controller, session: session);
  }

  test('a reconnect of this device the SFU blamed on another comes back', () {
    fakeAsync((async) {
      final call = inCallThenBlamed(async, voiceApi(listedOnThisDevice: true));
      expect(call.controller.state.rejoining, isTrue);
      expect(
        call.controller.state.error,
        isNot(VoiceDisconnect.replacedByOtherDevice.message),
        reason: 'nothing has said another device holds the call yet',
      );

      async.elapse(delays.first);
      async.flushMicrotasks();

      expect(call.session.joins, 2);
      expect(call.controller.state.state, VoiceSessionState.connected);
      expect(call.controller.state.rejoining, isFalse);
    });
  });

  test('a room that lists nobody for this account is rejoined too', () {
    fakeAsync((async) {
      final call = inCallThenBlamed(async, voiceApi());

      async.elapse(delays.first);
      async.flushMicrotasks();

      expect(call.session.joins, 2);
    });
  });

  test('another device that took the call keeps it', () {
    fakeAsync((async) {
      final call = inCallThenBlamed(async, voiceApi(listedOnThisDevice: false));

      async.elapse(delays.reduce((a, b) => a + b) * 2);
      async.flushMicrotasks();

      expect(call.session.joins, 1);
      expect(call.controller.state.rejoining, isFalse);
      expect(call.controller.state.state, VoiceSessionState.failed);
      expect(
        call.controller.state.error,
        VoiceDisconnect.replacedByOtherDevice.message,
      );
    });
  });

  int forgets(List<http.Request> seen) => seen
      .where((r) => r.method == 'DELETE' && r.url.path.endsWith('/heartbeat'))
      .length;

  test('hanging up a call another device took leaves it on record', () {
    fakeAsync((async) {
      final seen = <http.Request>[];
      final call = inCallThenBlamed(
        async,
        voiceApi(listedOnThisDevice: false, onRequest: seen.add),
      );
      async.elapse(delays.first);
      async.flushMicrotasks();
      expect(call.controller.state.rejoining, isFalse);

      unawaited(call.controller.leave());
      async.flushMicrotasks();
      unawaited(call.controller.join('channel-2'));
      async.flushMicrotasks();

      expect(
        forgets(seen),
        0,
        reason: 'the heartbeat on record is the other device\'s by now',
      );
    });
  });

  test(
    'a call rejoined here after another device took it is left as usual',
    () {
      fakeAsync((async) {
        final seen = <http.Request>[];
        final call = inCallThenBlamed(
          async,
          voiceApi(listedOnThisDevice: false, onRequest: seen.add),
        );
        async.elapse(delays.first);
        async.flushMicrotasks();
        unawaited(call.controller.join('channel-1'));
        async.flushMicrotasks();
        expect(call.controller.state.state, VoiceSessionState.connected);

        unawaited(call.controller.leave());
        async.flushMicrotasks();

        expect(forgets(seen), 1);
      });
    },
  );
}
