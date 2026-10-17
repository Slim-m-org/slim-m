// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'incoming_call_overlay.dart';

// Split from incoming_call_overlay.dart for the line budget: the two width surfaces themselves, kept as private part-of classes so both still share _RingShortcuts, _acceptRing and _declineRing with no public surface added.
/// Below `kCompactWidth`: a full-screen takeover, the same shape a phone's
/// own incoming-call screen already uses - desktop-vs-mobile.md rule 7's
/// compact case. A floating card here would be either too small to read at
/// a glance or too large not to already be the whole screen, and a call
/// ringing is exactly the moment nothing else on screen should compete for
/// the tap.
class _CompactIncomingCall extends ConsumerWidget {
  const _CompactIncomingCall({required this.ring});

  final IncomingDmCallRing ring;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final profile = ref.watch(userProfileProvider(ring.callerId)).valueOrNull;
    final name = profile?.displayName ?? 'Someone';

    return _RingShortcuts(
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
                        onPressed: () => _declineRing(ref, ring),
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
                        onPressed: () => _acceptRing(ref, ring),
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

/// At or above `kCompactWidth`: a floating card, the same
/// `FloatingDockCard` shape a call's own controls already use, positioned
/// at the top of the window with the rest of it left interactive - rule 7's
/// non-takeover case, matched to how Discord's own desktop client surfaces
/// this rather than blocking the whole app for a decision the user can also
/// just let time out.
class _ExpandedIncomingCall extends ConsumerWidget {
  const _ExpandedIncomingCall({required this.ring});

  final IncomingDmCallRing ring;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _RingShortcuts(
    ring: ring,
    child: FloatingDockCard(rows: [_ExpandedIncomingCallRow(ring: ring)]),
  );
}

class _ExpandedIncomingCallRow extends ConsumerWidget {
  const _ExpandedIncomingCallRow({required this.ring});

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
            onPressed: () => _declineRing(ref, ring),
          ),
          const SizedBox(width: AppSpacing.s8),
          CallDockButton(
            icon: AppIcons.startCall,
            tooltip: 'Accept',
            active: true,
            onPressed: () => _acceptRing(ref, ring),
          ),
        ],
      ),
    );
  }
}
