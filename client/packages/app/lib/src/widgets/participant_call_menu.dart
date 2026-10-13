// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a right-click or long-press on one call participant offers, shared
/// by the two places that gesture can land - a tile in the non-canvas call
/// view (`call_participant_tiles.dart`) and a bubble on the canvas
/// (`canvas_presence_tile.dart`) - so the two never drift into offering a
/// different set for the same person.
///
/// Deliberately thin. Volume opens its own popover
/// (`participant_volume_popover.dart`) rather than a bare slider fighting
/// this menu's own outside-tap-to-dismiss model. Moderation is one row, not
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
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/member_presence.dart' show membersProvider;
import '../providers/voice_controller.dart';
import 'member_actions.dart' show messageMember;
import 'member_moderation_gates.dart';
import 'member_profile.dart';
import 'participant_actions.dart';
import 'participant_audio_controls.dart' show ParticipantMuteForMeMenuItem;
import 'participant_volume_popover.dart';

/// The rows one call participant's quick-actions menu offers - empty for
/// this device's own tile, which has nothing to say about itself here (no
/// muting or viewing your own profile from a call tile; the member pane's
/// own "Profile settings" row already covers that).
List<Widget> participantCallMenuItems(
  BuildContext context,
  WidgetRef ref, {
  required VoiceParticipant participant,
  required VoidCallback close,
}) {
  if (participant.isLocal) return const [];

  final controller = ref.read(voiceControllerProvider.notifier);
  final profile = ref
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
        ParticipantAction.volume => AppMenuItem(
          label: 'Volume...',
          leading: AppIcons.speaker,
          submenu: true,
          onTap: () {
            close();
            showParticipantVolumePopover(
              context,
              identity: participant.identity,
              name: participant.name,
              controller: controller,
            );
          },
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
        ParticipantAction.viewProfile => AppMenuItem(
          label: 'View profile',
          leading: AppIcons.account,
          onTap: () {
            close();
            showMemberProfile(context, profile: profile!);
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
              initiallyModerating: true,
            );
          },
        ),
      },
  ];
}
