// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The SFU ends a connection as "joined from another device" for this client's own reconnect
/// overtaking its old connection too; only the room's list says which of the two it was.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_rejoin.dart';
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
    http.Client api, {
    VoiceDisconnect drop = VoiceDisconnect.replacedByOtherDevice,
  }) {
    final session = _RejoiningSession();
    final controller = harness.controllerWith(
      session,
      api,
      autoRejoinDelays: delays,
    );
    unawaited(controller.join('channel-1'));
    async.flushMicrotasks();
    expect(controller.state.state, VoiceSessionState.connected);
    session.dropWith(drop);
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

  test('hanging up before the room has answered leaves the call on record', () {
    fakeAsync((async) {
      final seen = <http.Request>[];
      final call = inCallThenBlamed(
        async,
        voiceApi(listedOnThisDevice: false, onRequest: seen.add),
      );
      expect(call.controller.state.rejoining, isTrue);

      unawaited(call.controller.leave());
      async.flushMicrotasks();
      async.elapse(delays.reduce((a, b) => a + b));

      expect(
        forgets(seen),
        0,
        reason: 'nothing has said this call is not the other device\'s',
      );
    });
  });

  test('a room that cannot be read is asked again instead of rejoined', () {
    fakeAsync((async) {
      var unreadable = true;
      final call = inCallThenBlamed(
        async,
        voiceApi(listedOnThisDevice: false, rosterUnreadable: () => unreadable),
      );

      async.elapse(delays.first);
      async.flushMicrotasks();

      expect(
        call.session.joins,
        1,
        reason: 'a failed read is no proof the call is still this device\'s',
      );
      expect(call.controller.state.rejoining, isTrue);

      unreadable = false;
      async.elapse(delays.last);
      async.flushMicrotasks();

      expect(call.session.joins, 1);
      expect(call.controller.state.rejoining, isFalse);
      expect(
        call.controller.state.error,
        VoiceDisconnect.replacedByOtherDevice.message,
      );
    });
  });

  test(
    'a room read on the second ask lets this device\'s own reconnect back',
    () {
      fakeAsync((async) {
        var unreadable = true;
        final call = inCallThenBlamed(
          async,
          voiceApi(
            listedOnThisDevice: true,
            rosterUnreadable: () => unreadable,
          ),
        );
        async.elapse(delays.first);
        async.flushMicrotasks();
        expect(call.session.joins, 1);

        unreadable = false;
        async.elapse(delays.last);
        async.flushMicrotasks();

        expect(call.session.joins, 2);
        expect(call.controller.state.state, VoiceSessionState.connected);
      });
    },
  );

  test('a room nobody could read stops asking with a way to try by hand', () {
    fakeAsync((async) {
      final call = inCallThenBlamed(
        async,
        voiceApi(rosterUnreadable: () => true),
      );

      async.elapse(delays.reduce((a, b) => a + b) * 2);
      async.flushMicrotasks();

      expect(call.session.joins, 1);
      expect(call.controller.state.rejoining, isFalse);
      expect(call.controller.state.state, VoiceSessionState.failed);
      expect(call.controller.state.retryable, isTrue);
      expect(
        call.controller.state.error,
        VoiceDisconnect.connectionLost.message,
      );
    });
  });

  Iterable<http.Request> tokenAsks(List<http.Request> seen) =>
      seen.where((r) => r.url.path.endsWith('/voice/token'));

  test('a comeback gives way to a call the account made since', () {
    fakeAsync((async) {
      final seen = <http.Request>[];
      final call = inCallThenBlamed(
        async,
        voiceApi(refuseComeback: true, onRequest: seen.add),
        drop: VoiceDisconnect.connectionLost,
      );
      expect(call.controller.state.rejoining, isTrue);
      expect(
        tokenAsks(seen).single.url.queryParameters,
        isNot(contains('automatic')),
        reason: 'a person\'s own join moves the call, so it is never refused',
      );

      async.elapse(delays.reduce((a, b) => a + b) * 2);
      async.flushMicrotasks();

      expect(tokenAsks(seen), hasLength(2), reason: 'refused once is refused');
      expect(tokenAsks(seen).last.url.queryParameters['automatic'], 'true');
      expect(call.session.joins, 1);
      expect(call.controller.state.rejoining, isFalse);
      expect(call.controller.state.state, VoiceSessionState.failed);
      expect(call.controller.state.error, VoiceRejoin.onCallElsewhere);
      expect(
        call.controller.state.retryable,
        isTrue,
        reason: 'moving the call back here is the person\'s to choose',
      );

      unawaited(call.controller.leave());
      async.flushMicrotasks();
      expect(forgets(seen), 0, reason: 'the call on record is not this one');
    });
  });

  test('a person can still move the call back after a refused comeback', () {
    fakeAsync((async) {
      final call = inCallThenBlamed(
        async,
        voiceApi(refuseComeback: true),
        drop: VoiceDisconnect.connectionLost,
      );
      async.elapse(delays.first);
      async.flushMicrotasks();
      expect(call.session.joins, 1);

      unawaited(call.controller.join('channel-1'));
      async.flushMicrotasks();

      expect(call.session.joins, 2);
      expect(call.controller.state.state, VoiceSessionState.connected);
      expect(call.controller.state.error, isNull);
    });
  });
}
