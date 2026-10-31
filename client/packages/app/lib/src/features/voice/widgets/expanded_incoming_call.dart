// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'incoming_call_ring_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import '../providers/dm_call_ring_controller.dart';
import '../../members/providers/user_profiles.dart';
import 'voice_call_controls.dart' show CallDockButton;
import '../../../widgets/floating_dock_card.dart';
import '../../members/widgets/user_avatar.dart';

/// At or above `kCompactWidth`: a floating card, the same
/// `FloatingDockCard` shape a call's own controls already use, positioned
/// at the top of the window with the rest of it left interactive - rule 7's
/// non-takeover case, matched to how Discord's own desktop client surfaces
/// this rather than blocking the whole app for a decision the user can also
/// just let time out.
class ExpandedIncomingCall extends ConsumerWidget {
  const ExpandedIncomingCall({super.key, required this.ring});

  final IncomingDmCallRing ring;

  @override
  Widget build(BuildContext context, WidgetRef ref) => RingShortcuts(
    ring: ring,
    child: FloatingDockCard(rows: [ExpandedIncomingCallRow(ring: ring)]),
  );
}

class ExpandedIncomingCallRow extends ConsumerWidget {
  const ExpandedIncomingCallRow({super.key, required this.ring});

  final IncomingDmCallRing ring;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final profile = ref.watch(userProfileProvider(ring.callerId)).valueOrNull;
    final name = profile?.displayName ?? 'Someone';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          UserAvatar.known(
            name: name,
            userId: profile?.id,
            avatarUpdatedAt: profile?.avatarUpdatedAt,
            size: AppAvatarSize.s32,
          ),
          const SizedBox(width: AppSpacing.s8),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: AppWeights.medium,
                  ),
                ),
                Text(
                  'Incoming call',
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.s12),
          CallDockButton(
            icon: AppIcons.leaveCall,
            tooltip: 'Decline',
            active: false,
            destructive: true,
            onPressed: () => declineRing(ref, ring),
          ),
          const SizedBox(width: AppSpacing.s8),
          CallDockButton(
            icon: AppIcons.startCall,
            tooltip: 'Accept',
            active: true,
            onPressed: () => acceptRing(ref, ring),
          ),
        ],
      ),
    );
  }
}
