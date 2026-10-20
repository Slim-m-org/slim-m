// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Everyone in the call, each row opening the menu their call tile has.
///
/// The canvas hides or moves tiles, so a person can be hard to find or reach
/// on the board; this list reaches everyone the same way at any width.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../widgets/context_menu_region.dart';
import '../../members/providers/blocks_controller.dart';
import '../../members/widgets/user_avatar.dart';
import '../../voice/providers/voice_flags.dart';
import '../../voice/widgets/call_participant_tiles.dart'
    show kParticipantMenuWidth;
import '../../voice/widgets/participant_call_menu.dart';

Future<void> showCanvasParticipantsSheet(BuildContext context) =>
    showAppSheet<void>(
      context,
      scrolls: true,
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
          Text(
            'In this call',
            style: AppText.body.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const SizedBox(height: AppSpacing.s8),
          if (participants.isEmpty)
            Text(
              'Nobody else is here.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          for (final participant in participants)
            _ParticipantRow(
              key: ValueKey(participant.identity),
              participant: participant,
            ),
        ],
      ),
    );
  }
}

class _ParticipantRow extends ConsumerStatefulWidget {
  const _ParticipantRow({super.key, required this.participant});

  final VoiceParticipant participant;

  @override
  ConsumerState<_ParticipantRow> createState() => _ParticipantRowState();
}

class _ParticipantRowState extends ConsumerState<_ParticipantRow> {
  final _region = GlobalKey<ContextMenuRegionState>();

  @override
  Widget build(BuildContext context) {
    final participant = widget.participant;
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ContextMenuRegion(
      key: _region,
      ownsFocusNode: false,
      menuWidth: kParticipantMenuWidth,
      itemsBuilder: (menuContext, close) => participantCallMenuItems(
        menuContext,
        ref,
        participant: participant,
        close: close,
        withFullscreen: false,
      ),
      child: AppListRow(
        label: participant.name,
        meta: participant.isLocal ? 'You' : null,
        leading: UserAvatar(
          name: participant.name,
          userId: participant.identity,
          size: AppAvatarSize.s28,
          speaking: participant.isSpeaking,
        ),
        trailing: Icon(
          participant.isMuted ? AppIcons.micOff : AppIcons.moreVertical,
          size: AppSizes.icon16,
          color: tokens.textSecondary,
        ),
        onTap: () => _region.currentState?.open(),
      ),
    );
  }
}
