// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Stops drawing the member's own camera and screen-share preview, and
/// receiving other members' video, while nobody can see the window.
///
/// Audio and the call are never touched; only a phone's own camera stops
/// publishing, see `camera_background_pause.dart`.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart' show isDesktopHost;
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import '../../../providers/app_lifecycle.dart';
import 'picture_in_picture.dart';
import 'popout_window.dart';
import 'video_interest_relay.dart';
import 'voice_controller.dart';
import 'voice_settings_controller.dart';

/// Whether this is a desktop window, where minimising is a choice the user can opt out of pausing for.
final pauseOnUnfocusedAppliesProvider = Provider<bool>((ref) => isDesktopHost);

/// Whether the member's own camera and screen-share preview stop drawing.
///
/// Hidden, minimised or backgrounded always pauses on a phone. On a desktop
/// the user's setting decides, and it also covers a window that is open but
/// not focused: a preview of your own screen redrawn at full rate costs more
/// than the share itself, and nobody is looking at it while you are elsewhere.
bool shouldPauseLocalPreview({
  required AppLifecycleState lifecycle,
  required bool pauseWhenMinimised,
  required bool desktop,
  required bool pictureInPicture,
}) {
  if (pictureInPicture) return false;
  return switch (lifecycle) {
    AppLifecycleState.resumed => false,
    AppLifecycleState.inactive => desktop && pauseWhenMinimised,
    AppLifecycleState.hidden ||
    AppLifecycleState.paused ||
    AppLifecycleState.detached => !desktop || pauseWhenMinimised,
  };
}

/// Other members' video is still worth receiving in an unfocused window, which
/// can sit on a second monitor; only a hidden one stops it.
bool shouldPauseRemoteVideo({
  required AppLifecycleState lifecycle,
  required bool pauseWhenMinimised,
  required bool desktop,
  required bool pictureInPicture,
}) =>
    lifecycle != AppLifecycleState.inactive &&
    shouldPauseLocalPreview(
      lifecycle: lifecycle,
      pauseWhenMinimised: pauseWhenMinimised,
      desktop: desktop,
      pictureInPicture: pictureInPicture,
    );

typedef _Read = T Function<T>(ProviderListenable<T> provider);

bool _pausedNow(_Read read, {required bool local}) =>
    (local ? shouldPauseLocalPreview : shouldPauseRemoteVideo)(
      lifecycle: read(appLifecycleProvider),
      pauseWhenMinimised: read(_pauseWhenMinimised),
      desktop: read(pauseOnUnfocusedAppliesProvider),
      pictureInPicture: read(inPictureInPictureProvider),
    );

final _pauseWhenMinimised = voiceSettingsControllerProvider.select(
  (s) => s.pauseVideoWhenMinimised,
);

final localPreviewPausedProvider = Provider<bool>(
  (ref) => _pausedNow(ref.watch, local: true),
);

/// Whether a person can see the window, so remote video is worth receiving.
final remoteVideoSeenProvider = Provider<bool>(
  (ref) => !_pausedNow(ref.watch, local: false),
);

/// Runs [onChange] with whether video is paused, now and at once on every
/// change of what decides it.
///
/// The two providers above are derived, so a listener on them waits for a
/// frame, and a window that was just hidden may never draw one.
void onVideoPauseChanged(
  Ref ref, {
  required bool local,
  required void Function(bool paused) onChange,
}) {
  void sync() => onChange(_pausedNow(ref.read, local: local));
  ref.listen(appLifecycleProvider, (_, _) => sync());
  ref.listen(_pauseWhenMinimised, (_, _) => sync());
  ref.listen(inPictureInPictureProvider, (_, _) => sync());
  sync();
}

/// Mounted from the app chrome: feeds window visibility and a fresh connection into the video interest.
final videoInterestHostProvider = Provider<void>((ref) {
  final relay = ref.watch(videoInterestRelayProvider);
  onVideoPauseChanged(
    ref,
    local: false,
    onChange: (paused) => relay.setSeen(!paused),
  );
  ref.listen(popOutLiveFeedsProvider, (_, feeds) {
    relay.setPoppedOut({
      for (final feed in feeds) pictureInPictureTileKey(feed),
    });
  }, fireImmediately: true);
  ref.listen<bool>(
    voiceControllerProvider.select(
      (s) => s.state == VoiceSessionState.connected,
    ),
    (_, connected) {
      if (connected) relay.refresh();
    },
  );
});
