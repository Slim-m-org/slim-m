// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for [VoiceController.setPushToTalkHeld]: the hold/release mute
/// transitions it drives, with a fake session standing in for a real call.
/// Reaching the key event itself, and the composer-focus guard that keeps a
/// held letter from stealing keystrokes, is `push_to_talk_listener_test.dart`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_rtc/rtc.dart';

import 'features/voice/voice_controller_harness.dart';

void main() {
  final harness = VoiceHarness();

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(harness.dispose);

  test('holding unmutes, and it is not a toggle', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    await pumpEventQueue();

    await controller.setPushToTalkHeld(true);

    expect(controller.state.microphoneEnabled, isTrue);
  });

  test('releasing re-mutes', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    await pumpEventQueue();

    await controller.setPushToTalkHeld(true);
    await controller.setPushToTalkHeld(false);

    expect(controller.state.microphoneEnabled, isFalse);
  });

  test('a refused mic change leaves the reported state unchanged', () async {
    final session = FakeSession(microphoneGranted: false);
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    await pumpEventQueue();
    // The default, unmuted - asking to close it below is what the fake refuses.
    expect(controller.state.microphoneEnabled, isTrue);

    await controller.setPushToTalkHeld(false);

    expect(
      controller.state.microphoneEnabled,
      isTrue,
      reason: 'the button must not claim a change the SFU refused',
    );
  });

  test('held before joining, it never touches the mic - a key pressed early '
      'must not corrupt the pre-join preference', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());
    // From the true default, so a working guard leaves it exactly here.
    await controller.toggleMicrophone();
    expect(controller.state.microphoneEnabled, isFalse);

    await controller.setPushToTalkHeld(true);

    expect(controller.state.state, isNot(VoiceSessionState.connected));
    expect(
      controller.state.microphoneEnabled,
      isFalse,
      reason: 'without the guard this would flip to true',
    );
  });

  test('held after leaving, it never touches the mic either', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    await pumpEventQueue();
    // From the true default, so a working guard leaves it exactly here.
    await controller.toggleMicrophone();
    expect(controller.state.microphoneEnabled, isFalse);
    await controller.leave();

    await controller.setPushToTalkHeld(true);

    expect(
      controller.state.microphoneEnabled,
      isFalse,
      reason:
          'leave() carries the pre-call preference forward untouched, '
          'and a held key after it must not overwrite that',
    );
  });

  test(
    'push-to-talk joins with the mic closed, so it never opens itself',
    () async {
      final session = FakeSession();
      final controller = harness.controllerWith(session, voiceApi());
      controller.setPushToTalkPreference(true);

      await controller.join('channel-1');
      session.emitState(VoiceSessionState.connected);
      await pumpEventQueue();

      expect(
        session.askedForMicrophoneOnJoin,
        isFalse,
        reason: 'push-to-talk must not publish an open mic on join',
      );
      expect(
        controller.state.microphoneEnabled,
        isFalse,
        reason: 'and the button must show the closed mic',
      );
    },
  );

  test('enabling push-to-talk during a call closes the open mic', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    await pumpEventQueue();
    expect(controller.state.microphoneEnabled, isTrue);

    controller.setPushToTalkPreference(true);
    await pumpEventQueue();

    expect(controller.state.microphoneEnabled, isFalse);
  });

  test('disabling push-to-talk during a call reopens the mic', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());
    controller.setPushToTalkPreference(true);
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    await pumpEventQueue();
    expect(controller.state.microphoneEnabled, isFalse);

    controller.setPushToTalkPreference(false);
    await pumpEventQueue();

    expect(
      controller.state.microphoneEnabled,
      isTrue,
      reason: 'leaving push-to-talk returns to an open mic, Discord-style',
    );
  });
}
