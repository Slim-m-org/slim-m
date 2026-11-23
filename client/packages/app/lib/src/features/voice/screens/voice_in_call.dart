// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../widgets/dock_height_reporter.dart';
import '../../canvas/widgets/canvas_open_button.dart'
    show callDockOmitsCanvasToggle;
import '../../members/providers/member_presence.dart' show membersProvider;
import '../../members/widgets/member_profile.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import '../widgets/bot_call_controls.dart';
import '../widgets/call_stage_layout.dart';
import '../widgets/hold_music_badge.dart';
import '../widgets/lounge_backdrop.dart';
import '../widgets/participant_call_menu.dart';
import 'voice_call_dock.dart';

const voiceCallDockKey = Key('voice-call-dock');

/// In the call: who is here, and the controls.
///
/// The controls used to trail this column as a full-width anchored strip,
/// which is exactly what made opening the canvas make them disappear
/// outright - `ConversationPane` swaps the whole pane, controls included,
/// rather than merely covering them. They float over this content instead
/// now, in the same `FloatingDockCard` a canvas's own controls use (see
/// `canvas_call_dock.dart`), so a future viewer comparing the two screens
/// sees one dock idea rather than two. What sits beneath them is
/// `CallStageLayout` (`widgets/call_stage_layout.dart`), which carries its
/// own bottom clearance so the floating card never sits on top of its
/// content.
///
/// [isDm] withholds the dock's own canvas toggle - not because a DM call has
/// no canvas to open, but because `dm_call_pane.dart`'s `_DmCallBar` already
/// carries one at every width; see `voice_call_dock.dart` for the full
/// reasoning, and `canvas_pane_test.dart` for the header affordance this is
/// in addition to, not a replacement for.
class VoiceInCall extends ConsumerStatefulWidget {
  const VoiceInCall({required this.channelId, required this.isDm, super.key});

  final String channelId;
  final bool isDm;

  @override
  ConsumerState<VoiceInCall> createState() => _InCallState();
}

class _InCallState extends ConsumerState<VoiceInCall> {
  /// The dock's real height, which bot controls and the call row make vary;
  /// null until measured.
  double? _dockHeight;
  double? _dockWidth;

  String get channelId => widget.channelId;
  bool get isDm => widget.isDm;

  void _onDockHeight(double height) {
    if (mounted && _dockHeight != height) setState(() => _dockHeight = height);
  }

  void _onDockWidth(double width) {
    if (mounted && _dockWidth != width) setState(() => _dockWidth = width);
  }

  /// The margin [SafeArea] keeps below the dock.
  double _dockMargin(BuildContext context) {
    final inset = MediaQuery.paddingOf(context).bottom;
    return inset > AppSpacing.s12 ? inset : AppSpacing.s12;
  }

  /// Dock plus the margin [SafeArea] keeps below it.
  double? _clearance(BuildContext context) {
    final height = _dockHeight;
    if (height == null) return null;
    return height + _dockMargin(context);
  }

  @override
  Widget build(BuildContext context) {
    final voice = ref.watch(voiceFlagsProvider);
    // autoDispose: hold the roster while a call is shown, or a tile's menu and card read it unloaded.
    ref.listen(membersProvider, (_, _) {});
    final controller = ref.read(voiceControllerProvider.notifier);
    final botControls = isDm ? null : botCallControlsFor(ref, channelId);

    return Stack(
      children: [
        Positioned.fill(
          child: Consumer(
            builder: (context, ref, _) => LoungeBackdrop(
              channelId: channelId,
              participants: ref.watch(voiceParticipantsProvider),
              canvas: !isDm,
            ),
          ),
        ),
        CallStageLayout(
          controller: controller,
          onOpenProfile: (anchor, p) => _openProfile(anchor, ref, p),
          isDm: isDm,
          dockClearance: _clearance(context) ?? defaultDockClearance,
          menuItemsBuilder:
              (context, participant, close, {withStreams = true}) =>
                  participantCallMenuItems(
                    context,
                    ref,
                    participant: participant,
                    close: close,
                    withStreams: withStreams,
                  ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.all(AppSpacing.s12),
            // Pure fade: VoiceCallDock owns its own per-call rise now.
            child: AppFadeIn(
              key: ValueKey('call-dock-$channelId'),
              offset: 0,
              child: DockHeightReporter(
                key: voiceCallDockKey,
                onHeight: _onDockHeight,
                onWidth: _onDockWidth,
                child: VoiceCallDock(
                  controller: controller,
                  voice: voice,
                  canvasChannelId: isDm || callDockOmitsCanvasToggle(context)
                      ? null
                      : channelId,
                  botControls: botControls,
                ),
              ),
            ),
          ),
        ),
        HoldMusicBadgeOverlay(
          fallbackBottom:
              (_clearance(context) ?? defaultDockClearance) + AppSpacing.s8,
          dockHeight: _dockHeight,
          dockWidth: _dockWidth ?? 0,
          dockMargin: _dockMargin(context),
        ),
      ],
    );
  }
}

/// Opens a caller's profile from their tile, which is the only route to the
/// per-participant volume control that does not go via the member pane.
///
/// The roster carries an identity and a name, not a profile, so the member
/// list is where the rest comes from. Absent from it (a member past the
/// page cap) means no profile to show rather than a wrong one, so nothing
/// opens - the alternative is a popover whose moderation half is missing
/// with no way to tell that it is.
void _openProfile(
  BuildContext context,
  WidgetRef ref,
  VoiceParticipant participant,
) {
  if (participant.isLocal) return;
  final profile = ref
      .read(membersProvider)
      .valueOrNull
      ?.where((m) => m.id == participant.identity)
      .firstOrNull;
  if (profile == null) return;

  showMemberProfile(context, profile: profile, profileOnly: true);
}
