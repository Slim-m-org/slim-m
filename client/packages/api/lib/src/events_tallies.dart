// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Per-item tallies carried by live reaction and poll updates.
library;

/// One emoji and its current public count, as broadcast live.
///
/// Deliberately a different type from [ReactionSummary] (in models.dart),
/// which is what a REST read of a message returns: that shape also carries
/// `reacted`, this one never does, because who reacted is per-viewer and the
/// server never broadcasts it. Keeping them distinct types means a caller
/// cannot accidentally read `.reacted` off a live update as if it were a
/// fetched one.
class ReactionTally {
  const ReactionTally({required this.emoji, required this.count});

  final String emoji;
  final int count;

  factory ReactionTally.fromJson(Map<String, dynamic> json) => ReactionTally(
        emoji: json['emoji'] as String,
        count: json['count'] as int,
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
