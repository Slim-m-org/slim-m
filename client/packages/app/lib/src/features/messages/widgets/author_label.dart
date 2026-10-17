// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The single place a message author's display name is resolved, closing the
/// recorded debt that a renamed author's already-cached messages never
/// reconciled: `message_row_identity.dart`, `channel_search.dart`,
/// `pinned_messages_sheet.dart` and `command_palette_items.dart` used to each
/// carry their own copy of the "cached name, or a fallback for a missing
/// author" rule and none of them ever refreshed it.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

/// [authorId]'s name as of the last time [profiles] was asked about them.
///
/// A `null` [authorId] is an author already anonymized before this row was
/// even fetched. A [profiles] entry present but `null` is the same fact
/// learned live - the batch lookup asked and nobody answered - and that must
/// win over [cachedDisplayName], or a rename that resolves to "gone" would
/// keep showing the deleted account's last-known name forever, which is
/// exactly the resurrection the local cache is not allowed to cause. An id
/// absent from [profiles] entirely just means nobody has asked yet, so the
/// row's own cached copy (accurate as of whenever it was written) is the
/// best answer available until [profiles] catches up.
String authorLabel({
  required String? authorId,
  required String? cachedDisplayName,
  required Map<String, api.UserProfile?> profiles,
}) => _label(
  authorId: authorId,
  cachedDisplayName: cachedDisplayName,
  present: authorId != null && profiles.containsKey(authorId),
  profile: authorId == null ? null : profiles[authorId],
);

/// One id's slice of the batch map: whether it has been asked about at all,
/// and what it resolved to. See `providers/user_profiles.dart`'s
/// `authorResolution`, which selects this out of the map without depending
/// on the map's own identity.
typedef AuthorResolution = ({bool present, api.UserProfile? profile});

/// Equivalent to [authorLabel], for a caller that already selected its own
/// author's [AuthorResolution] out of the batch map via a `.select` (a row
/// watching the whole map rebuilt on every other author's resolve, not only
/// its own).
String authorLabelResolved({
  required String? authorId,
  required String? cachedDisplayName,
  required AuthorResolution resolution,
}) => _label(
  authorId: authorId,
  cachedDisplayName: cachedDisplayName,
  present: resolution.present,
  profile: resolution.profile,
);

String _label({
  required String? authorId,
  required String? cachedDisplayName,
  required bool present,
  required api.UserProfile? profile,
}) {
  if (authorId == null) return 'Deleted user';
  if (present) return profile?.displayName ?? 'Deleted user';
  return cachedDisplayName ?? 'Unknown';
}

/// The Bot/Webhook badge chips for [profile], meant to sit directly after a
/// name in a `Row`, as a plain (non-`Flexible`) sibling.
///
/// `docs/decisions/0030-incoming-webhooks.md` calls the always-visible
/// `Webhook` badge the entire mitigation for a webhook's caller-chosen
/// `username`: nothing else tells a reader that a claimed name is not a
/// person, so the badge must never be squeezable off the line by a narrow
/// layout, a theme, or a long name. Giving it fixed, non-flexible size next
/// to a `Flexible` name - the shape `message_row_identity.dart`'s
/// `MessageRowHeader` already uses - means the name shrinks under an
/// ellipsis first and the badge always renders at full size. Every surface
/// that draws a message author's name outside that row - a reply quote, a
/// thread parent card, a forwarded message, a search hit, a pinned or saved
/// entry, a thread-list row, a command-palette hit - draws its badge from
/// here rather than re-deriving the two flags.
List<Widget> authorBadges(api.UserProfile? profile) {
  final isWebhook = profile?.isWebhook ?? false;
  final isBot = profile?.isBot ?? false;
  return [
    if (isWebhook) ...[
      const SizedBox(width: AppSpacing.s4),
      const AppBadge(variant: AppBadgeVariant.tag, label: 'Webhook'),
    ],
    if (isBot) ...[
      const SizedBox(width: AppSpacing.s4),
      const AppBadge(variant: AppBadgeVariant.tag, label: 'Bot'),
    ],
  ];
}

/// A resolved author [name], its [authorBadges], and an optional [secondary]
/// bit of text after it (a message snippet, a channel label), all on one
/// row that ellipsizes [name] and [secondary] independently around the
/// badge - never the badge itself.
///
/// This is the shape every dense list row that names a message's author
/// needs and none of them had: a reply quote, a thread parent card, a
/// forwarded message, a search hit, a pinned or saved entry, a thread-list
/// row, and a command-palette hit each used to draw a plain `Text(name)`
/// with nothing beside it for a badge to attach to, which is exactly the
/// suppression `docs/decisions/0030-incoming-webhooks.md` warns against: a
/// webhook's caller-chosen `username` is safe only because the `Webhook`
/// badge sits unconditionally next to it, and a badge that can be crowded
/// off a dense line by a long name is no badge at all.
///
/// [name] is [Flexible] and may ellipsize under a long or hostile value;
/// the badge is a plain sibling laid out at its natural size before either
/// [Flexible] gets a share of what is left, so it renders in full
/// regardless of how long [name] or [secondary] are - `RenderFlex` sizes
/// non-flexible children first. `MainAxisSize.min` keeps this row from
/// claiming more width than its own content when a caller places something
/// else after it in the same row (`ForwardedMessageCard`'s timestamp).
class AuthorNameLine extends StatelessWidget {
  const AuthorNameLine({
    super.key,
    required this.name,
    required this.profile,
    this.style,
    this.secondary,
    this.secondaryStyle,
  });

  final String name;
  final api.UserProfile? profile;
  final TextStyle? style;

  /// Shares the line's remaining space with [name] once the badge has taken
  /// its own; null when a surface has nothing to say after the name.
  final String? secondary;
  final TextStyle? secondaryStyle;

  @override
  Widget build(BuildContext context) {
    final secondary = this.secondary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            name,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        ...authorBadges(profile),
        if (secondary != null) ...[
          const SizedBox(width: AppSpacing.s8),
          Flexible(
            flex: 2,
            child: Text(
              secondary,
              style: secondaryStyle ?? style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }
}
