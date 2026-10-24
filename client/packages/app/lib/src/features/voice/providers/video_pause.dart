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
import 'popout_window.dart';
import 'video_interest_relay.dart';
import 'voice_flags.dart';
import 'voice_settings_controller.dart';

/// Whether this is a desktop window, where minimising is a choice the user can opt out of pausing for.
final pauseOnUnfocusedAppliesProvider = Provider<bool>((ref) => isDesktopHost);

/// Hidden, minimised or backgrounded pauses; a merely unfocused window never does.
///
/// On a desktop the user's setting decides whether a minimised window pauses; a phone always does.
bool shouldPauseLocalPreview({
  required AppLifecycleState lifecycle,
  required bool pauseWhenMinimised,
  required bool desktop,
  required bool pictureInPicture,
}) {
  if (pictureInPicture) return false;
  return switch (lifecycle) {
    AppLifecycleState.resumed || AppLifecycleState.inactive => false,
    AppLifecycleState.hidden ||
    AppLifecycleState.paused ||
    AppLifecycleState.detached => !desktop || pauseWhenMinimised,
  };
}

bool _pausedNow(Ref ref) => shouldPauseLocalPreview(
  lifecycle: ref.watch(appLifecycleProvider),
  pauseWhenMinimised: ref.watch(
    voiceSettingsControllerProvider.select((s) => s.pauseVideoWhenMinimised),
  ),
  desktop: ref.watch(pauseOnUnfocusedAppliesProvider),
  pictureInPicture: ref.watch(inPictureInPictureProvider),
);

final localPreviewPausedProvider = Provider<bool>(_pausedNow);

/// Whether a person can see the window, so remote video is worth receiving.
final remoteVideoSeenProvider = Provider<bool>((ref) => !_pausedNow(ref));

/// Mounted from the app chrome: feeds window visibility and a fresh connection into the video interest.
final videoInterestHostProvider = Provider<void>((ref) {
  final relay = ref.watch(videoInterestRelayProvider);
  ref.listen<bool>(remoteVideoSeenProvider, (_, seen) {
    relay.setSeen(seen);
  }, fireImmediately: true);
  ref.listen(popOutLiveFeedProvider, (_, feed) {
    relay.setPoppedOut({if (feed != null) pictureInPictureTileKey(feed)});
  }, fireImmediately: true);
  ref.listen<bool>(
    voiceFlagsProvider.select((f) => f.state == VoiceSessionState.connected),
    (_, connected) {
      if (connected) relay.refresh();
    },
  );
});
