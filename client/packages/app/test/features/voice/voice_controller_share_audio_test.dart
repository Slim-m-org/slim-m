// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call dock's switch for a running share's audio: silencing it must not end the share.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart' show shareAudioNote, shareAudioOffNote;
import 'package:slimm_app/src/features/voice/providers/voice_state.dart';

import 'voice_controller_harness.dart';

void main() {
  final harness = VoiceHarness();

  tearDown(harness.dispose);

  test('a share that carries audio starts with it on', () async {
    final session = FakeSession()..shareHasAudio = true;
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');

    await controller.share.setScreenShare(true, includeAudio: true);

    expect(controller.state.shareAudio, ShareAudio.on);
  });

  test('a share with no audio track has nothing to switch', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');

    await controller.share.setScreenShare(true);
    await controller.share.setScreenShareAudioOn(false);

    expect(controller.state.shareAudio, ShareAudio.none);
    expect(session.shareAudioMuted, isFalse);
  });

  test('switching it off silences the audio and keeps the share', () async {
    final session = FakeSession()..shareHasAudio = true;
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');
    await controller.share.setScreenShare(true, includeAudio: true);

    await controller.share.setScreenShareAudioOn(false);

    expect(session.shareAudioMuted, isTrue);
    expect(controller.state.shareAudio, ShareAudio.muted);
    expect(controller.state.screenSharing, isTrue);
    expect(session.screenShareAudioCalls, [true], reason: 'no restart');
  });

  test('switching it back on restores the audio', () async {
    final session = FakeSession()..shareHasAudio = true;
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');
    await controller.share.setScreenShare(true, includeAudio: true);
    await controller.share.setScreenShareAudioOn(false);

    await controller.share.setScreenShareAudioOn(true);

    expect(session.shareAudioMuted, isFalse);
    expect(controller.state.shareAudio, ShareAudio.on);
  });

  test('stopping the share clears the switch', () async {
    final session = FakeSession()..shareHasAudio = true;
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');
    await controller.share.setScreenShare(true, includeAudio: true);

    await controller.share.setScreenShare(false);

    expect(controller.state.shareAudio, ShareAudio.none);
  });

  group('a share that dropped its audio', () {
    tearDown(() => shareAudioNote.value = null);

    test('says so in the call error and keeps sharing', () async {
      final session = FakeSession();
      final controller = harness.controllerWith(session, voiceApi());
      await controller.join('channel-1');
      shareAudioNote.value = shareAudioOffNote;

      await controller.share.setScreenShare(true, includeAudio: true);

      expect(controller.state.screenSharing, isTrue);
      expect(
        controller.state.error,
        'Share audio is off: PipeWire tools not found',
      );
      expect(controller.state.retryable, isFalse);
    });

    test('a share that kept its audio shows no note', () async {
      final session = FakeSession()..shareHasAudio = true;
      final controller = harness.controllerWith(session, voiceApi());
      await controller.join('channel-1');

      await controller.share.setScreenShare(true, includeAudio: true);

      expect(controller.state.error, isNull);
    });
  });
}
