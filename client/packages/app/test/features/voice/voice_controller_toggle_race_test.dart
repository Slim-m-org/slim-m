// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A mute whose SFU round trip outlives the call it was asked in.
///
/// `join` and `leave` are generation-guarded so a stale continuation never
/// writes into a newer call's state (see `voice_controller_leave_race_test.dart`).
/// The mid-call toggles awaited the session too but wrote back unguarded, so a
/// mute that stalled while the person hung up and joined another channel
/// landed on the new call - claiming a microphone state that call's session
/// had never been asked for.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

void main() {
  final harness = VoiceHarness();

  tearDown(harness.dispose);

  test('a mute that lands after a hang-up and rejoin does not write into the '
      'new call', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());

    await controller.join('chan-1');
    session.emitState(VoiceSessionState.connected);
    await pumpEventQueue();
    final wasEnabled = controller.state.microphoneEnabled;

    // The mute starts and stalls inside the SFU round trip.
    final roundTrip = Completer<void>();
    session.microphoneGate = roundTrip;
    final muting = controller.toggleMicrophone();
    await pumpEventQueue();

    // The person hangs up and joins another channel before it returns.
    await controller.leave();
    session.microphoneGate = null;
    await controller.join('chan-2');
    session.emitState(VoiceSessionState.connected);
    await pumpEventQueue();
    expect(controller.state.channelId, 'chan-2');
    final established = controller.state.microphoneEnabled;

    roundTrip.complete();
    await muting;
    await pumpEventQueue();

    expect(
      controller.state.microphoneEnabled,
      established,
      reason: 'the superseded mute belongs to the first call, not this one',
    );
    expect(controller.state.error, isNull);
    expect(controller.state.channelId, 'chan-2');
    expect(
      established,
      wasEnabled,
      reason:
          'the rejoined call carries the preference the stalled mute '
          'had not yet changed, so a late write would visibly flip it',
    );
  });
}
