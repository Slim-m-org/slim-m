// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sections a member profile composes from, split out of
/// `member_profile.dart` when the moderation half took that file past the
/// review budget.
///
/// Each is a whole section or nothing. That is the design's own rule: a
/// section you have no rights or context for is *absent*, never
/// present-and-disabled, which is what keeps a plain member's profile to two
/// verbs instead of a wall of greyed rows.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../format.dart';
import '../providers/presence_view.dart';
import 'user_avatar.dart';

/// Avatar, name, role badge, and the presence word beside its dot - never the
/// dot alone, which is the rule every surface in this app follows.
class MemberProfileHeader extends ConsumerWidget {
  const MemberProfileHeader({
    super.key,
    required this.profile,
    required this.isSelf,
    required this.inCallTogether,
    this.callChannelName,
  });

  final api.UserProfile profile;
  final bool isSelf;
  final bool inCallTogether;

  /// Refines the shared-call line to name the room. Absent where the caller
  /// does not have the name to hand - the voice screen reads its channel from
  /// a database stream rather than holding it - and then the line reads "in
  /// this call with you", which is unambiguous from inside the call anyway.
  final String? callChannelName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final word = ref.watch(presenceForProvider(profile.id)).word;
    final timedOut = profile.timedOutUntil != null;

    final handleLine = Text(
      [
        '@${profile.username}',
        // A nickname hides the account's own name everywhere else, so say it here.
        if (profile.nickname != null && profile.accountDisplayName != null)
          'account name ${profile.accountDisplayName}',
        ?profile.pronouns,
      ].join(' · '),
      overflow: TextOverflow.ellipsis,
      style: AppText.caption.copyWith(color: tokens.textSecondary),
    );

    final subtitle = inCallTogether
        ? Row(
            children: [
              Icon(AppIcons.speaker, size: 12, color: tokens.accent),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  callChannelName == null
                      ? 'in this call with you'
                      : 'in $callChannelName with you',
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(color: tokens.accent),
                ),
              ),
            ],
          )
        : Text(
            isSelf ? [?word, 'you'].join(' - ') : word ?? '',
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          );

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s12),
      child: Row(
        children: [
          // The avatar only, never the text, which would cost its contrast.
          Opacity(
            opacity: timedOut ? 0.7 : 1,
            child: UserAvatar.known(
              userId: profile.id,
              avatarUpdatedAt: profile.avatarUpdatedAt,
              name: profile.displayName,
              size: AppAvatarSize.s44,
              presence: true,
              // The ring here means "in a call with you", so the name says that.
              speaking: inCallTogether,
              // The profile colour; absent on an older server reads as no ring.
              ringColor: inCallTogether ? null : profileRingColor(profile),
              semanticLabel: inCallTogether
                  ? '${profile.displayName}, in a call with you'
                  : null,
            ),
          ),
          const SizedBox(width: AppSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  profile.displayName,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: AppWeights.semi,
                  ),
                ),
                handleLine,
                const SizedBox(height: 2),
                subtitle,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The member card's own avatar ring, from an index into the design system's
/// closed categorical colour set - reused rather than a new palette, per the
/// "no new hue family" spirit of decision 0004. Null when the server has not
/// sent a colour at all (an older deployment), which is unknown, not zero.
Color? profileRingColor(api.UserProfile profile) {
  final index = profile.profileColor;
  if (index == null) return null;
  final cursors = AppCanvasColors.cursors;
  return cursors[index % cursors.length];
}

/// The timed-out banner: amber rather than red, because it expires on its own
/// and the error grammar reserves red for something that needs acting on.
///
/// Says exactly what is restricted rather than only that something is, and
/// offers "Lift" only to somebody who can actually lift it. A member without
/// that right still sees the badge: why they cannot hear from someone is
/// information they are entitled to.
class MemberTimeoutBadge extends StatelessWidget {
  const MemberTimeoutBadge({super.key, required this.until, this.onLift});

  /// Unix milliseconds.
  final int until;
  final VoidCallback? onLift;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final remaining = DateTime.fromMillisecondsSinceEpoch(
      until,
    ).difference(DateTime.now());

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s12,
        0,
        AppSpacing.s12,
        AppSpacing.s12,
      ),
      child: AppCallout(
        icon: AppIcons.clock,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        const TextSpan(text: 'Timed out - '),
                        TextSpan(
                          text: formatRemaining(remaining),
                          style: AppText.code.copyWith(
                            color: tokens.warnText,
                            fontSize: 12,
                          ),
                        ),
                        const TextSpan(text: ' remaining'),
                      ],
                    ),
                    style: AppText.caption.copyWith(color: tokens.warnText),
                  ),
                  Text(
                    'Can read messages and view the canvas; '
                    "can't draw, send messages, or join voice.",
                    style: AppText.caption.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (onLift != null)
              Padding(
                padding: const EdgeInsets.only(left: AppSpacing.s8),
                child: AppButton(
                  label: 'Lift',
                  variant: AppButtonVariant.ghost,
                  size: AppButtonSize.sm,
                  onPressed: onLift,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The lengths every timeout chooser offers, so no surface drifts from another.
const timeoutDurationOptions = <(String, Duration)>[
  ('5m', Duration(minutes: 5)),
  ('1h', Duration(hours: 1)),
  ('24h', Duration(hours: 24)),
  ('7d', Duration(days: 7)),
];

/// The inline timeout durations from the design: one tap, no dialog.
///
/// A dialog for "5 minutes" would be a confirmation step for something that
/// undoes itself, and the undo lives on the resulting badge rather than in a
/// toast that floats away.
///
/// Two separate defects made this unreadable in the member pane, which at
/// 236px is the narrowest surface it appears on. Both showed in one
/// screenshot, as two of the four durations rendering as empty boxes.
///
/// The buttons were four [Expanded] in a [Row]. Expanded makes each child's
/// width the row's decision rather than the label's, so at that width every
/// button was narrower than its own padding plus text and every label was
/// clipped to a fixed 16px - measured, and identical for `5m` and `24h` alike.
/// No overflow was reported for this, because Expanded forces the fit. A
/// [Wrap] lets each take the width it needs and fall to a second line when
/// there isn't any; a wider profile sheet still fits them on one.
///
/// Separately, the header's [Text] sat in a [Row] with no [Flexible], so that
/// row wanted 46px more than the pane had and reported a real overflow. That
/// one is independent of the buttons and shows at this width alone.
///
/// `timeout_chips_width_test.dart` pins both: nothing overflows, and a
/// three-character label stays wider than a two-character one.
class TimeoutDurationChips extends StatelessWidget {
  const TimeoutDurationChips({super.key, required this.onChosen});

  final void Function(Duration) onChosen;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                AppIcons.clock,
                size: AppSizes.icon16,
                color: tokens.textSecondary,
              ),
              const SizedBox(width: AppSpacing.s8),
              // Flexible, or this runs 46px past the member pane; see the class doc.
              Flexible(
                child: Text(
                  'Time out for...',
                  style: AppText.ui.copyWith(color: tokens.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s8),
          Wrap(
            spacing: AppSpacing.s8,
            runSpacing: AppSpacing.s8,
            children: [
              for (final (label, duration) in timeoutDurationOptions)
                AppButton(
                  label: label,
                  variant: AppButtonVariant.secondary,
                  size: AppButtonSize.sm,
                  semanticLabel: 'Time out for $label',
                  onPressed: () => onChosen(duration),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
