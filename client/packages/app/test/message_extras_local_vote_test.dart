// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `applyLocalVote` is the optimistic tally a poll shows the instant you pick an
/// option, before the `poll.voted` broadcast confirms it. Its arithmetic was
/// untested: a first vote adds one to the chosen option, changing your vote
/// moves the one you already cast, and re-picking the same option does nothing.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';

import 'channel_history_harness.dart';

api.Message _withPoll(api.Poll? poll) {
  final base = channelMessage(1);
  return api.Message(
    id: base.id,
    channelId: base.channelId,
    authorId: base.authorId,
    authorDisplayName: base.authorDisplayName,
    seq: base.seq,
    content: base.content,
    createdAt: base.createdAt,
    editedAt: null,
    poll: poll,
  );
}

api.Poll _poll({int? voted, int votesA = 0, int votesB = 0}) => api.Poll(
  question: 'q',
  options: [
    api.PollOption(position: 0, label: 'A', votes: votesA),
    api.PollOption(position: 1, label: 'B', votes: votesB),
  ],
  totalVotes: votesA + votesB,
  votedOption: voted,
  closeAt: null,
  closed: false,
);

int _votes(MessageExtrasController c, int position) => c
    .extrasFor('m1')
    .poll!
    .options
    .firstWhere((o) => o.position == position)
    .votes;

void main() {
  MessageExtrasController seed(ProviderContainer container, api.Poll poll) {
    final c = container.read(messageExtrasProvider.notifier);
    c.applyMessages([_withPoll(poll)]);
    return c;
  }

  test('a first vote adds one to the chosen option and records it', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final c = seed(container, _poll());

    c.applyLocalVote('m1', 1);

    expect(_votes(c, 1), 1);
    expect(_votes(c, 0), 0);
    expect(c.extrasFor('m1').poll!.votedOption, 1);
  });

  test('changing your vote moves the one you already cast', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final c = seed(container, _poll(voted: 0, votesA: 1));

    c.applyLocalVote('m1', 1);

    expect(_votes(c, 0), 0);
    expect(_votes(c, 1), 1);
    expect(c.extrasFor('m1').poll!.votedOption, 1);
  });

  test('re-picking the option you already chose changes nothing', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final c = seed(container, _poll(voted: 1, votesB: 1));

    c.applyLocalVote('m1', 1);

    expect(_votes(c, 1), 1);
  });

  test('a message with no poll is left untouched', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final c = container.read(messageExtrasProvider.notifier);
    c.applyMessages([_withPoll(null)]);

    c.applyLocalVote('m1', 1);

    expect(c.extrasFor('m1').poll, isNull);
  });
}
