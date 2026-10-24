// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A quality change while sharing or on camera restarts it once, quietly.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/live_quality_restart.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

const _delay = Duration(milliseconds: 30);
const _settle = Duration(milliseconds: 200);

const _screens = [
  ScreenShareSource(id: 'screen-1', name: 'Screen 1'),
  ScreenShareSource(id: 'screen-2', name: 'Screen 2'),
];

void main() {
  final harness = VoiceHarness();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(harness.dispose);

  Future<(VoiceController, VoiceSettingsController, FakeSession)> sharing(
    FakeSession session, {
    bool startShare = true,
  }) async {
    final controller = harness.controllerWith(
      session,
      voiceApi(),
      extraOverrides: [
        liveQualityRestartProvider.overrideWith(
          (ref) => LiveQualityRestart(ref, delay: _delay),
        ),
      ],
    );
    final container = harness.container..read(liveQualityRestartProvider);
    final settings = container.read(voiceSettingsControllerProvider.notifier);
    await Future<void>.delayed(_settle);
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    if (startShare) {
      await controller.setScreenShare(true, sourceId: 'screen-2');
      session.shareCalls.clear();
    }
    return (controller, settings, session);
  }

  FakeSession desktop() => FakeSession(
    needsSource: true,
    sources: _screens,
    sourcePickerUseful: true,
  );

  group('screen share', () {
    test('restarts once with the new options on the same source', () async {
      final (controller, settings, session) = await sharing(desktop());
      await settings.setScreenShareFps(ScreenShareFps.fps60);
      await Future<void>.delayed(_settle);

      expect(session.shareCalls.map((c) => c.enabled), [false, true]);
      final start = session.shareCalls.last;
      expect(start.quality.frameRate, ScreenShareFps.fps60);
      expect(start.sourceId, 'screen-2');
      expect(controller.state.screenSharing, isTrue);
      await controller.leave();
    });

    test('a burst of changes restarts once with the last value', () async {
      final (controller, settings, session) = await sharing(desktop());
      await settings.setScreenShareResolution(ScreenShareResolution.p720);
      await settings.setScreenShareResolution(ScreenShareResolution.p1440);
      await settings.setScreenShareResolution(ScreenShareResolution.p1080);
      await settings.setScreenShareFps(ScreenShareFps.fps15);
      await Future<void>.delayed(_settle);

      expect(session.shareCalls.map((c) => c.enabled), [false, true]);
      expect(
        session.shareCalls.last.quality,
        const ScreenShareQuality(
          ScreenShareResolution.p1080,
          ScreenShareFps.fps15,
        ),
      );
      await controller.leave();
    });

    test('a hang-up while the share stops does not start it again', () async {
      final (controller, settings, session) = await sharing(desktop());
      session.shareStopGate = Completer<void>();
      await settings.setScreenShareFps(ScreenShareFps.fps60);
      await Future<void>.delayed(_settle);
      expect(session.shareCalls.map((c) => c.enabled), [false]);

      await controller.leave();
      session.shareStopGate!.complete();
      await Future<void>.delayed(_settle);

      expect(session.shareCalls.map((c) => c.enabled), [false]);
    });

    test('does nothing after the share has stopped', () async {
      final (controller, settings, session) = await sharing(desktop());
      await controller.setScreenShare(false);
      session.shareCalls.clear();
      await settings.setScreenShareFps(ScreenShareFps.fps60);
      await Future<void>.delayed(_settle);

      expect(session.shareCalls, isEmpty);
      expect(controller.state.screenSharing, isFalse);
      await controller.leave();
    });

    test('restarts when share audio is toggled', () async {
      final (controller, settings, session) = await sharing(desktop());
      await settings.setScreenShareIncludeAudio(true);
      await Future<void>.delayed(_settle);

      expect(session.shareCalls.map((c) => c.enabled), [false, true]);
      expect(session.shareCalls.last.includeAudio, isTrue);
      await controller.leave();
    });

    for (final (name, make) in [
      (
        'wayland',
        () => FakeSession(
          needsSource: true,
          sources: _screens,
          sourcePickerUseful: false,
        ),
      ),
      ('web or mobile', () => FakeSession(needsSource: false)),
    ]) {
      test('$name keeps the share and shows the note', () async {
        final (controller, settings, session) = await sharing(make());
        await settings.setScreenShareFps(ScreenShareFps.fps60);
        await Future<void>.delayed(_settle);

        expect(session.shareCalls, isEmpty);
        expect(controller.state.screenSharing, isTrue);
        expect(harness.container.read(shareSettingsPendingProvider), isTrue);

        await controller.setScreenShare(false);
        await Future<void>.delayed(_settle);
        expect(harness.container.read(shareSettingsPendingProvider), isFalse);
        await controller.leave();
      });
    }

    test(
      'a failed restart leaves the call up with a persistent error',
      () async {
        final (controller, settings, session) = await sharing(desktop());
        session.screenShareOutcome = ScreenShareOutcome.failed;
        await settings.setScreenShareFps(ScreenShareFps.fps60);
        await Future<void>.delayed(_settle);

        expect(controller.state.state, VoiceSessionState.connected);
        expect(controller.state.screenSharing, isFalse);
        expect(controller.state.error, startsWith('Could not start sharing.'));
        await controller.leave();
      },
    );
  });

  group('camera', () {
    test('a quality change with no call joined touches no camera', () async {
      final session = FakeSession();
      final controller = harness.controllerWith(
        session,
        voiceApi(),
        extraOverrides: [
          liveQualityRestartProvider.overrideWith(
            (ref) => LiveQualityRestart(ref, delay: _delay),
          ),
        ],
      );
      final container = harness.container..read(liveQualityRestartProvider);
      final settings = container.read(voiceSettingsControllerProvider.notifier);
      await Future<void>.delayed(_settle);
      controller.setCameraPreference(true);
      await settings.setCameraQuality(CameraQuality.dataSaver);
      await Future<void>.delayed(_settle);

      expect(session.cameraToggles, isEmpty);
      expect(controller.state.error, isNull);
      expect(controller.state.cameraPending, isFalse);
    });

    test('a call change mid-restart neither re-enables nor sticks', () async {
      final (controller, settings, session) = await sharing(
        FakeSession(),
        startShare: false,
      );
      await controller.toggleCamera();
      session.cameraToggles.clear();
      session.cameraGate = Completer<void>();
      await settings.setCameraQuality(CameraQuality.dataSaver);
      await Future<void>.delayed(_settle);
      expect(controller.state.cameraPending, isTrue);

      await controller.join('channel-2');
      session.cameraGate!.complete();
      await Future<void>.delayed(_settle);

      expect(session.cameraToggles, [false]);
      expect(controller.state.cameraPending, isFalse);
      await controller.leave();
    });

    test('cycles a live camera once and keeps the call state', () async {
      final (controller, settings, session) = await sharing(
        FakeSession(),
        startShare: false,
      );
      await controller.toggleMicrophone();
      await controller.toggleCamera();
      session.cameraToggles.clear();
      final muted = controller.state.microphoneEnabled;

      await settings.setCameraQuality(CameraQuality.dataSaver);
      await settings.setCameraQuality(CameraQuality.high);
      await Future<void>.delayed(_settle);

      expect(session.cameraToggles, [false, true]);
      expect(session.lastCameraQuality, CameraQuality.high);
      expect(controller.state.cameraEnabled, isTrue);
      expect(controller.state.cameraPending, isFalse);
      expect(controller.state.microphoneEnabled, muted);
      await controller.leave();
    });

    test('does nothing while the camera is off', () async {
      final (controller, settings, session) = await sharing(
        FakeSession(),
        startShare: false,
      );
      await settings.setCameraQuality(CameraQuality.dataSaver);
      await Future<void>.delayed(_settle);

      expect(session.cameraToggles, isEmpty);
      expect(controller.state.cameraEnabled, isFalse);
      await controller.leave();
    });
  });
}
