// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Hanging up and joining again before the hang-up has finished unwinding.
///
/// `VoiceController.join` has carried a generation guard since PR #487, so an
/// abandoned join cannot write onto the call that superseded it. `leave` had
/// no such guard: it read `state` again after awaiting `VoiceSession.leave()`
/// and reset it unconditionally, so a hang-up whose teardown was still in
/// flight wiped whatever a newer join had already established - leaving a
/// genuinely connected call with no `channelId`, which every voice surface
/// reads as "not in this call" and which the heartbeat needs in order to keep
/// the server's proof of that call alive.
///
/// The gate is on the *session's* `leave`, not on the network, because that is
/// where the real delay is: `room.disconnect()` plus `room.dispose()` is a
/// round trip to the SFU, and nothing in the UI blocks on it - the hang-up
/// button fires and forgets, so the next tap is available immediately.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

void main() {
  final harness = VoiceHarness();

  tearDown(harness.dispose);

  test('a join that lands while a hang-up is still tearing down keeps its '
      'channel', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());

    await controller.join('chan-1');
    session.emitState(VoiceSessionState.connected);
    await pumpEventQueue();

    // The hang-up starts unwinding and stalls inside the session's teardown.
    final teardown = Completer<void>();
    session.leaveGate = teardown;
    final leaving = controller.leave();
    await pumpEventQueue();

    // The person taps a voice channel again before that teardown finishes.
    session.leaveGate = null;
    await controller.join('chan-2');
    session.emitState(VoiceSessionState.connected);
    await pumpEventQueue();
    expect(controller.state.channelId, 'chan-2');

    teardown.complete();
    await leaving;
    await pumpEventQueue();

    expect(
      controller.state.channelId,
      'chan-2',
      reason: 'the superseded hang-up must not reset the call that replaced it',
    );
    expect(controller.state.state, VoiceSessionState.connected);
  });

  test('a superseded hang-up does not tell the server the call it was '
      'superseded by has ended', () async {
    final forgotten = <String>[];
    final session = FakeSession();
    final controller = harness.controllerWith(
      session,
      voiceApi(
        onRequest: (http.Request request) {
          if (request.method == 'DELETE' &&
              request.url.path.endsWith('/voice/heartbeat')) {
            forgotten.add(request.url.path);
          }
        },
      ),
    );

    await controller.join('chan-1');
    session.emitState(VoiceSessionState.connected);
    await pumpEventQueue();

    final teardown = Completer<void>();
    session.leaveGate = teardown;
    final leaving = controller.leave();
    await pumpEventQueue();

    // Same channel: the server turns a forget it honours into a broadcast hangup.
    session.leaveGate = null;
    await controller.join('chan-1');
    session.emitState(VoiceSessionState.connected);
    await pumpEventQueue();

    teardown.complete();
    await leaving;
    await pumpEventQueue();

    expect(
      forgotten,
      isEmpty,
      reason:
          'the rejoined call is live, so nothing may report it as hung up; '
          'the abandoned entry is what the staleness sweep is for',
    );
  });
}
