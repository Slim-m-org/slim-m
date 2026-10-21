// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call participant's avatar with the marks a canvas list owes them: speaking ring, poor connection, muted.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../members/widgets/user_avatar.dart';
import '../../voice/providers/voice_health.dart';
import '../../voice/widgets/call_participant_tiles.dart';

class CanvasRosterAvatar extends ConsumerWidget {
  const CanvasRosterAvatar({
    super.key,
    required this.participant,
    this.size = AppAvatarSize.s28,
  });

  final VoiceParticipant participant;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final poor = ref.watch(
      poorConnectionsProvider.select((s) => s.contains(participant.identity)),
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        UserAvatar(
          name: participant.name,
          userId: participant.identity,
          size: size,
          speaking: participant.isSpeaking,
        ),
        if (poor)
          Positioned(
            right: -2,
            top: -2,
            child: _badge(
              tokens,
              Icon(
                AppIcons.connectionPoor,
                key: poorConnectionBadgeKey,
                size: AppSizes.icon12,
                color: tokens.warnText,
              ),
            ),
          ),
        if (participant.isMuted || participant.isDeafened)
          Positioned(
            right: -2,
            bottom: -2,
            child: _badge(
              tokens,
              Icon(
                participant.isMuted ? AppIcons.micOff : AppIcons.headphonesOff,
                size: AppSizes.icon12,
                color: tokens.textSecondary,
              ),
            ),
          ),
      ],
    );
  }

  Widget _badge(AppTokens tokens, Widget icon) => DecoratedBox(
    decoration: BoxDecoration(
      color: tokens.surfaceRaised,
      shape: BoxShape.circle,
    ),
    child: icon,
  );
}
