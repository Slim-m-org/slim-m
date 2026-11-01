// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What this listener can do about hearing one participant, all of it local.
///
/// Split out of `member_profile_sections.dart` once a shared quick-actions
/// menu (`participant_call_menu.dart`, reached from a call tile or a canvas
/// bubble) needed the same controls the full member card already had.
///
/// The volume slider shows wherever gain can be changed, which is every
/// platform now (the web through Web Audio, see `audio_gain.dart` in the rtc
/// package). A change the platform refuses shows inline under the slider.
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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/voice_controller.dart';

/// Both halves together, in the shape the full member card wants them: the
/// slider (when supported) above the mute toggle.
class MemberLocalAudioSection extends StatefulWidget {
  const MemberLocalAudioSection({
    super.key,
    required this.identity,
    required this.controller,
    required this.showVolume,
  });

  final String identity;
  final VoiceController controller;

  /// From the shared action list, never re-derived here.
  final bool showVolume;

  @override
  State<MemberLocalAudioSection> createState() =>
      _MemberLocalAudioSectionState();
}

class _MemberLocalAudioSectionState extends State<MemberLocalAudioSection> {
  @override
  Widget build(BuildContext context) {
    final identity = widget.identity;
    final controller = widget.controller;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.showVolume)
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
        if (widget.showVolume && controller.volumes.hasScreenAudio(identity))
          ParticipantScreenAudioSection(
            identity: identity,
            controller: controller,
          ),
        ParticipantMuteForMeMenuItem(
          identity: identity,
          controller: controller,
          onDone: () {
            if (mounted) setState(() {});
          },
        ),
      ],
    );
  }
}

/// The slider half alone, on one row: a label, the slider, the percentage and
/// a reset-to-normal button once it has moved off [kDefaultParticipantVolume]. Reusable on its own - a quick-actions menu's own "Volume..." row
/// opens a small popover holding just this, since a bare slider inside the
/// menu itself would fight that menu's own outside-tap-to-dismiss model.
///
/// Caller's job to gate this on [VoiceController.supportsParticipantVolume]
/// first, the same "absent, never disabled" split every caller makes.
/// How close to normal, as a fraction of it, a drag snaps to normal.
const double _snapToNormal = 0.04;

/// One arrow-key or screen-reader step, so each press moves 5% while a drag stays fine.
const int _keyStepPercent = 5;

/// Wide enough for "200%" in the mono face, so the number never wraps or shifts the slider.
const double _valueWidth = 40;

class ParticipantVolumeControl extends StatefulWidget {
  const ParticipantVolumeControl({
    super.key,
    required this.identity,
    required this.controller,
    this.showLabel = true,
    this.channel = LocalAudioChannel.voice,
    this.autofocus = false,
    this.label,
  });

  final String identity;
  final VoiceController controller;

  /// Replaces the default title, for a menu that names the thing differently.
  final String? label;

  /// Whose sound this slider sets: their voice, or their shared screen's.
  final LocalAudioChannel channel;

  /// Off where a title above already names whose volume this is.
  final bool showLabel;

  /// On where the slider is the first thing a just-opened menu offers.
  final bool autofocus;

  @override
  State<ParticipantVolumeControl> createState() =>
      _ParticipantVolumeControlState();
}

class _ParticipantVolumeControlState extends State<ParticipantVolumeControl> {
  bool get _screen => widget.channel == LocalAudioChannel.screen;

  String get _label =>
      widget.label ?? (_screen ? 'Screen audio' : 'Volume for you');

  /// The slider owns its position while it is being dragged. Reading it back
  /// from the session on every frame would make the drag depend on a round
  /// trip through the platform channel.
  late double _volume = _screen
      ? widget.controller.volumes.screenVolumeFor(widget.identity)
      : widget.controller.volumes.volumeFor(widget.identity);

  /// Whether the platform refused the last gain change for this person.
  bool _failed = false;

  /// A drag frame is throttled and unsaved; a release or reset is applied and
  /// saved at once.
  void _setVolume(double volume, {bool commit = false}) {
    // Within a few points of normal snaps to it, so normal is easy to find again by feel.
    if ((volume - kDefaultParticipantVolume).abs() < _snapToNormal) {
      volume = kDefaultParticipantVolume;
    }
    // Whole percents, so the label shows exactly the value that is applied.
    volume = (volume * 100).round() / 100;
    setState(() => _volume = volume);
    final controller = widget.controller;
    final applied = _applyVolume(controller, volume, commit: commit);
    unawaited(applied.then((_) => _syncFailure()));
  }

