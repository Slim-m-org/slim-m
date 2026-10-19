// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the rejoin screen shows instead of nothing after a real call: how
/// long it lasted, who else was in it, and whether a screen or camera was
/// shared at any point. A solo call renders the same card with just the
/// duration and any activity, rather than nothing at all - see `CallRecap`
/// (`providers/call_recap.dart`) for what is tracked, and why it never
/// reaches the server.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../format.dart';
import '../providers/call_recap.dart';
import '../../members/widgets/user_avatar.dart';

/// `1 hr 4 min`-style, for a call that has already ended - unlike
/// `CallDuration`, a fixed string rather than a ticking clock.
String formatCallDuration(Duration d) {
  final parts = decomposeDuration(d);
  if (parts.hours > 0) {
    final plural = parts.hours == 1 ? '' : 's';
    return '${parts.hours} hr$plural ${parts.minutes} min';
  }
  if (parts.minutes > 0) return '${parts.minutes} min';
  return '${parts.seconds} sec';
}

/// "Your last call" labels the card: without it, the card sat directly
/// under the present-tense "Nobody is in this call yet." with nothing
/// marking it as a summary of the call that just ended, not who is in it
/// right now.
class CallRecapCard extends StatelessWidget {
  const CallRecapCard({
    super.key,
    required this.recap,
    this.title = 'Your last call',
  });

  final CallRecap recap;
  final String title;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _RecapStat(
                icon: AppIcons.clock,
                value: formatCallDuration(recap.duration),
                label: 'in the call',
              ),
              if (recap.others.isNotEmpty) ...[
                const SizedBox(width: AppSpacing.s24),
                _RecapStat(
                  icon: AppIcons.members,
                  value: '${recap.others.length}',
                  label: recap.others.length == 1
                      ? 'other person'
                      : 'other people',
                ),
              ],
            ],
          ),
          if (recap.wasAlone) ...[
            const SizedBox(height: AppSpacing.s8),
            Text(
              'Nobody else joined.',
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ],
          if (recap.sharedScreen || recap.usedCamera) ...[
            const SizedBox(height: AppSpacing.s12),
            _ActivityLine(recap: recap),
          ],
          if (recap.others.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s16),
            _ParticipantList(others: recap.others),
          ],
        ],
      ),
    );
  }
}

class _RecapStat extends StatelessWidget {
  const _RecapStat({
    required this.icon,
    required this.value,
    required this.label,
  });

  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: tokens.textSecondary),
            const SizedBox(width: AppSpacing.s4),
            Text(
              value,
              style: AppText.heading.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.s4),
        Text(
          label,
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
      ],
    );
  }
}

/// Whether a screen or camera was shared at any point, not only at the
/// moment of hang-up - both flags are cumulative across the whole call.
class _ActivityLine extends StatelessWidget {
  const _ActivityLine({required this.recap});

  final CallRecap recap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final parts = <String>[
      if (recap.sharedScreen) 'shared your screen',
      if (recap.usedCamera) 'had your camera on',
    ];
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (recap.sharedScreen)
          Icon(AppIcons.screenShare, size: 14, color: tokens.accent),
        if (recap.sharedScreen && recap.usedCamera)
          const SizedBox(width: AppSpacing.s8),
        if (recap.usedCamera)
          Icon(AppIcons.camera, size: 14, color: tokens.accent),
        const SizedBox(width: AppSpacing.s8),
        Flexible(
          child: Text(
            'You ${parts.join(' and ')}',
            textAlign: TextAlign.center,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ),
      ],
    );
  }
}

/// Who else was here, and whether they were still there when this device
/// hung up. The "left early" caption is the same fact a join/leave chip
/// would otherwise carry by shape alone - text, not a colour or an icon.
class _ParticipantList extends StatelessWidget {
  const _ParticipantList({required this.others});

  final List<CallParticipantActivity> others;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final person in others)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
            child: Semantics(
              container: true,
              label: person.leftAt == null
                  ? '${person.name}, in the call until you left'
                  : '${person.name}, left before you did',
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    UserAvatar(
                      name: person.name,
                      userId: person.identity,
                      size: AppAvatarSize.s24,
                    ),
                    const SizedBox(width: AppSpacing.s8),
                    Expanded(
                      child: Text(
                        person.name,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.body.copyWith(color: tokens.textPrimary),
                      ),
                    ),
                    if (person.leftAt != null)
                      Text(
                        'left early',
                        style: AppText.caption.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
