// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call dock's switch for a running share's audio: silencing it must not end the share.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_state.dart';

import 'features/voice/voice_controller_harness.dart';

void main() {
  final harness = VoiceHarness();

  tearDown(harness.dispose);

  test('a share that carries audio starts with it on', () async {
    final session = FakeSession()..shareHasAudio = true;
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');

    await controller.setScreenShare(true, includeAudio: true);

    expect(controller.state.shareAudio, ShareAudio.on);
  });

  test('a share with no audio track has nothing to switch', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');

    await controller.setScreenShare(true);
    await controller.setScreenShareAudioOn(false);

    expect(controller.state.shareAudio, ShareAudio.none);
    expect(session.shareAudioMuted, isFalse);
  });

  test('switching it off silences the audio and keeps the share', () async {
    final session = FakeSession()..shareHasAudio = true;
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');
    await controller.setScreenShare(true, includeAudio: true);

    await controller.setScreenShareAudioOn(false);

    expect(session.shareAudioMuted, isTrue);
    expect(controller.state.shareAudio, ShareAudio.muted);
    expect(controller.state.screenSharing, isTrue);
    expect(session.screenShareAudioCalls, [true], reason: 'no restart');
  });

  test('switching it back on restores the audio', () async {
    final session = FakeSession()..shareHasAudio = true;
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');
    await controller.setScreenShare(true, includeAudio: true);
    await controller.setScreenShareAudioOn(false);

    await controller.setScreenShareAudioOn(true);

    expect(session.shareAudioMuted, isFalse);
    expect(controller.state.shareAudio, ShareAudio.on);
  });

  test('stopping the share clears the switch', () async {
    final session = FakeSession()..shareHasAudio = true;
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');
    await controller.setScreenShare(true, includeAudio: true);

    await controller.setScreenShare(false);

    expect(controller.state.shareAudio, ShareAudio.none);
  });
}
