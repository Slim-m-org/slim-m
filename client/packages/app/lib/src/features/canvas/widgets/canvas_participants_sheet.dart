// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Everyone in the call, each row opening the menu their call tile has, reachable the same way at any width.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../members/providers/blocks_controller.dart';
import '../../members/widgets/user_avatar.dart';
import '../../voice/providers/voice_flags.dart';
import 'canvas_participant_menu.dart';

Future<void> showCanvasParticipantsSheet(BuildContext context) =>
    showAppSheet<void>(
      context,
      scrolls: true,
      semanticLabel: 'In this call',
      builder: (_) => const CanvasParticipantsSheet(),
    );

class CanvasParticipantsSheet extends ConsumerWidget {
  const CanvasParticipantsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final blocks = ref.watch(blocksProvider);
    final participants = [
      for (final p in ref.watch(voiceParticipantsProvider))
        if (!blocks.contains(p.identity)) p,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              'In this call',
              style: AppText.body.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s8),
          if (participants.isEmpty)
            Text(
              'Nobody else is here.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          // The sheet is bounded (scrolls: true), so a long call scrolls under the pinned heading.
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final participant in participants)
                    _ParticipantRow(
                      key: ValueKey(participant.identity),
                      participant: participant,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ParticipantRow extends StatelessWidget {
  const _ParticipantRow({super.key, required this.participant});

  final VoiceParticipant participant;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return CanvasParticipantMenu(
      participant: participant,
      builder: (context, open) {
        // Said in words as well as icons, so a screen reader hears who is muted or talking.
        final state = [
          if (participant.isLocal) 'You',
          if (participant.isSpeaking) 'Speaking',
          if (participant.isDeafened)
            'Deafened'
          else if (participant.isMuted)
            'Muted',
        ];
        return AppListRow(
          label: participant.name,
          meta: state.isEmpty ? null : state.join(', '),
          leading: UserAvatar(
            name: participant.name,
            userId: participant.identity,
            size: AppAvatarSize.s28,
            speaking: participant.isSpeaking,
          ),
          // This device's own row has nothing to open unless it is sharing or has a camera on.
          trailing: open == null
              ? null
              : Icon(
                  AppIcons.moreVertical,
                  size: AppSizes.icon16,
                  color: tokens.textSecondary,
                ),
          onTap: open,
        );
      },
    );
  }
}
