// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Stops drawing the member's own camera and screen-share preview, and
/// receiving other members' video, while nobody can see the window.
///
/// Audio, the call and what is published to it are never touched, whatever
/// the window is doing.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart' show isDesktopHost;
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import '../../../providers/app_lifecycle.dart';
import 'picture_in_picture.dart';
import 'video_interest_relay.dart';
import 'voice_flags.dart';
import 'voice_settings_controller.dart';

/// Whether a focus-only loss counts; a phone's `inactive` is a shade pull, not a switch away.
final pauseOnUnfocusedAppliesProvider = Provider<bool>((ref) => isDesktopHost);

/// Hidden, minimised or backgrounded pauses; unfocused only when the user opts in.
bool shouldPauseLocalPreview({
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

/// The member asked to keep their own preview showing while unfocused; lasts until the app closes.
final localPreviewResumedProvider = StateProvider<bool>((ref) => false);

final localPreviewPausedProvider = Provider<bool>((ref) {
  final unfocusedSetting = ref.watch(
    voiceSettingsControllerProvider.select((s) => s.pauseVideoWhenUnfocused),
  );
  final lifecycle = ref.watch(appLifecycleProvider);
  // Only a focus loss is overridable: a hidden or minimised window has nobody to draw for.
  if (lifecycle == AppLifecycleState.inactive &&
      ref.watch(localPreviewResumedProvider)) {
    return false;
  }
  return shouldPauseLocalPreview(
    lifecycle: lifecycle,
    pauseWhenUnfocused:
        unfocusedSetting && ref.watch(pauseOnUnfocusedAppliesProvider),
    pictureInPicture: ref.watch(inPictureInPictureProvider),
  );
});

/// Whether a person can see the window, so remote video is worth receiving.
final remoteVideoSeenProvider = Provider<bool>((ref) {
  final unfocusedSetting = ref.watch(
    voiceSettingsControllerProvider.select((s) => s.pauseVideoWhenUnfocused),
  );
  return !shouldPauseLocalPreview(
    lifecycle: ref.watch(appLifecycleProvider),
    pauseWhenUnfocused:
        unfocusedSetting && ref.watch(pauseOnUnfocusedAppliesProvider),
    pictureInPicture: ref.watch(inPictureInPictureProvider),
  );
});

/// Mounted from the app chrome: feeds window visibility and a fresh connection into the video interest.
final videoInterestHostProvider = Provider<void>((ref) {
  final relay = ref.watch(videoInterestRelayProvider);
  ref.listen<bool>(remoteVideoSeenProvider, (_, seen) {
    relay.setSeen(seen);
  }, fireImmediately: true);
  ref.listen<bool>(
    voiceFlagsProvider.select((f) => f.state == VoiceSessionState.connected),
    (_, connected) {
      if (connected) relay.refresh();
    },
  );
});
