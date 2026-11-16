// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call that comes back, on its own or by "Try again", comes back with the
/// microphone as the person left it: muted stays muted.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/voice_move_follower.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

/// Reports each join's outcome on the state stream, as a real session does.
class _RejoiningSession extends FakeSession {
  final micAtJoin = <bool>[];
  bool connects = true;

  @override
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
    bool canPublish = true,
  }) async {
    micAtJoin.add(microphoneEnabled);
    lastDisconnect = null;
    await super.join(
      url: url,
      token: token,
      microphoneEnabled: microphoneEnabled,
      cameraEnabled: cameraEnabled,
    );
    emitState(
      connects ? VoiceSessionState.connected : VoiceSessionState.failed,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final harness = VoiceHarness();

  tearDown(harness.dispose);

  const delays = [Duration(seconds: 2)];

  test('a call joined muted comes back muted after the network took it', () {
    fakeAsync((async) {
      final session = _RejoiningSession();
      final controller = harness.controllerWith(
        session,
        voiceApi(),
        autoRejoinDelays: delays,
      );

      unawaited(controller.joinMuted('channel-1'));
      async.flushMicrotasks();
      expect(session.micAtJoin, [false]);

      session.dropWith(VoiceDisconnect.connectionLost);
      async.flushMicrotasks();
      async.elapse(delays.first);
      async.flushMicrotasks();

      expect(session.micAtJoin, [
        false,
        false,
      ], reason: 'nobody unmuted, so the rejoin must not open the microphone');
      expect(controller.state.microphoneEnabled, isFalse);
    });
  });

  test(
    'muting again after unmuting a call joined muted survives the rejoin',
    () {
      fakeAsync((async) {
        final session = _RejoiningSession();
        final controller = harness.controllerWith(
          session,
          voiceApi(),
          autoRejoinDelays: delays,
        );

        unawaited(controller.joinMuted('channel-1'));
        async.flushMicrotasks();
        unawaited(controller.toggleMicrophone());
        async.flushMicrotasks();
        unawaited(controller.toggleMicrophone());
        async.flushMicrotasks();
        expect(controller.state.microphoneEnabled, isFalse);

        session.dropWith(VoiceDisconnect.connectionLost);
        async.flushMicrotasks();
        async.elapse(delays.first);
        async.flushMicrotasks();

        expect(session.micAtJoin.last, isFalse);
      });
    },
  );

  test(
    '"Try again" on the same channel after the attempts ran out stays muted',
    () {
      fakeAsync((async) {
        final session = _RejoiningSession();
        final controller = harness.controllerWith(
          session,
          voiceApi(),
          autoRejoinDelays: delays,
        );

        unawaited(controller.joinMuted('channel-1'));
        async.flushMicrotasks();
        session.connects = false;
        session.dropWith(VoiceDisconnect.connectionLost);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(controller.state.rejoining, isFalse);

        session.connects = true;
        unawaited(controller.join('channel-1'));
        async.flushMicrotasks();

        expect(session.micAtJoin.last, isFalse);
        expect(controller.state.microphoneEnabled, isFalse);
      });
    },
  );

  test('a muted join that fails is still muted when it is tried again', () {
    fakeAsync((async) {
      final session = _RejoiningSession()..connects = false;
      final controller = harness.controllerWith(
        session,
        voiceApi(),
        autoRejoinDelays: delays,
      );

      unawaited(controller.joinMuted('channel-1'));
      async.flushMicrotasks();
      expect(controller.state.state, VoiceSessionState.failed);

      session.connects = true;
      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();

      expect(session.micAtJoin, [false, false]);
    });
  });

  test('a muted join refused before the call opened is retried muted', () {
    fakeAsync((async) {
      final session = _RejoiningSession();
      var refuse = true;
      final controller = harness.controllerWith(
        session,
        MockClient((request) async {
          final token = request.url.path.endsWith('/voice/token');
          if (token && refuse) return http.Response('', 503);
          if (!token) return http.Response('', 204);
          return http.Response(
            '{"url":"wss://sfu.example.com","room":"r","token":"jwt",'
            '"expires_at":0,"can_publish":true}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        autoRejoinDelays: delays,
      );

      unawaited(controller.joinMuted('channel-1'));
      async.flushMicrotasks();
      expect(controller.state.state, VoiceSessionState.failed);
      expect(session.micAtJoin, isEmpty);

      refuse = false;
      unawaited(controller.join('channel-1'));
      async.elapse(const Duration(seconds: 1));

      expect(session.micAtJoin, [false]);
    });
  });

  test('a moderator moving a muted member does not open their microphone', () {
    fakeAsync((async) {
      final events = StreamController<api.ServerEvent>.broadcast();
      final session = _RejoiningSession();
      final controller = harness.controllerWith(
        session,
        voiceApi(),
        autoRejoinDelays: delays,
        extraOverrides: [liveEventsProvider.overrideWithValue(events.stream)],
      );
      harness.container.read(voiceMoveFollowerProvider);

      unawaited(controller.joinMuted('channel-1'));
      async.flushMicrotasks();
      events.add(
        const api.VoiceMoved(
          fromChannelId: 'channel-1',
          toChannelId: 'channel-2',
          toChannelName: 'Games',
          movedById: 'u',
          movedByName: 'Alice',
        ),
      );
      async.flushMicrotasks();

      expect(controller.state.channelId, 'channel-2');
      expect(session.micAtJoin, [false, false]);
      unawaited(events.close());
    });
  });

  test('the preference from before the muted call returns once it is left', () {
    fakeAsync((async) {
      final session = _RejoiningSession();
      final controller = harness.controllerWith(
        session,
        voiceApi(),
        autoRejoinDelays: delays,
      );

      unawaited(controller.joinMuted('channel-1'));
      async.flushMicrotasks();
      session.dropWith(VoiceDisconnect.connectionLost);
      async.flushMicrotasks();
      async.elapse(delays.first);
      async.flushMicrotasks();

      unawaited(controller.leave());
      async.flushMicrotasks();
      expect(controller.state.microphoneEnabled, isTrue);

      unawaited(controller.join('channel-2'));
      async.flushMicrotasks();
      expect(session.micAtJoin.last, isTrue);
    });
  });
}
