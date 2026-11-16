// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The controls at the right of the rail's user bar: mic and deafen while in a
/// call, then the gear. `channel_rail_frame.dart` keeps the footer's layout.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../desktop/update_watch.dart';
import '../../../routing/routes.dart';
import '../../../widgets/shortcut_label.dart';
import '../../accounts/widgets/other_account_value.dart';
import '../../voice/providers/mic_status.dart';
import '../../voice/providers/voice_controller.dart';
import '../../voice/providers/voice_flags.dart';

VoidCallback? _micAction({
  required bool inCall,
  required bool stuck,
  required VoiceController voiceController,
}) {
  if (!inCall) return null;
  return stuck
      ? voiceController.devices.resetMicrophone
      : voiceController.toggleMicrophone;
}

/// The mic/deafen toggles in `RailUserFooter`'s row, shown only while in a
/// call: out of one they could do nothing, and the call dock carries the rest.
///
/// Takes [VoiceFlags] rather than the full [VoiceState] on purpose: the
/// footer has no use for the roster, and typing this as the narrower flags
/// object makes it impossible for a future caller to thread it back in.
List<Widget> railVoiceToggleButtons({
  required VoiceFlags voice,
  required VoiceController voiceController,
  MicStatus micStatus = MicStatus.ok,
}) {
  if (!voice.callLive) return const [];
  final trouble = voice.microphoneEnabled ? micStatus.trouble : null;
  final micLabel = voice.microphoneEnabled ? 'Mute' : 'Unmute';
  final deafenLabel = voice.deafened ? 'Undeafen' : 'Deafen';
  return [
    AppIconButton(
      icon: voice.microphoneEnabled && trouble == null
          ? AppIcons.mic
          : AppIcons.micOff,
      semanticLabel: trouble ?? micLabel,
      tooltip: trouble ?? labelWithShortcut(micLabel, AppAction.toggleMuteCall),
      variant: voice.microphoneEnabled && trouble == null
          ? AppIconButtonVariant.ghost
          : AppIconButtonVariant.dangerGhost,
      onPressed: _micAction(
        inCall: true,
        stuck: micStatus == MicStatus.unavailable && trouble != null,
        voiceController: voiceController,
      ),
    ),
    AppIconButton(
      icon: voice.deafened ? AppIcons.headphonesOff : AppIcons.headphones,
      semanticLabel: deafenLabel,
      tooltip: labelWithShortcut(deafenLabel, AppAction.toggleDeafenCall),
      variant: voice.deafened
          ? AppIconButtonVariant.dangerGhost
          : AppIconButtonVariant.ghost,
      onPressed: voiceController.toggleDeafen,
    ),
  ];
}

/// [railVoiceToggleButtons] for the live call: this account's, or the one
/// [otherAccount] holds while another community is on screen.
class RailVoiceToggles extends StatelessWidget {
  const RailVoiceToggles({super.key, this.otherAccount});

  final ProviderContainer? otherAccount;

  static Widget _row(
    VoiceFlags voice,
    VoiceController controller,
    MicStatus? mic,
  ) => Row(
    mainAxisSize: MainAxisSize.min,
    children: railVoiceToggleButtons(
      voice: voice,
      voiceController: controller,
      micStatus: mic ?? MicStatus.ok,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final other = otherAccount;
    if (other == null) {
      return Consumer(
        builder: (context, ref, _) => _row(
          ref.watch(voiceFlagsProvider),
          ref.read(voiceControllerProvider.notifier),
          ref.watch(micStatusProvider).valueOrNull,
        ),
      );
    }
    return OtherAccountValue(
      container: other,
      provider: voiceFlagsProvider,
      builder: (context, voice) => OtherAccountValue(
        container: other,
        provider: micStatusProvider,
        builder: (context, mic) => _row(
          voice,
          other.read(voiceControllerProvider.notifier),
          mic.valueOrNull,
        ),
      ),
    );
  }
}

/// The personal-settings nav button, last in the bar.
///
/// Carries a dot when an update is waiting. The banner says the same thing in
/// words, but it is dismissible and this is not: once the banner is gone the
/// only remaining sign used to be relaunching and hitting the splash check
/// again. The dot points at the pane that can act on it, and About is where
/// the two version numbers and the manual re-check live.
Widget railSettingsButton(BuildContext context) => Consumer(
  builder: (context, ref, _) {
    final pending = ref.watch(updatePendingProvider);
    final button = AppIconButton(
      icon: AppIcons.settings,
      semanticLabel: pending
          ? 'Personal settings, an update is available'
          : 'Personal settings',
      tooltip: labelWithShortcut('Settings', AppAction.openSettings),
      // The spoken name already says which settings; the short tooltip would only repeat it.
      excludeTooltipFromSemantics: true,
      onPressed: () => context.push(Routes.personalSettings),
    );
    if (!pending) return button;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        button,
        // The dot means "something is waiting" by being there, not by its hue.
        const Positioned(
          top: 2,
          right: 2,
          child: ExcludeSemantics(child: _UpdateDot(key: updateBadgeDotKey)),
        ),
      ],
    );
  },
);

/// Finds the gear's dot in a test, which nothing else about the rail can be
/// mistaken for.
const updateBadgeDotKey = Key('rail-gear-update-dot');

/// The gear's pending-update dot. Sized against nothing in particular: it has
/// to read as a mark on the icon rather than as a second control, and 8 is the
/// smallest that survives a HiDPI downscale without turning into a smudge.
class _UpdateDot extends StatelessWidget {
  const _UpdateDot({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: tokens.accent,
        shape: BoxShape.circle,
        // A ring of the surface behind it, so the dot stays legible on the glyph.
        border: Border.all(color: tokens.surfaceSunken, width: 1.5),
      ),
    );
  }
}
