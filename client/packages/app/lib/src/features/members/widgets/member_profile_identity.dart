// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The profile-first content around the header: an about line, role badges,
/// and a join date. Split out of `member_profile_sections.dart` to keep that
/// file under the review budget.
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

/// The member's own "About" text, labelled so it is not read as their typed
/// status, which has its own line under their name. [onEdit] adds a pencil
/// on your own card; with no text it becomes a prompt to write one.
class MemberProfileAbout extends StatelessWidget {
  const MemberProfileAbout({super.key, required this.about, this.onEdit});

  final String about;

  /// Opens the field this text is edited in; null on someone else's card.
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final body = Text(
      about.isEmpty ? 'Write a short bio' : about,
      style: AppText.caption.copyWith(
        color: tokens.textSecondary,
        fontStyle: about.isEmpty ? FontStyle.italic : null,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s12,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text(
                  'ABOUT',
                  style: AppText.label.copyWith(color: tokens.textSecondary),
                ),
                body,
              ],
            ),
          ),
          if (onEdit != null)
            AppIconButton(
              icon: AppIcons.edit,
              iconSize: AppSizes.icon16,
              semanticLabel: 'Edit about',
              tooltip: 'Edit about',
              size: AppIconButtonSize.sm,
              onPressed: onEdit,
            ),
        ],
      ),
    );
  }
}

/// The join date, muted, closing the name block; the invite code a moderator
/// can see rides in its tooltip rather than a line of its own.
class MemberProfileJoined extends StatelessWidget {
  const MemberProfileJoined({
    super.key,
    required this.createdAt,
    this.inviteCode,
  });

  final int createdAt;

  /// Present only for a viewer who can manage roles; see `UserProfile.inviteCode`.
  final String? inviteCode;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final joined = Text(
      formatJoinDate(createdAt),
      maxLines: 1,
      softWrap: false,
      style: AppText.caption.copyWith(color: tokens.textSecondary),
    );
    return switch (inviteCode) {
      final code? => Tooltip(
        message: 'Joined with invite $code',
        child: joined,
      ),
      null => joined,
    };
  }
}

/// The member's role badges, absent when they hold none.
class MemberProfileRoles extends StatelessWidget {
  const MemberProfileRoles({super.key, required this.roles});

  final List<String> roles;

  @override
  Widget build(BuildContext context) {
    if (roles.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s12,
      ),
      child: Wrap(
        spacing: AppSpacing.s4,
        runSpacing: AppSpacing.s4,
        children: [
          for (final role in roles)
            AppBadge(variant: AppBadgeVariant.tag, label: role),
        ],
      ),
    );
  }
}
