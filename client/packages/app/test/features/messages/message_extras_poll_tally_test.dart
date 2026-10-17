// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A `poll.voted` broadcast refreshes everyone's tally, and the client merge
/// behind it had no test. Two things must hold: the broadcast updates the vote
/// counts but must not touch this viewer's own votedOption (per-viewer, never
/// broadcast), and a tally for a message whose poll this client has not cached
/// is dropped rather than conjuring a poll from nothing.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';

import '../../channel_history_harness.dart';

Future<void> _settle() => Future<void>.delayed(Duration.zero);

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

void main() {
  test(
    'a broadcast refreshes the counts but keeps this viewer\'s own vote',
    () async {
      final events = StreamController<api.ServerEvent>.broadcast();
      addTearDown(events.close);
      final container = ProviderContainer(
        overrides: [liveEventsProvider.overrideWithValue(events.stream)],
      );
      addTearDown(container.dispose);
      final c = container.read(messageExtrasProvider.notifier);
      c.applyMessages([_withPoll(_poll(voted: 0, votesA: 1, votesB: 2))]);

      events.add(
        const api.PollVoted(
          channelId: 'c1',
          messageId: 'm1',
          // Only option 1 changes; option 0 is not named and must be kept.
          options: [api.PollOptionTally(position: 1, votes: 9)],
        ),
      );
      await _settle();

      final poll = c.extrasFor('m1').poll!;
      int votes(int p) => poll.options.firstWhere((o) => o.position == p).votes;
      expect(votes(1), 9);
      expect(
        votes(0),
        1,
        reason: 'an option absent from the tally keeps its count',
      );
      expect(poll.totalVotes, 10);
      expect(
        poll.votedOption,
        0,
        reason: 'the broadcast never carries who voted',
      );
    },
  );

  test('a tally for an uncached poll is dropped', () async {
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    final container = ProviderContainer(
      overrides: [liveEventsProvider.overrideWithValue(events.stream)],
    );
    addTearDown(container.dispose);
    final c = container.read(messageExtrasProvider.notifier);
    c.applyMessages([_withPoll(null)]);

    events.add(
      const api.PollVoted(
        channelId: 'c1',
        messageId: 'm1',
        options: [api.PollOptionTally(position: 0, votes: 5)],
      ),
    );
    await _settle();

    expect(c.extrasFor('m1').poll, isNull);
  });
}
