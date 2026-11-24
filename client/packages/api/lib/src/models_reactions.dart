// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reaction summaries: one entry per distinct emoji on a message, from the
/// calling user's point of view.
///
/// Split out of models.dart purely to stay under this repo's line budget; see
/// that file for how the pieces are recombined into one import.
library;

/// One emoji's tally on a message, plus whether the calling user is one of
/// the people who reacted with it.
class ReactionSummary {
  const ReactionSummary({
    required this.emoji,
    required this.count,
    required this.reacted,
  });

  /// The reaction emoji itself. User content, never chrome.
  final String emoji;

  /// How many people have reacted with this emoji.
  final int count;

  /// Whether the calling user is one of them, so a client can render the
  /// toggled state without a second request.
  ///
  /// Per-viewer. The live `reactions.changed` frame carries `ReactionTally`
  /// (events.dart) instead, whose flag is null from an older server.
  final bool reacted;

  factory ReactionSummary.fromJson(Map<String, dynamic> json) =>
      ReactionSummary(
        emoji: json['emoji'] as String,
        count: json['count'] as int,
        reacted: json['reacted'] as bool,
      );
}

/// One page of the people who left one reaction, as the caller may see them.
///
/// Only ids: a client resolves names and avatars from the profiles it already
/// holds. The list is already filtered for this viewer exactly as the tally
/// is, so its total length always equals the count the viewer was shown.
class ReactionUsersPage {
  const ReactionUsersPage({required this.userIds, this.nextCursor});

  /// Oldest reaction first.
  final List<String> userIds;

  /// Opaque; pass it back as `after` for the next page. Null on the last one.
  final String? nextCursor;

  factory ReactionUsersPage.fromJson(Map<String, dynamic> json) =>
      ReactionUsersPage(
        userIds: [
          for (final u in json['users'] as List<dynamic>)
            (u as Map<String, dynamic>)['user_id'] as String,
        ],
        nextCursor: json['next_cursor'] as String?,
      );
}
