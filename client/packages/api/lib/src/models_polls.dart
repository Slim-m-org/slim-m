// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Polls: a message that carries a question with options fixed at creation.
///
/// Split out of models.dart purely to stay under this repo's line budget; see
/// that file for how the pieces are recombined into one import.
library;

/// A poll attached to a message. Options are ordered and fixed at creation;
/// only their tallies and [closed] change afterward.
class Poll {
  const Poll({
    required this.question,
    required this.options,
    required this.totalVotes,
    required this.votedOption,
    required this.closeAt,
    required this.closed,
    this.ranked = false,
    this.votedRanking,
    this.runoff,
  });

  final String question;
  final List<PollOption> options;

  /// The sum of every option's count.
  final int totalVotes;

  /// The 0-based position the calling user picked, or null if they have not
  /// voted. Per-viewer, exactly like a reaction's `reacted`: never present
  /// for anyone but the voter themselves.
  final int? votedOption;

  /// Unix milliseconds; null means the poll never closes.
  final int? closeAt;

  /// Whether the server's own clock already considers this past [closeAt].
  /// Voting is refused server-side regardless of what a client believes this
  /// to be.
  final bool closed;

  /// Voters rank the options; [options] votes and [votedOption] are then
  /// first choices, and [runoff] carries the result.
  final bool ranked;

  /// The calling user's own ranking, best first, on a ranked poll.
  final List<int>? votedRanking;

  final PollRunoff? runoff;

  Poll copyWith({
    List<PollOption>? options,
    int? totalVotes,
    int? votedOption,
    List<int>? votedRanking,
    PollRunoff? runoff,
  }) =>
      Poll(
        question: question,
        options: options ?? this.options,
        totalVotes: totalVotes ?? this.totalVotes,
        votedOption: votedOption ?? this.votedOption,
        closeAt: closeAt,
        closed: closed,
        ranked: ranked,
        votedRanking: votedRanking ?? this.votedRanking,
        runoff: runoff ?? this.runoff,
      );

  factory Poll.fromJson(Map<String, dynamic> json) => Poll(
        question: json['question'] as String,
        options: (json['options'] as List<dynamic>)
            .map((o) => PollOption.fromJson(o as Map<String, dynamic>))
            .toList(growable: false),
        totalVotes: json['total_votes'] as int,
        votedOption: json['voted_option'] as int?,
        closeAt: json['close_at'] as int?,
        closed: json['closed'] as bool,
        ranked: json['ranked'] as bool? ?? false,
        votedRanking: (json['voted_ranking'] as List<dynamic>?)
            ?.map((p) => p as int)
            .toList(growable: false),
        runoff: json['runoff'] is Map<String, dynamic>
            ? PollRunoff.fromJson(json['runoff'] as Map<String, dynamic>)
            : null,
      );
}

/// An instant-runoff count. Each round counts every ballot for its best
/// option still running; an option with more than half wins, otherwise
/// every option tied for fewest drops. [winner] is null for no votes or a
/// tie.
class PollRunoff {
  const PollRunoff({required this.rounds, required this.winner});

  /// Each round's votes by option position, for the options still running.
  final List<Map<int, int>> rounds;
  final int? winner;

  factory PollRunoff.fromJson(Map<String, dynamic> json) => PollRunoff(
        rounds: [
          for (final round in json['rounds'] as List<dynamic>)
            {
              for (final count
                  in (round as List<dynamic>).cast<Map<String, dynamic>>())
                count['position'] as int: count['votes'] as int,
            },
        ],
        winner: json['winner'] as int?,
      );
}

/// One fixed option on a poll and its current public tally. Who picked it is
/// never revealed by this or any other read; only the calling user's own
/// [Poll.votedOption] is.
class PollOption {
  const PollOption({
    required this.position,
    required this.label,
    required this.votes,
  });

  /// 0-based, fixed at creation; also the option's identity.
  final int position;
  final String label;
  final int votes;

  factory PollOption.fromJson(Map<String, dynamic> json) => PollOption(
        position: json['position'] as int,
        label: json['label'] as String,
        votes: json['votes'] as int,
      );
}
