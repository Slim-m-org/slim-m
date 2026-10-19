// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a right-click or long-press on one call participant offers, shared
/// by the two places that gesture can land - a tile in the non-canvas call
/// view (`call_participant_tiles.dart`) and a bubble on the canvas
/// (`canvas_presence_tile.dart`) - so the two never drift into offering a
/// different set for the same person.
///
/// Deliberately thin. Volume is the slider itself, first in the list, so one
/// right click is enough to change it. Moderation is one row, not
/// a wall of rows, matching `member_profile.dart`'s own precedent: tapping
/// it opens that same full profile popover, pre-seeded onto
/// [MemberModerateView] via `initiallyModerating`, so the permission checks
/// and the actions themselves are never a second copy - only whether the
/// row appears at all is decided here, from the same
/// [memberModerationGates] the full card itself uses.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../members/providers/member_presence.dart' show membersProvider;
import '../providers/voice_controller.dart';
import '../../members/widgets/member_actions.dart'
    show callMember, messageMember;
import '../../members/widgets/member_moderation_gates.dart';
import '../../members/widgets/member_profile.dart';
import 'participant_actions.dart';
import 'participant_stream_menu.dart';
import 'participant_audio_controls.dart'
    show ParticipantMuteForMeMenuItem, ParticipantVolumeControl;

/// The rows one call participant's quick-actions menu offers. This device's
/// own tile gets only its stream rows: no muting or viewing your own profile
/// from a call tile; the member pane's "Profile settings" row covers that.
/// The call lounge tile, the canvas bubble and the rail row all use this.
List<Widget> participantCallMenuItems(
  BuildContext context,
  WidgetRef ref, {
  required VoiceParticipant participant,
  required VoidCallback close,
  api.UserProfile? knownProfile,
  String? channelId,
}) {
  final streams = participantStreamMenuItems(
    context,
    ref,
    identity: participant.identity,
    close: close,
  );
  if (participant.isLocal) return streams;

  final controller = ref.read(voiceControllerProvider.notifier);
  final profile =
      knownProfile ??
      ref
          .read(membersProvider)
          .valueOrNull
          ?.where((m) => m.id == participant.identity)
          .firstOrNull;

  // watch: false - see memberModerationGates's own doc for why.
  final gates = profile == null
      ? null
      : memberModerationGates(ref, profile: profile, watch: false);
  final actions = participantActions(
    surface: ParticipantSurface.menu,
    isSelf: false,
    inCallTogether: true,
    supportsVolume: controller.supportsParticipantVolume,
    hasProfile: profile != null,
    showModeration: gates?.showModeration ?? false,
  );

  return [
    for (final action in actions)
      switch (action) {
        ParticipantAction.volume => Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s8,
            vertical: AppSpacing.s4,
          ),
          child: Row(
            children: [
              Icon(
                AppIcons.speaker,
                size: AppSizes.icon16,
                color: Theme.of(context).extension<AppTokens>()!.textSecondary,
              ),
              const SizedBox(width: AppSpacing.s8),
              Expanded(
                child: ParticipantVolumeControl(
                  identity: participant.identity,
                  controller: controller,
                  showLabel: false,
                ),
              ),
            ],
          ),
        ),
        ParticipantAction.muteForMe => ParticipantMuteForMeMenuItem(
          identity: participant.identity,
          controller: controller,
          onDone: close,
        ),
        ParticipantAction.message => AppMenuItem(
          label: 'Message',
          leading: AppIcons.send,
          onTap: () {
            final container = ProviderScope.containerOf(context, listen: false);
            close();
            unawaited(messageMember(context, container, profile!));
          },
        ),
        ParticipantAction.call => AppMenuItem(
          label: 'Call',
          leading: AppIcons.startCall,
          onTap: () {
            final container = ProviderScope.containerOf(context, listen: false);
            close();
            unawaited(callMember(context, container, profile!));
          },
        ),
        ParticipantAction.viewProfile => AppMenuItem(
          label: 'View profile',
          leading: AppIcons.account,
          onTap: () {
            close();
            showMemberProfile(context, profile: profile!, channelId: channelId);
          },
        ),
        ParticipantAction.moderate => AppMenuItem(
          label: 'Moderate...',
          leading: AppIcons.shield,
          submenu: true,
          onTap: () {
            close();
            showMemberProfile(
              context,
              profile: profile!,
              channelId: channelId,
              initiallyModerating: true,
            );
          },
        ),
      },
    ...streams,
  ];
}
