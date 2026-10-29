// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for what happens once a call is live: toggling the microphone, the
/// camera, screen sharing, and deafening, plus leaving.
///
/// Split out of `voice_controller_test.dart`, which sat at this repo's
/// 500-line hard ceiling before the camera-refusal diagnostics grew it past
/// it; joining a call (the token round trip, the insecure-scheme refusal)
/// stays there. Both share a harness.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

import 'features/voice/voice_controller_harness.dart';

const _me = VoiceParticipant(
  identity: 'user-1',
  name: 'Me',
  isLocal: true,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: false,
);

const _alice = VoiceParticipant(
  identity: 'user-2',
  name: 'Alice',
  isLocal: false,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: false,
);

void main() {
  final harness = VoiceHarness();

  tearDown(harness.dispose);

  test('a refused microphone leaves the button where it was', () async {
    final session = FakeSession(microphoneGranted: false);
    final controller = harness.controllerWith(session, voiceApi());

    await controller.join('channel-1');
    expect(controller.state.microphoneEnabled, isTrue);

    await controller.toggleMicrophone();

    // The SFU refused, so the button must not claim the microphone is muted.
    expect(controller.state.microphoneEnabled, isTrue);
    expect(controller.state.error, isNotNull);
  });

  test('a granted microphone toggle clears the previous error', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());

    await controller.join('channel-1');
    await controller.share.setScreenShare(true);
    await controller.toggleMicrophone();

    expect(controller.state.microphoneEnabled, isFalse);
    expect(controller.state.error, isNull);
  });

  test('toggling the camera mid-call reaches the session', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());

    await controller.join('channel-1');
    expect(controller.state.cameraEnabled, isFalse);

    await controller.toggleCamera();

    expect(controller.state.cameraEnabled, isTrue);
    expect(session.askedForCameraOnToggle, isTrue);
  });

  test('a refused camera toggle leaves the button where it was', () async {
    final session = FakeSession(cameraGranted: false);
    final controller = harness.controllerWith(session, voiceApi());

    await controller.join('channel-1');
    await controller.toggleCamera();

    // The SFU refused, so the button must not claim the camera turned on.
    expect(controller.state.cameraEnabled, isFalse);
    expect(controller.state.error, isNotNull);
  });

  test(
    'a refused camera toggle surfaces why, not just that, and logs it',
    () async {
      final session = FakeSession(cameraGranted: false);
      final controller = harness.controllerWith(session, voiceApi());

      await controller.join('channel-1');
      await controller.toggleCamera();

      expect(controller.state.error, contains('no camera device found'));
      expect(
        harness
            .log(controller)
            .any((e) => e.detail == 'no camera device found'),
        isTrue,
        reason: 'the cause must reach the debug log, not only the screen',
      );
    },
  );

  test(
    'no camera detected reads as absence, not as a generic refusal',
    () async {
      final session = FakeSession(
        cameraGranted: false,
        cameraFailureReason: CameraFailureReason.noCameraDetected,
      );
      final controller = harness.controllerWith(session, voiceApi());

      await controller.join('channel-1');
      await controller.toggleCamera();

      expect(
        controller.state.error,
        'No camera detected. Check that one is connected.',
      );
    },
  );

  test(
    'a denied camera permission names the permission, not the device',
    () async {
      final session = FakeSession(
        cameraGranted: false,
        cameraFailureReason: CameraFailureReason.permissionDenied,
      );
      final controller = harness.controllerWith(session, voiceApi());

      await controller.join('channel-1');
      await controller.toggleCamera();

      expect(
        controller.state.error,
        'Camera access was denied. Check your camera permission for this app.',
      );
    },
  );

  test(
    'a camera busy elsewhere is reported as unavailable, not absent',
    () async {
      final session = FakeSession(
        cameraGranted: false,
        cameraFailureReason: CameraFailureReason.cameraUnavailable,
      );
      final controller = harness.controllerWith(session, voiceApi());

      await controller.join('channel-1');
      await controller.toggleCamera();

      expect(
        controller.state.error,
        'The camera could not be opened. It may be in use by another app.',
      );
    },
  );

  test(
    'a camera failing to turn off never claims no camera was detected',
    () async {
      // The camera was already on, so "no camera" cannot apply here.
      final session = FakeSession(
        cameraGranted: false,
        cameraFailureReason: CameraFailureReason.noCameraDetected,
      );
      final controller = harness.controllerWith(session, voiceApi());
      controller.setCameraPreference(true);

      await controller.join('channel-1');
      await controller.toggleCamera();

      expect(controller.state.error, contains('Could not turn the camera off'));
    },
  );

  test(
    'a desktop that refuses the capture is reported, not shown as sharing',
    () async {
      final session = FakeSession(
        screenShareOutcome: ScreenShareOutcome.failed,
      );
      final controller = harness.controllerWith(session, voiceApi());

      await controller.join('channel-1');
      await controller.share.setScreenShare(true);

      expect(controller.state.screenSharing, isFalse);
      expect(controller.state.error, contains('Could not start sharing'));
    },
  );

  test('the session decides who is sharing, not the local toggle', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());

    await controller.join('channel-1');
    await controller.share.setScreenShare(true);
    expect(controller.state.screenSharing, isTrue);

    // The SFU drops the track without the local toggle changing.
    session.emitParticipants(const [
      VoiceParticipant(
        identity: 'user-1',
        name: 'me',
        isLocal: true,
        isSpeaking: false,
        isMuted: false,
        isScreenSharing: false,
      ),
    ]);
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.screenSharing, isFalse);
  });

  test('deafening reflects what the session actually did', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());

    await controller.join('channel-1');
    expect(controller.state.deafened, isFalse);

    await controller.toggleDeafen();
    expect(controller.state.deafened, isTrue);

    await controller.toggleDeafen();
    expect(controller.state.deafened, isFalse);
  });

  test('a session that cannot deafen leaves the button where it was', () async {
    final session = FakeSession(deafenGranted: false);
    final controller = harness.controllerWith(session, voiceApi());

    await controller.join('channel-1');
    await controller.toggleDeafen();

    expect(controller.state.deafened, isFalse);
    expect(controller.state.error, isNotNull);
  });

  test('leaving forgets the call entirely', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());

    await controller.join('channel-1');
    expect(controller.state.channelId, 'channel-1');

    await controller.leave();

    expect(session.leaveCalls, 1);
    expect(controller.state.channelId, isNull);
    expect(controller.state.state, VoiceSessionState.idle);
  });

  /// Since a voice channel now joins on arrival rather than behind a lobby
  /// with its own pre-toggles (see `voice_screen.dart`), the only place left
  /// to set "join muted" is whatever was last chosen mid-call - so leaving
  /// must not reset it back to the defaults.
  test(
    'leaving preserves the mic and camera preference for the next join',
    () async {
      final session = FakeSession();
      final controller = harness.controllerWith(session, voiceApi());

      await controller.join('channel-1');
      await controller.toggleMicrophone();
      await controller.toggleCamera();
      expect(controller.state.microphoneEnabled, isFalse);
      expect(controller.state.cameraEnabled, isTrue);

      await controller.leave();

      expect(controller.state.microphoneEnabled, isFalse);
      expect(controller.state.cameraEnabled, isTrue);
    },
  );

  test('a drop the SFU decided on is reported, not silently idle', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');

    session.dropWith(VoiceDisconnect.replacedByOtherDevice);
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.state, VoiceSessionState.failed);
    expect(
      controller.state.error,
      VoiceDisconnect.replacedByOtherDevice.message,
    );
  });

  test('a screen share failure carries the cause, not just a shrug', () async {
    final session = FakeSession(screenShareOutcome: ScreenShareOutcome.failed);
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');

    await controller.share.setScreenShare(true);

    // Dropping this is what left the real Linux failure invisible.
    expect(controller.state.error, contains('source not found!'));
    expect(
      harness.log(controller).map((e) => e.message),
      contains(contains('Could not start the screen share')),
    );
  });

  test('a chosen screen reaches the session', () async {
    final session = FakeSession(
      needsSource: true,
      sources: const [ScreenShareSource(id: 'screen-2', name: 'Screen 2')],
    );
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');

    expect(controller.video.screenShareNeedsSource, isTrue);
    final sources = await controller.video.screenShareSources();
    await controller.share.setScreenShare(true, sourceId: sources.first.id);

    expect(session.lastSourceId, 'screen-2');
  });

  test(
    'a request for screen share audio reaches a session that supports it',
    () async {
      final session = FakeSession(supportsScreenShareAudio: true);
      final controller = harness.controllerWith(session, voiceApi());
      await controller.join('channel-1');

      await controller.share.setScreenShare(true, includeAudio: true);

      expect(session.screenShareAudioCalls, [true]);
    },
  );

  test(
    'a request for screen share audio is dropped on a session that cannot',
    () async {
      final session = FakeSession(supportsScreenShareAudio: false);
      final controller = harness.controllerWith(session, voiceApi());
      await controller.join('channel-1');

      await controller.share.setScreenShare(true, includeAudio: true);

      // See VoiceController.setScreenShare's own guard against exactly this.
      expect(session.screenShareAudioCalls, [false]);
    },
  );

  group('the call recap leave() leaves behind', () {
    test('a real call with someone else in it produces a recap', () async {
      var now = DateTime(2026, 1, 1, 12);
      final session = FakeSession();
      final controller = harness.controllerWith(
        session,
        voiceApi(),
        now: () => now,
      );

      await controller.join('channel-1');
      session.emitState(VoiceSessionState.connected);
      await Future<void>.delayed(Duration.zero);
      session.emitParticipants(const [_me, _alice]);
      await Future<void>.delayed(Duration.zero);

      now = now.add(const Duration(minutes: 6));
      await controller.leave();

      final recap = controller.state.recap;
      expect(recap, isNotNull);
      expect(recap!.channelId, 'channel-1');
      expect(recap.duration, const Duration(minutes: 6));
      expect(recap.others.single.name, 'Alice');
      expect(recap.isWorthShowing, isTrue);
    });

    test(
      'someone who left before you hang up is recorded, not dropped',
      () async {
        var now = DateTime(2026, 1, 1, 12);
        final session = FakeSession();
        final controller = harness.controllerWith(
          session,
          voiceApi(),
          now: () => now,
        );

        await controller.join('channel-1');
        session.emitState(VoiceSessionState.connected);
        await Future<void>.delayed(Duration.zero);
        session.emitParticipants(const [_me, _alice]);
        await Future<void>.delayed(Duration.zero);
        now = now.add(const Duration(minutes: 1));
        session.emitParticipants(const [_me]);
        await Future<void>.delayed(Duration.zero);

        now = now.add(const Duration(minutes: 1));
        await controller.leave();

        final person = controller.state.recap!.others.single;
        expect(person.name, 'Alice');
        expect(
          person.leftAt,
          isNotNull,
          reason: 'Alice hung up a minute before this device did',
        );
      },
    );

    test('a call spent entirely alone still reports its duration', () async {
      var now = DateTime(2026, 1, 1, 12);
      final session = FakeSession();
      final controller = harness.controllerWith(
        session,
        voiceApi(),
        now: () => now,
      );

      await controller.join('channel-1');
      session.emitState(VoiceSessionState.connected);
      await Future<void>.delayed(Duration.zero);
      session.emitParticipants(const [_me]);
      await Future<void>.delayed(Duration.zero);

      now = now.add(const Duration(minutes: 5));
      await controller.leave();

      final recap = controller.state.recap;
      expect(recap, isNotNull);
      expect(recap!.wasAlone, isTrue);
      expect(
        recap.isWorthShowing,
        isTrue,
        reason:
            'a solo test of the call itself, or of screen share or '
            'camera, is still a real use worth reporting on',
      );
    });

    test("joining again clears the previous call's recap", () async {
      var now = DateTime(2026, 1, 1, 12);
      final session = FakeSession();
      final controller = harness.controllerWith(
        session,
        voiceApi(),
        now: () => now,
      );

      await controller.join('channel-1');
      session.emitState(VoiceSessionState.connected);
      await Future<void>.delayed(Duration.zero);
      session.emitParticipants(const [_me, _alice]);
      await Future<void>.delayed(Duration.zero);
      now = now.add(const Duration(minutes: 2));
      await controller.leave();
      expect(controller.state.recap, isNotNull);

      await controller.join('channel-2');

      expect(
        controller.state.recap,
        isNull,
        reason: "a fresh join must not carry the previous call's recap forward",
      );
    });
  });
}
