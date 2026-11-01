// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Stops publishing the member's own camera while a phone is in the background.
///
/// A backgrounded phone cannot capture, so publishing would only send a frozen
/// or black frame. The camera comes back on its own, and only if this paused it.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import 'video_pause.dart';
import 'voice_controller.dart';
import 'voice_flags.dart';

/// Whether the camera should be off for the window state, on a phone only.
final cameraBackgroundPausedProvider = Provider<bool>(
  (ref) =>
      ref.watch(localPreviewPausedProvider) &&
      !ref.watch(pauseOnUnfocusedAppliesProvider),
);

/// Remembers whether it was the one to turn the camera off.
class CameraBackgroundPause {
  CameraBackgroundPause({required this.cameraOn, required this.setCamera});

  final bool Function() cameraOn;
  final Future<bool> Function(bool on) setCamera;
  bool _pausedByUs = false;
  Future<void> _queue = Future.value();

  /// Applies the latest [paused]; calls run one after another so a quick
  /// background and return cannot interleave.
  Future<void> apply({required bool paused}) =>
      _queue = _queue.then((_) => _apply(paused));

  Future<void> _apply(bool paused) async {
    if (paused && !_pausedByUs && cameraOn()) {
      _pausedByUs = await setCamera(false);
    } else if (!paused && _pausedByUs) {
      _pausedByUs = false;
      await setCamera(true);
    }
  }

  /// The call ended, so there is nothing to bring back.
  void forget() => _pausedByUs = false;
}

/// Mounted from the app chrome next to [videoInterestHostProvider].
final cameraBackgroundHostProvider = Provider<void>((ref) {
  final controller = ref.read(voiceControllerProvider.notifier);
  final pause = CameraBackgroundPause(
    cameraOn: () => ref.read(voiceControllerProvider).cameraEnabled,
    setCamera: controller.video.setCameraPublishing,
  );
  ref.listen<bool>(cameraBackgroundPausedProvider, (_, paused) {
    unawaited(pause.apply(paused: paused));
  }, fireImmediately: true);
  ref.listen<bool>(
    voiceFlagsProvider.select((f) => f.state == VoiceSessionState.connected),
    (_, connected) {
      if (!connected) pause.forget();
    },
  );
});
