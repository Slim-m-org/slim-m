// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What this listener can do about hearing one participant, all of it local.
///
/// Split out of `member_profile_sections.dart` once a shared quick-actions
/// menu (`participant_call_menu.dart`, reached from a call tile or a canvas
/// bubble) needed the same controls the full member card already had.
///
/// The volume slider is present only where the platform can actually change
/// gain: on Linux, Windows and web the underlying call either throws or
/// quietly does nothing (see `audio_gain.dart` in the rtc package), and a
/// control that does nothing between its ends is worse than no control. The
/// mute half works everywhere, so it always shows.
///
/// **Mute for me is a separate flag, not volume 0.** [VoiceController
/// .isLocallyMuted] disables the track outright (`LocalAudioState.muted`);
/// volume (`LocalAudioState.volumes`) is gain applied only while a track is
/// not silenced this way - see `local_audio.dart`'s own `applyToRefs`, which
/// checks `deafened || muted` first and only reads a volume at all once
/// neither is true. Collapsing mute into "volume 0" would mean muting
/// someone quietly overwrites whatever volume you had them at, so unmuting
/// them again would need to also guess a volume back rather than simply
/// resuming whatever was already dialled in - and it would mean the reset-
/// to-normal button on the slider could no longer tell "muted" from "turned
/// all the way down" apart. Keeping them independent is also why leaving a
/// call clears [LocalAudioState.muted] but not `.volumes` (see that class's
/// own doc): a mute is a decision about the person for this call, gain is a
/// decision about how loud they generally are.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/voice_controller.dart';

/// Both halves together, in the shape the full member card wants them: the
/// slider (when supported) above the mute toggle.
class MemberLocalAudioSection extends StatelessWidget {
  const MemberLocalAudioSection({
    super.key,
    required this.identity,
    required this.controller,
  });

  final String identity;
  final VoiceController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (controller.supportsParticipantVolume)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s12,
              AppSpacing.s8,
              AppSpacing.s12,
              0,
            ),
            child: ParticipantVolumeControl(
              identity: identity,
              controller: controller,
            ),
          ),
        ParticipantMuteForMeMenuItem(
          identity: identity,
          controller: controller,
        ),
      ],
    );
  }
}

/// The slider half alone: a label, the current percentage, a reset-to-normal
/// button once it has moved off [kDefaultParticipantVolume], and the slider
/// itself. Reusable on its own - a quick-actions menu's own "Volume..." row
/// opens a small popover holding just this, since a bare slider inside the
/// menu itself would fight that menu's own outside-tap-to-dismiss model.
///
/// Caller's job to gate this on [VoiceController.supportsParticipantVolume]
/// first - this widget renders unconditionally once asked to, the same
/// "absent, never disabled" split every caller of it already makes.
/// How close to normal, as a fraction of it, a drag snaps to normal.
const double _snapToNormal = 0.04;

class ParticipantVolumeControl extends StatefulWidget {
  const ParticipantVolumeControl({
    super.key,
    required this.identity,
    required this.controller,
    this.showLabel = true,
  });

  final String identity;
  final VoiceController controller;

  /// Off where a title above already names whose volume this is.
  final bool showLabel;

  @override
  State<ParticipantVolumeControl> createState() =>
      _ParticipantVolumeControlState();
}

class _ParticipantVolumeControlState extends State<ParticipantVolumeControl> {
  /// The slider owns its position while it is being dragged. Reading it back
  /// from the session on every frame would make the drag depend on a round
  /// trip through the platform channel.
  late double _volume = widget.controller.volumeFor(widget.identity);

  /// Reaches the live LiveKit track on every move, the same round trip
  /// [VoiceController.setVolumeFor] already makes for the full member card -
  /// see `local_audio.dart`'s own `applyToRefs`, which this ends up calling.
  void _setVolume(double volume) {
    // Within a few points of normal snaps to it, so normal is easy to find again by feel.
    if ((volume - kDefaultParticipantVolume).abs() < _snapToNormal) {
      volume = kDefaultParticipantVolume;
    }
    setState(() => _volume = volume);
    widget.controller.setVolumeFor(widget.identity, volume);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final muted = widget.controller.isLocallyMuted(widget.identity);
    final atDefault = _volume == kDefaultParticipantVolume;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (widget.showLabel)
              Expanded(
                child: Text(
                  'Volume for you',
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
              )
            else
              const Spacer(),
            // Absent at the default, never disabled - see this widget's own doc; beside the number it resets.
            if (!atDefault)
              AppIconButton(
                icon: AppIcons.undo,
                semanticLabel: 'Reset volume to normal',
                tooltip: 'Reset to normal',
                size: AppIconButtonSize.sm,
                iconSize: AppSizes.icon16,
                touch: AppTouchTargets.of(context),
                onPressed: () => _setVolume(kDefaultParticipantVolume),
              ),
            Text(
              '${(_volume * 100).round()}%',
              style: AppText.code.copyWith(
                color: tokens.textPrimary,
                fontSize: 12,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.s8),
        AppSlider(
          value: _volume * 100,
          min: 0,
          max: kMaxParticipantVolume * 100,
          ticks: const ['0', '100', '200'],
          semanticLabel: 'Volume for you',
          muted: muted,
          onChanged: (next) => _setVolume(next / 100),
        ),
      ],
    );
  }
}

/// The mute-for-me toggle alone, as its own menu row - shared by the full
/// member card and any quick-actions menu, so the label, icon and the
/// underlying call are never duplicated between them.
class ParticipantMuteForMeMenuItem extends StatefulWidget {
  const ParticipantMuteForMeMenuItem({
    super.key,
    required this.identity,
    required this.controller,
    this.onDone,
  });

  final String identity;
  final VoiceController controller;

  /// Called once the toggle lands, for a caller that wants to close its own
  /// menu at that point - a quick-actions popover closes, the full member
  /// card just repaints in place (null).
  final VoidCallback? onDone;

  @override
  State<ParticipantMuteForMeMenuItem> createState() =>
      _ParticipantMuteForMeMenuItemState();
}

class _ParticipantMuteForMeMenuItemState
    extends State<ParticipantMuteForMeMenuItem> {
  @override
  Widget build(BuildContext context) {
    final muted = widget.controller.isLocallyMuted(widget.identity);
    return AppMenuItem(
      label: muted ? 'Unmute for me' : 'Mute for me',
      leading: muted ? AppIcons.speakerOff : AppIcons.speaker,
      selected: muted,
      onTap: () async {
        await widget.controller.setLocallyMuted(widget.identity, !muted);
        widget.onDone?.call();
        if (mounted) setState(() {});
      },
    );
  }
}
