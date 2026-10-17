// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call the network took away comes back on its own.
///
/// LiveKit retries a dropped connection on its own schedule and then stops
/// (ten attempts over 44 seconds, `defaultRetryDelaysInMs` in
/// livekit_client 2.10.0). Before this, that was the end of the call: the
/// controller went to `failed`, the heartbeat stopped, and the only way back
/// in was the manual "Try again" on `VoiceRejoinScreen`. Somebody whose phone
/// changed network in a lift had to notice and tap.
///
/// Driven through `fake_async` for the reason `voice_call_heartbeat_test.dart`
/// gives: a real timer at a few milliseconds is schedulable flake on a loaded
/// runner, and fake time makes each assertion below exact.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_auto_rejoin.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

/// A session that reports the outcome of a join the way a real one does, on
/// the state stream, so an automatic attempt is observable as a reconnection
/// rather than only as a method call.
class _RejoiningSession extends FakeSession {
  int joins = 0;

  /// Whether the next join finds the network back. A test flips this to model
  /// an outage that outlasted the attempts.
  bool connects = true;

  @override
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
  }) async {
    joins++;
    // The real join clears this; keeping it would leak a stale reason into the next drop.
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

  const delays = [Duration(seconds: 2), Duration(seconds: 5)];
  final wholeBudget =
      delays.reduce((a, b) => a + b) + const Duration(seconds: 1);

  test('a call the network took comes back without anybody tapping', () {
    fakeAsync((async) {
      final session = _RejoiningSession();
      final controller = harness.controllerWith(
        session,
        voiceApi(),
        autoRejoinDelays: delays,
      );

      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();
      expect(controller.state.state, VoiceSessionState.connected);
      expect(session.joins, 1);

      session.dropWith(VoiceDisconnect.connectionLost);
      async.flushMicrotasks();
      expect(
        controller.state.rejoining,
        isTrue,
        reason:
            'the screen has to say it is reconnecting, not that the call '
            'is over and waiting on a tap',
      );
      expect(
        session.joins,
        1,
        reason:
            'the first attempt waits out a delay; an instant retry would '
            'land inside the same outage that just dropped us',
      );

      async.elapse(delays.first);
      async.flushMicrotasks();
      expect(session.joins, 2);
      expect(controller.state.state, VoiceSessionState.connected);
      expect(controller.state.rejoining, isFalse);
    });
  });

  test('the attempts run out and hand the call back to the person', () {
    fakeAsync((async) {
      final session = _RejoiningSession();
      final controller = harness.controllerWith(
        session,
        voiceApi(),
        autoRejoinDelays: delays,
      );

      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();
      session.connects = false;
      session.dropWith(VoiceDisconnect.connectionLost);
      async.flushMicrotasks();

      async.elapse(wholeBudget);
      async.flushMicrotasks();
      expect(
        session.joins,
        1 + delays.length,
        reason:
            'two attempts is what the budget bought; nothing here retries '
            'an outage forever',
      );
      expect(
        controller.state.rejoining,
        isFalse,
        reason:
            'once it has given up, the manual Try again is the only honest '
            'thing to leave on screen',
      );
      expect(controller.state.state, VoiceSessionState.failed);
    });
  });

  test('an outage of a few minutes still ends in a rejoin, untapped', () {
    fakeAsync((async) {
      final session = _RejoiningSession();
      final controller = harness.controllerWith(session, voiceApi());

      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();
      session.connects = false;
      session.dropWith(VoiceDisconnect.connectionLost);
      async.flushMicrotasks();

      async.elapse(const Duration(minutes: 3));
      async.flushMicrotasks();
      expect(controller.state.state, VoiceSessionState.failed);
      expect(
        controller.state.rejoining,
        isTrue,
        reason: 'three minutes offline is inside the window, not the end of it',
      );

      session.connects = true;
      async.elapse(const Duration(seconds: 31));
      async.flushMicrotasks();
      expect(controller.state.state, VoiceSessionState.connected);
      expect(controller.state.rejoining, isFalse);
    });
  });

  test('a device that answered somewhere else is not dragged back', () {
    fakeAsync((async) {
      final session = _RejoiningSession();
      final controller = harness.controllerWith(
        session,
        voiceApi(),
        autoRejoinDelays: delays,
      );

      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();
      session.dropWith(VoiceDisconnect.replacedByOtherDevice);
      async.flushMicrotasks();
      async.elapse(wholeBudget);
      async.flushMicrotasks();

      expect(
        session.joins,
        1,
        reason:
            'answering on another device is a decision, and rejoining '
            'would have two of one person fighting over the room',
      );
      expect(controller.state.rejoining, isFalse);
    });
  });

  test('a call the server removed is not rejoined either', () {
    fakeAsync((async) {
      final session = _RejoiningSession();
      final controller = harness.controllerWith(
        session,
        voiceApi(),
        autoRejoinDelays: delays,
      );

      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();
      session.dropWith(VoiceDisconnect.removed);
      async.flushMicrotasks();
      async.elapse(wholeBudget);
      async.flushMicrotasks();

      expect(
        session.joins,
        1,
        reason: 'being removed is an answer, not a question to retry',
      );
    });
  });

  test(
    'a removal that arrives after the heartbeat has been failing is rejoined',
    () {
      fakeAsync((async) {
        const heartbeatInterval = Duration(seconds: 15);
        final epoch = DateTime(2026, 1, 1, 12);
        final session = _RejoiningSession();
        final controller = harness.controllerWith(
          session,
          voiceApi(failHeartbeat: true),
          voiceHeartbeatInterval: heartbeatInterval,
          autoRejoinDelays: delays,
          // Ties isLagging's clock to the one async.elapse actually drives.
          now: () => epoch.add(async.elapsed),
        );

        unawaited(controller.join('channel-1'));
        async.flushMicrotasks();
        expect(controller.state.state, VoiceSessionState.connected);

        // Heartbeats fail while the media transport never moves - distinct from the transport-loss scenarios above.
        async.elapse(heartbeatInterval * 2 + const Duration(seconds: 1));
        async.flushMicrotasks();

        session.dropWith(VoiceDisconnect.removed);
        async.flushMicrotasks();

        expect(
          controller.state.rejoining,
          isTrue,
          reason:
              'a removed reason that arrives on top of a lagging heartbeat '
              'is the stale-heartbeat sweep, not a moderator, so it must '
              'auto-rejoin the same way a lost connection does',
        );
        expect(
          controller.state.error,
          contains('Reconnecting'),
          reason: 'the copy must not read as a moderator kick',
        );

        async.elapse(delays.first);
        async.flushMicrotasks();
        expect(session.joins, 2);
      });
    },
  );

  test(
    'a removal with a healthy heartbeat is not rejoined even right after connecting',
    () {
      fakeAsync((async) {
        final session = _RejoiningSession();
        final controller = harness.controllerWith(
          session,
          voiceApi(),
          autoRejoinDelays: delays,
        );

        unawaited(controller.join('channel-1'));
        async.flushMicrotasks();
        session.dropWith(VoiceDisconnect.removed);
        async.flushMicrotasks();
        async.elapse(wholeBudget);
        async.flushMicrotasks();

        expect(
          session.joins,
          1,
          reason:
              'a healthy heartbeat means this was a real removal, not the '
              'sweep, even though the drop landed moments after connecting',
        );
      });
    },
  );

  /// The narrow case `join`'s own `cancelPending` is for.
  ///
  /// A manual rejoin that *succeeds* does not need it: reaching `connected`
  /// calls `reset()`, which cancels the queued timer on its way past. The line
  /// earns its place only when the manual attempt fails, where without it the
  /// old timer still fires afterwards and starts an automatic attempt the
  /// person's own failed one was supposed to have replaced.
  test('a failed manual rejoin is not followed by the queued attempt', () {
    fakeAsync((async) {
      final session = _RejoiningSession();
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

      // The person taps Try again before the timer fires, and it fails too.
      session.connects = false;
      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();
      expect(session.joins, 2);
      expect(controller.state.state, VoiceSessionState.failed);
      expect(
        controller.state.rejoining,
        isFalse,
        reason:
            'their own attempt replaced the queued one, so the screen must not '
            'claim to be reconnecting on the strength of a dead timer',
      );

      async.elapse(wholeBudget);
      async.flushMicrotasks();
      expect(
        session.joins,
        2,
        reason:
            'the queued attempt belonged to the call this join replaced; its '
            'only other guard is the channel id, unchanged here',
      );
    });
  });

  test('a hang-up while an attempt is queued stays hung up', () {
    fakeAsync((async) {
      final session = _RejoiningSession();
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

      unawaited(controller.leave());
      async.flushMicrotasks();
      async.elapse(wholeBudget);
      async.flushMicrotasks();

      expect(
        session.joins,
        1,
        reason:
            'hanging up during the wait is the person saying they are '
            'done; a queued attempt must not overrule that',
      );
      expect(controller.state.channelId, isNull);
      expect(controller.state.rejoining, isFalse);
    });
  });

  test('reset restores the full budget', () {
    fakeAsync((async) {
      final rejoin = VoiceAutoRejoin(
        delays: const [Duration(seconds: 1), Duration(seconds: 2)],
      );
      expect(rejoin.schedule(() {}), isTrue);
      expect(rejoin.schedule(() {}), isTrue);
      expect(rejoin.schedule(() {}), isFalse, reason: 'budget is spent');

      rejoin.reset();

      expect(rejoin.schedule(() {}), isTrue);
      expect(rejoin.schedule(() {}), isTrue);
      expect(rejoin.schedule(() {}), isFalse);
      rejoin.reset();
    });
  });
}