  Future<void> _applyVolume(
    VoiceController controller,
    double volume, {
    required bool commit,
  }) {
    if (!commit) {
      return controller.volumes.dragVolumeFor(
        widget.identity,
        volume,
        channel: widget.channel,
      );
    }
    if (_screen) {
      return controller.volumes.setScreenVolumeFor(widget.identity, volume);
    }
    return controller.volumes.setVolumeFor(widget.identity, volume);
  }

  void _syncFailure() {
    if (!mounted) return;
    final failed =
        widget.controller.volumes.volumeFailureFor(
          widget.identity,
          channel: widget.channel,
        ) !=
        null;
    if (failed != _failed) setState(() => _failed = failed);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final muted = _screen
        ? widget.controller.volumes.isScreenAudioMuted(widget.identity)
        : widget.controller.isLocallyMuted(widget.identity);
    final atDefault = _volume == kDefaultParticipantVolume;

    final touch = AppTouchTargets.of(context);
    final row = Row(
      children: [
        if (widget.showLabel) ...[
          Flexible(
            child: Text(
              _label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ),
          const SizedBox(width: AppSpacing.s8),
        ],
        Expanded(
          child: AppSlider(
            value: _volume * 100,
            min: 0,
            max: kMaxParticipantVolume * 100,
            keyStep: _keyStepPercent.toDouble(),
            semanticLabel: _label,
            valueLabel: (v) => '${v.round()}%',
            valueBubble: false,
            autofocus: widget.autofocus,
            muted: muted,
            onChanged: (next) => _setVolume(next / 100),
            onChangeEnd: (next) => _setVolume(next / 100, commit: true),
          ),
        ),
        SizedBox(
          width: _valueWidth,
          child: Text(
            '${(_volume * 100).round()}%',
            maxLines: 1,
            textAlign: TextAlign.end,
            style: AppText.code.copyWith(
              color: tokens.textPrimary,
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        // The slot is always reserved so the slider does not resize as the reset button comes and goes.
        SizedBox(
          width: AppSizes.controlSm,
          child: atDefault
              ? null
              : AppIconButton(
                  icon: AppIcons.undo,
                  semanticLabel: 'Reset volume to normal',
                  tooltip: 'Reset to normal',
                  size: AppIconButtonSize.sm,
                  iconSize: AppSizes.icon16,
                  touch: touch,
                  onPressed: () =>
                      _setVolume(kDefaultParticipantVolume, commit: true),
                ),
        ),
      ],
    );
    if (!_failed) return row;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row,
        Text(
          "Volume can't be changed on this device",
          style: AppText.caption.copyWith(color: tokens.dangerText),
        ),
      ],
    );
  }
}

/// The screen audio half of a person's volume popover: its own slider and
/// mute, present only while they are sharing sound.
class ParticipantScreenAudioSection extends StatefulWidget {
  const ParticipantScreenAudioSection({
    super.key,
    required this.identity,
    required this.controller,
    this.showLabel = true,
    this.autofocus = false,
  });

  final String identity;
  final VoiceController controller;

  /// Off where a title above already says this is the screen's sound.
  final bool showLabel;
  final bool autofocus;

  @override
  State<ParticipantScreenAudioSection> createState() =>
      _ParticipantScreenAudioSectionState();
}

class _ParticipantScreenAudioSectionState
    extends State<ParticipantScreenAudioSection> {
  @override
  Widget build(BuildContext context) {
    final muted = widget.controller.volumes.isScreenAudioMuted(widget.identity);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ParticipantVolumeControl(
          identity: widget.identity,
          controller: widget.controller,
          channel: LocalAudioChannel.screen,
          showLabel: widget.showLabel,
          autofocus: widget.autofocus,
        ),
        AppMenuItem(
          label: muted ? 'Unmute screen audio' : 'Mute screen audio',
          leading: muted ? AppIcons.speakerOff : AppIcons.speaker,
          selected: muted,
          onTap: () async {
            await widget.controller.volumes.setScreenAudioMuted(
              widget.identity,
              !muted,
            );
            if (mounted) setState(() {});
          },
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
