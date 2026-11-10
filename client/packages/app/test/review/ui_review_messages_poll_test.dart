// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Review captures of `message-poll`: a poll inside the real transcript, open,
/// voted, closed, ranked (a ballot in progress and a decided result) and with
/// its vote refused, at phone and desktop width in both themes. PNGs are
/// written only under SLIMM_UI_SNAPSHOTS=1; otherwise each case asserts a
/// clean layout.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/poll_vote_failure.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_messages_support.dart';

const _surface = 'message-poll';
const _ada = 'user-ada';

api.Poll _poll({
  List<int> votes = const [2, 11, 3],
  int? voted,
  bool closed = false,
}) => api.Poll(
  question: 'Which map for the next event?',
  options: [
    for (final (i, label) in const ['Ruins', 'Harbor', 'Foundry'].indexed)
      api.PollOption(position: i, label: label, votes: votes[i]),
  ],
  totalVotes: votes.fold(0, (a, b) => a + b),
  votedOption: voted,
  closeAt: closed ? 1753600000000 : null,
  closed: closed,
);

api.Poll _ranked({
  List<int> firstChoices = const [0, 0, 0],
  List<int>? votedRanking,
  api.PollRunoff? runoff,
}) => api.Poll(
  question: 'Where should the summer trip go?',
  options: [
    for (final (i, label) in const ['Beach', 'City', 'Hills'].indexed)
      api.PollOption(position: i, label: label, votes: firstChoices[i]),
  ],
  totalVotes: firstChoices.fold(0, (a, b) => a + b),
  votedOption: votedRanking?.first,
  closeAt: null,
  closed: false,
  ranked: true,
  votedRanking: votedRanking,
  runoff: runoff,
);

const _decided = api.PollRunoff(
  rounds: [
    {0: 4, 1: 3, 2: 2},
    {0: 4, 1: 5},
  ],
  winner: 1,
);

List<api.Message> _withPoll(api.Poll poll) => [
  reviewMessage(1, _ada, 'putting it to a vote so we can book the room'),
  reviewMessage(2, _ada, '', poll: poll),
];

Future<void> _rankBallot(ReviewScene scene) async {
  for (final label in const ['Hills', 'Beach']) {
    await scene.tester.tap(find.text(label));
    await scene.frames(1);
  }
}

Future<void> _refuseVote(ReviewScene scene) async {
  scene.container
      .read(pollVoteFailureProvider('r-2').notifier)
      .state = const PollVoteFailure(
    'Could not send your vote: this poll has closed.',
    PollBallot(option: 1),
  );
  await scene.frames(1);
}

typedef _Case = ({api.Poll poll, SceneStep? act});

final _cases = <String, _Case>{
  'open': (poll: _poll(), act: null),
  'voted': (poll: _poll(voted: 1), act: null),
  'closed': (poll: _poll(voted: 1, closed: true), act: null),
  'ranked-ballot': (poll: _ranked(), act: _rankBallot),
  'ranked-result': (
    poll: _ranked(
      firstChoices: const [4, 3, 2],
      votedRanking: const [2, 1],
      runoff: _decided,
    ),
    act: null,
  ),
  'vote-refused': (poll: _poll(), act: _refuseVote),
};

void main() {
  setUpAll(loadRealFonts);

  for (final entry in _cases.entries) {
    for (final viewport in reviewViewports.keys) {
      testWidgets('${entry.key} at $viewport', (tester) async {
        await captureMessages(
          tester,
          surface: _surface,
          state: entry.key,
          viewport: viewport,
          messages: _withPoll(entry.value.poll),
          act: entry.value.act,
        );
      });
    }
  }
}
