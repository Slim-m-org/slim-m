// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'incoming_call_ring_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import '../providers/dm_call_ring_controller.dart';
import '../../members/providers/user_profiles.dart';
import '../../members/widgets/user_avatar.dart';

/// Below `kCompactWidth`: a full-screen takeover, the same shape a phone's
/// own incoming-call screen already uses - desktop-vs-mobile.md rule 7's
/// compact case. A floating card here would be either too small to read at
/// a glance or too large not to already be the whole screen, and a call
/// ringing is exactly the moment nothing else on screen should compete for
/// the tap.
class CompactIncomingCall extends ConsumerWidget {
  const CompactIncomingCall({super.key, required this.ring});

  final IncomingDmCallRing ring;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final profile = ref.watch(userProfileProvider(ring.callerId)).valueOrNull;
    final name = profile?.displayName ?? 'Someone';

    return RingShortcuts(
      ring: ring,
      child: Material(
        color: tokens.surfaceBase,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.s24),
            child: Column(
              children: [
                const Spacer(),
                UserAvatar.known(
                  name: name,
                  userId: profile?.id,
                  avatarUpdatedAt: profile?.avatarUpdatedAt,
                  size: AppAvatarSize.s96,
                ),
                const SizedBox(height: AppSpacing.s16),
                Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: AppText.title.copyWith(color: tokens.textPrimary),
                ),
                const SizedBox(height: AppSpacing.s4),
                Text(
                  'Incoming call',
                  style: AppText.body.copyWith(color: tokens.textSecondary),
                ),
                const Spacer(),
                Row(
                  children: [
                    Expanded(
                      child: AppButton(
                        label: 'Decline',
                        icon: AppIcons.leaveCall,
                        variant: AppButtonVariant.danger,
                        size: AppButtonSize.lg,
                        full: true,
                        onPressed: () => declineRing(ref, ring),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s12),
                    Expanded(
                      child: AppButton(
                        label: 'Accept',
                        icon: AppIcons.startCall,
                        variant: AppButtonVariant.primary,
                        size: AppButtonSize.lg,
                        full: true,
                        onPressed: () => acceptRing(ref, ring),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
