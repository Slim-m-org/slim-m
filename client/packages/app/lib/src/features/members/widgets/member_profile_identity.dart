// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The profile-first content between the header and the actions: an about
/// line, role badges, and a join date. Split out of `member_profile_sections
/// .dart` to keep that file under the review budget.
///
/// Each piece is *absent* rather than present-and-empty, the same rule the
/// rest of the card follows: an account with no about line shows no about
/// row at all, not an empty one.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

const List<String> _shortMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "Joined Mar 2026", from Unix milliseconds.
String formatJoinDate(int createdAtMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(createdAtMs);
  return 'Joined ${_shortMonths[dt.month - 1]} ${dt.year}';
}

/// A short "about" paragraph under the status line.
class MemberProfileAbout extends StatelessWidget {
  const MemberProfileAbout({super.key, required this.about});

  final String about;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s12,
      ),
      child: Text(
        about,
        style: AppText.caption.copyWith(color: tokens.textSecondary),
      ),
    );
  }
}

/// Role badges on the left, the join date on the right.
class MemberProfileRolesAndJoin extends StatelessWidget {
  const MemberProfileRolesAndJoin({
    super.key,
    required this.roles,
    required this.createdAt,
    this.inviteCode,
  });

  final List<String> roles;
  final int createdAt;

  /// Present only for a viewer who can manage roles; see `UserProfile.inviteCode`.
  final String? inviteCode;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s12,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Wrap(
              spacing: AppSpacing.s4,
              runSpacing: AppSpacing.s4,
              children: [
                for (final role in roles)
                  AppBadge(variant: AppBadgeVariant.tag, label: role),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.s8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatJoinDate(createdAt),
                maxLines: 1,
                softWrap: false,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
              if (inviteCode case final code?)
                Text(
                  'with invite $code',
                  maxLines: 1,
                  softWrap: false,
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
