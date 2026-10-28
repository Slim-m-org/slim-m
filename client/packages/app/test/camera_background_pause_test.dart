// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/camera_background_pause.dart';
import 'package:slimm_app/src/features/voice/providers/video_pause.dart';

class _Camera {
  bool on = true;
  final calls = <bool>[];

  Future<bool> set(bool want) async {
    calls.add(want);
    on = want;
    return true;
  }
}

CameraBackgroundPause _pause(_Camera c) =>
    CameraBackgroundPause(cameraOn: () => c.on, setCamera: c.set);

void main() {
  group('CameraBackgroundPause', () {
    test('turns the camera off in the background and back on after', () async {
      final cam = _Camera();
      final pause = _pause(cam);
      await pause.apply(paused: true);
      expect(cam.on, isFalse);
      await pause.apply(paused: false);
      expect(cam.on, isTrue);
      expect(cam.calls, [false, true]);
    });

    test('leaves a camera the user had off alone', () async {
      final cam = _Camera()..on = false;
      final pause = _pause(cam);
      await pause.apply(paused: true);
      await pause.apply(paused: false);
      expect(cam.calls, isEmpty);
    });

    test('does not resume a camera it did not pause', () async {
      final cam = _Camera();
      final pause = _pause(cam);
      await pause.apply(paused: false);
      expect(cam.calls, isEmpty);
    });

    test('forgets a pause when the call ends', () async {
      final cam = _Camera();
      final pause = _pause(cam);
      await pause.apply(paused: true);
      pause.forget();
      await pause.apply(paused: false);
      expect(cam.calls, [false]);
    });

    test('a quick background and return ends with the camera on', () async {
      final cam = _Camera();
      final pause = _pause(cam);
      final a = pause.apply(paused: true);
      final b = pause.apply(paused: false);
      await Future.wait([a, b]);
      expect(cam.on, isTrue);
    });

    test('a refused pause is not resumed later', () async {
      final calls = <bool>[];
      final pause = CameraBackgroundPause(
        cameraOn: () => true,
        setCamera: (on) async {
          calls.add(on);
          return false;
        },
      );
      await pause.apply(paused: true);
      await pause.apply(paused: false);
      expect(calls, [false]);
    });
  });

  group('cameraBackgroundPausedProvider', () {
    ProviderContainer container({
      required bool previewPaused,
      required bool desktop,
    }) {
      final c = ProviderContainer(
        overrides: [
          localPreviewPausedProvider.overrideWithValue(previewPaused),
          pauseOnUnfocusedAppliesProvider.overrideWithValue(desktop),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('a backgrounded phone pauses', () {
      final c = container(previewPaused: true, desktop: false);
      expect(c.read(cameraBackgroundPausedProvider), isTrue);
    });

    test('a minimised desktop keeps publishing', () {
      final c = container(previewPaused: true, desktop: true);
      expect(c.read(cameraBackgroundPausedProvider), isFalse);
    });

    test('a phone in the foreground keeps publishing', () {
      final c = container(previewPaused: false, desktop: false);
      expect(c.read(cameraBackgroundPausedProvider), isFalse);
    });
  });
}
