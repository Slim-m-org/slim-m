// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Per-item tallies carried by live reaction and poll updates.
library;

/// One emoji and its current count, as one viewer receives it live.
///
/// A different type from [ReactionSummary] (in models.dart), the REST read's
/// shape: [reacted] here is null from a server that predates it, so a caller
/// has to decide what an unknown flag means rather than read a false one.
class ReactionTally {
  const ReactionTally({required this.emoji, required this.count, this.reacted});

  final String emoji;
  final int count;

  /// Whether the receiving user is among the reactors; null from an older server.
  final bool? reacted;

  factory ReactionTally.fromJson(Map<String, dynamic> json) => ReactionTally(
        emoji: json['emoji'] as String,
        count: json['count'] as int,
        reacted: json['reacted'] as bool?,
      );
}

/// One poll option's position and its current public vote count, as
/// broadcast live. Unlike [PollOption] (in models.dart), it carries no
/// `label`: a poll's options and their labels are fixed at creation and never
/// change, so only the tally needs to travel over the live update.
class PollOptionTally {
  const PollOptionTally({required this.position, required this.votes});

  final int position;
  final int votes;

  factory PollOptionTally.fromJson(Map<String, dynamic> json) =>
      PollOptionTally(
        position: json['position'] as int,
        votes: json['votes'] as int,
      );
}
