// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Stops drawing the member's own camera and screen-share preview while
/// nobody can see the window.
///
/// Only the local previews: other members' video, audio, the call and what is
/// published to it are never touched, whatever the window is doing.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart' show isDesktopHost;
import 'package:slimm_rtc/rtc.dart' show VoiceParticipant;

import 'app_lifecycle.dart';
import 'picture_in_picture.dart';
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

final localPreviewPausedProvider = Provider<bool>((ref) {
  final unfocusedSetting = ref.watch(
    voiceSettingsControllerProvider.select((s) => s.pauseVideoWhenUnfocused),
  );
  return shouldPauseLocalPreview(
    lifecycle: ref.watch(appLifecycleProvider),
    pauseWhenUnfocused:
        unfocusedSetting && ref.watch(pauseOnUnfocusedAppliesProvider),
    pictureInPicture: ref.watch(inPictureInPictureProvider),
  );
});

/// Wraps the member's own preview; draws nothing while the preview is paused.
class LocalPreviewGate extends ConsumerWidget {
  const LocalPreviewGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      ref.watch(localPreviewPausedProvider) ? const SizedBox.shrink() : child;
}

/// Pauses [view] with the rest of the local preview when [identity] is the member.
Widget gateLocalPreview(
  List<VoiceParticipant> participants,
  String identity,
  Widget view,
) => participants.any((p) => p.isLocal && p.identity == identity)
    ? LocalPreviewGate(child: view)
    : view;
