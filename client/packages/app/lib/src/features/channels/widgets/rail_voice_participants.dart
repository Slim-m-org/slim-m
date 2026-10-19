// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The people under a voice channel in the rail. Each row opens that person's
/// member card on a tap or click, and the same menu as their call tile on a
/// right-click or long press (`participantCallMenuItems`), so the two cannot
/// offer different actions for one person.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../members/providers/user_profiles.dart';
import '../../../widgets/context_menu_region.dart';
import '../../voice/widgets/call_participant_tiles.dart'
    show kParticipantMenuWidth;
import '../../voice/widgets/participant_call_menu.dart';
import '../../members/widgets/member_profile.dart';
import '../../members/widgets/user_avatar.dart';
import 'rail_participant_drag.dart';

/// Left indent that puts the list under a channel row's *label* rather than
/// its icon: the row's own padding, its icon and the gap after it.
const double _stripIndent = AppSpacing.s8 + AppSizes.icon16 + AppSpacing.s8;

/// A participant row's height, so the avatar and caption share one 4dp-grid line.
const double _rowHeight = AppSpacing.s24;

const double _glyphSize = 12;

/// More rows than this and the list stops naming people and states a count
/// instead: an unbounded list would let one crowded voice channel push
/// every category below it off screen, the way `_maxMemberPages` bounds
/// paging for the same reason it exists at all - a defensive ceiling, not a
/// number any real channel is expected to reach.
const int _maxNamedParticipants = 8;

/// Who is in a voice channel: real-time for the one the caller has joined,
/// a periodic snapshot (`voiceRosterProvider`) for every other one.
///
/// Named rows, not a strip of faces: each participant gets their own row
/// (a small avatar and their name), the way a member pane names people
/// rather than just showing a row of pictures. `isSpeaking` already reaches
/// here for the joined channel's own live roster; `_asVoiceParticipant`
/// hardcodes it false for every other channel's periodic snapshot, which is
/// a real gap but not this one's - only the layout was a strip.
class RailParticipantList extends StatelessWidget {
  const RailParticipantList({
    super.key,
    required this.participants,
    required this.channelId,
  });

  final List<VoiceParticipant> participants;
  final String channelId;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final shown = participants.take(_maxNamedParticipants).toList();
    final overflow = participants.length - shown.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _stripIndent,
        0,
        AppSpacing.s8,
        AppSpacing.s4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final participant in shown)
            _ParticipantRow(participant: participant, channelId: channelId),
          if (overflow > 0)
            Text(
              '+$overflow more',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
        ],
      ),
    );
  }
}

class _ParticipantRow extends ConsumerStatefulWidget {
  const _ParticipantRow({required this.participant, required this.channelId});

  final VoiceParticipant participant;
  final String channelId;

  @override
  ConsumerState<_ParticipantRow> createState() => _ParticipantRowState();
}

class _ParticipantRowState extends ConsumerState<_ParticipantRow> {
  bool _hovered = false;

  void _open(api.UserProfile profile) => unawaited(
    showMemberProfile(context, profile: profile, channelId: widget.channelId),
  );

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final participant = widget.participant;
    final glyphs = [
      if (participant.isScreenSharing) AppIcons.screenShare,
      if (participant.isCameraOn) AppIcons.camera,
      if (participant.isMuted) AppIcons.micOff,
      if (participant.isDeafened) AppIcons.headphonesOff,
    ];
    final face = SizedBox(
      height: _rowHeight,
      child: Row(
        children: [
          UserAvatar(
            name: participant.name,
            userId: participant.identity,
            size: AppAvatarSize.s20,
            speaking: participant.isSpeaking,
          ),
          const SizedBox(width: AppSpacing.s8),
          Flexible(
            child: Text(
              participant.name,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ),
          for (final glyph in glyphs) ...[
            const SizedBox(width: AppSpacing.s4),
            Icon(glyph, size: _glyphSize, color: tokens.textSecondary),
          ],
        ],
      ),
    );
    final profile = ref
        .watch(userProfileProvider(participant.identity))
        .valueOrNull;
    // Until the profile resolves there is no card to open, so the row stays plain.
    if (profile == null) return face;
    return RailParticipantDraggable(
      data: ParticipantDragData(
        userId: participant.identity,
        name: participant.name,
        fromChannelId: widget.channelId,
      ),
      child: ContextMenuRegion(
        menuWidth: kParticipantMenuWidth,
        itemsBuilder: (menuContext, close) => participantCallMenuItems(
          menuContext,
          ref,
          participant: participant,
          close: close,
          knownProfile: profile,
          channelId: widget.channelId,
        ),
        child: ConstrainedBox(
          // A finger needs the touch row height; a pointer keeps the dense rows.
          constraints: BoxConstraints(
            minHeight: AppTouchTargets.of(context) ? AppSizes.rowTouch : 0,
          ),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            // The avatar's own label stays: it carries "<name>, speaking", which the e2e harness reads.
            child: Semantics(
              button: true,
              onTap: () => _open(profile),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _open(profile),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: _hovered ? tokens.surfaceSunken : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadii.control),
                  ),
                  child: face,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
