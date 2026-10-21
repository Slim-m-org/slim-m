// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Everyone in the call as a compact row of avatars in the canvas dock, since
/// a person with no camera or share has no tile on the board (decision 0086).
///
/// Each avatar shows who is speaking and who is muted, and opens the same menu
/// a call tile has: left-click or tap, right-click, or long-press.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../members/providers/blocks_controller.dart';
import '../../members/widgets/user_avatar.dart';
import '../../voice/providers/voice_flags.dart';
import 'canvas_participant_menu.dart';
import 'canvas_participants_sheet.dart';

/// How many avatars fit before the rest fold into a "+n" that opens the sheet.
int canvasRosterCapacity(double paneWidth) => paneWidth < kCompactWidth ? 5 : 9;

class CanvasCallRoster extends ConsumerWidget {
  const CanvasCallRoster({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocks = ref.watch(blocksProvider);
    final participants = [
      for (final p in ref.watch(voiceParticipantsProvider))
        if (!blocks.contains(p.identity)) p,
    ];
    if (participants.isEmpty) return const SizedBox.shrink();
    final capacity = canvasRosterCapacity(MediaQuery.sizeOf(context).width);
    final shown = participants.take(capacity).toList();
    final hidden = participants.length - shown.length;
    return Semantics(
      container: true,
      label: 'In this call',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final p in shown)
            _RosterAvatar(key: ValueKey(p.identity), participant: p),
          if (hidden > 0) _MoreChip(count: hidden),
        ],
      ),
    );
  }
}

class _RosterAvatar extends StatelessWidget {
  const _RosterAvatar({super.key, required this.participant});

  final VoiceParticipant participant;

  String get _label {
    final state = [
      if (participant.isLocal) 'you',
      if (participant.isSpeaking) 'speaking',
      if (participant.isMuted) 'muted',
      if (participant.isDeafened) 'deafened',
    ];
    return state.isEmpty
        ? participant.name
        : '${participant.name}, ${state.join(', ')}';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return CanvasParticipantMenu(
      participant: participant,
      opensAbove: true,
      builder: (context, open) => Tooltip(
        message: participant.isLocal
            ? '${participant.name} (you)'
            : participant.name,
        excludeFromSemantics: true,
        child: Semantics(
          button: open != null,
          label: _label,
          onTap: open,
          excludeSemantics: true,
          child: AppTouchHitArea(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: open,
              child: Padding(
                // A 44 square at touch density, 36 at pointer density.
                padding: EdgeInsets.all(
                  AppTouchTargets.of(context) ? AppSpacing.s8 : AppSpacing.s4,
                ),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    UserAvatar(
                      name: participant.name,
                      userId: participant.identity,
                      size: AppAvatarSize.s28,
                      speaking: participant.isSpeaking,
                    ),
                    if (participant.isMuted || participant.isDeafened)
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: tokens.surfaceRaised,
                            shape: BoxShape.circle,
                            border: Border.all(color: tokens.surfaceRaised),
                          ),
                          child: Icon(
                            participant.isMuted
                                ? AppIcons.micOff
                                : AppIcons.headphonesOff,
                            size: AppSizes.icon12,
                            color: tokens.textSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MoreChip extends StatelessWidget {
  const _MoreChip({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      button: true,
      label: '$count more in this call',
      excludeSemantics: true,
      onTap: () => showCanvasParticipantsSheet(context),
      child: AppTouchHitArea(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => showCanvasParticipantsSheet(context),
          child: Padding(
            padding: EdgeInsets.all(
              AppTouchTargets.of(context) ? AppSpacing.s8 : AppSpacing.s4,
            ),
            child: Text(
              '+$count',
              style: AppText.caption.copyWith(
                color: tokens.textSecondary,
                fontWeight: AppWeights.medium,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
