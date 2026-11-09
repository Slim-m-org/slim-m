// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A poll vote the server refused, kept with the ballot so it can be resent.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What a viewer voted: one [option], or on a ranked poll a [ranking] best first.
class PollBallot {
  const PollBallot({this.option, this.ranking});

  final int? option;
  final List<int>? ranking;
}

class PollVoteFailure {
  const PollVoteFailure(this.message, this.ballot);

  /// What went wrong, as a sentence for the poll to show.
  final String message;
  final PollBallot ballot;
}

/// Keyed by message, and null while the last vote on it stands.
final pollVoteFailureProvider = StateProvider.family<PollVoteFailure?, String>(
  (ref, messageId) => null,
);

/// A ballot tapped while an earlier one on the same poll was still out.
typedef QueuedPollBallot = ({PollBallot ballot, String whatFailed});

/// The messages with a vote still out, each with the newest ballot tapped
/// meanwhile, which goes out once the first answer is in.
final pollVotesInFlightProvider = Provider<Map<String, QueuedPollBallot?>>(
  (ref) => <String, QueuedPollBallot?>{},
);
