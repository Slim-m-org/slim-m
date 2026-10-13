// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Stops receiving remote video while nobody can see the window.
///
/// Rides the video-interest path the canvas already uses, so the existing
/// two-stage cull does the work: tracks go unshown, are unsubscribed after
/// their dwell, and come straight back when the window does. Audio, the call
/// and the member's own camera and screen share are never touched.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart' show isDesktopHost;

import 'app_lifecycle.dart';
import 'picture_in_picture.dart';
import 'voice_settings_controller.dart';

/// Whether a focus-only loss counts; a phone's `inactive` is a shade pull, not a switch away.
final pauseOnUnfocusedAppliesProvider = Provider<bool>((ref) => isDesktopHost);

/// Hidden, minimised or backgrounded always pauses; unfocused only by setting.
bool shouldPauseVideo({
  required AppLifecycleState lifecycle,
  required bool pauseWhenUnfocused,
  required bool pictureInPicture,
}) {
  if (pictureInPicture) return false;
  return switch (lifecycle) {
    AppLifecycleState.resumed => false,
    AppLifecycleState.inactive => pauseWhenUnfocused,
    AppLifecycleState.hidden ||
    AppLifecycleState.paused ||
    AppLifecycleState.detached => true,
  };
}

final videoPausedProvider = Provider<bool>((ref) {
  final unfocusedSetting = ref.watch(
    voiceSettingsControllerProvider.select((s) => s.pauseVideoWhenUnfocused),
  );
  return shouldPauseVideo(
    lifecycle: ref.watch(appLifecycleProvider),
    pauseWhenUnfocused:
        unfocusedSetting && ref.watch(pauseOnUnfocusedAppliesProvider),
    pictureInPicture: ref.watch(inPictureInPictureProvider),
  );
});

/// Mounted from the app chrome: feeds [videoPausedProvider] to the relay.
final videoPauseHostProvider = Provider<void>((ref) {
  ref.listen<bool>(videoPausedProvider, (_, paused) {
    ref.read(videoInterestRelayProvider).pause(paused);
  }, fireImmediately: true);
});
