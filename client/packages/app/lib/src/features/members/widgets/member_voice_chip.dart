// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "in #voice" chip on a member's row and card: a glyph and the channel
/// name, absent unless they are in a call this viewer can see.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/routes.dart';
import '../../voice/providers/member_voice_channel.dart';

class MemberVoiceChip extends ConsumerWidget {
  const MemberVoiceChip({
    super.key,
    required this.userId,
    this.onOpened,
    this.endGap = false,
  });

  final String userId;

  /// Runs after the jump, so a card can close itself.
  final VoidCallback? onOpened;

  /// Space after the chip, only while it shows, for a sibling beside it.
  final bool endGap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channel = ref.watch(memberVoiceChannelProvider(userId));
    if (channel == null) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final router = GoRouter.of(context);
    final chip = FocusableTapTarget(
      ringRadius: AppRadii.full,
      semanticLabel: 'In ${channel.name}, voice channel',
      onTap: () {
        router.go(Routes.channel(channel.id));
        onOpened?.call();
      },
      builder: (context, focused, hovered) => Container(
        height: AppSizes.icon20,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
        decoration: BoxDecoration(
          color: hovered ? tokens.accentSoft : tokens.surfaceRaised,
          border: Border.all(color: tokens.borderSubtle),
          borderRadius: BorderRadius.circular(AppRadii.full),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: AppSpacing.s4,
          children: [
            Icon(AppIcons.voice, size: AppSizes.icon12, color: tokens.accent),
            Flexible(
              child: Text(
                channel.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
    if (!endGap) return chip;
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.s4),
      child: chip,
    );
  }
}

/// The card's own placement of [MemberVoiceChip], inset like its siblings.
class MemberProfileVoice extends ConsumerWidget {
  const MemberProfileVoice({super.key, required this.userId, this.onOpened});

  final String userId;
  final VoidCallback? onOpened;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(memberVoiceChannelProvider(userId)) == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s12,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: MemberVoiceChip(userId: userId, onOpened: onOpened),
      ),
    );
  }
}
