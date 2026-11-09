// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The poll a viewer sees between casting a vote and the server answering,
/// and the way back when the server refuses it.
library;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:slimm_api/api.dart' as api;

/// [poll] with the viewer's own vote applied, or null when it changes nothing.
/// A [ranking] counts as a vote for its first choice; the runoff waits for
/// the broadcast.
api.Poll? pollAfterLocalVote(api.Poll poll, int option, {List<int>? ranking}) {
  final previous = poll.votedOption;
  if (previous == option && ranking == null) return null;
  int moved(api.PollOption o) =>
      (o.position == option ? 1 : 0) - (o.position == previous ? 1 : 0);
  final options = [
    for (final o in poll.options)
      api.PollOption(
        position: o.position,
        label: o.label,
        votes: (o.votes + moved(o)).clamp(0, 1 << 31),
      ),
  ];
  return poll.copyWith(
    options: options,
    totalVotes: options.fold<int>(0, (sum, o) => sum + o.votes),
    votedOption: option,
    votedRanking: ranking,
  );
}

/// [current] with a refused vote taken back: [before] is the poll as it stood
/// ahead of the vote and [applied] the poll right after it.
///
/// The viewer's own choice returns to [before] unless a later vote has already
/// replaced it. The counts return too, unless a broadcast has rewritten them
/// since: those come from the server and never held the refused vote.
api.Poll pollAfterRevertedVote({
  required api.Poll before,
  required api.Poll applied,
  required api.Poll current,
}) {
  final ownVoteIntact =
      current.votedOption == applied.votedOption &&
      listEquals(current.votedRanking, applied.votedRanking);
  final tallyIntact = _sameVotes(current.options, applied.options);
  return api.Poll(
    question: current.question,
    options: tallyIntact ? before.options : current.options,
    totalVotes: tallyIntact ? before.totalVotes : current.totalVotes,
    votedOption: ownVoteIntact ? before.votedOption : current.votedOption,
    closeAt: current.closeAt,
    closed: current.closed,
    ranked: current.ranked,
    votedRanking: ownVoteIntact ? before.votedRanking : current.votedRanking,
    runoff: tallyIntact ? before.runoff : current.runoff,
  );
}

bool _sameVotes(List<api.PollOption> a, List<api.PollOption> b) =>
    listEquals([for (final o in a) o.votes], [for (final o in b) o.votes]);
