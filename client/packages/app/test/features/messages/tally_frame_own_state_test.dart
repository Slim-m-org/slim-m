// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A reaction or vote made on another of the viewer's devices shows here, and
/// a tally frame that arrives after a newer one for the same message is ignored.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/features/messages/providers/poll_vote_failure.dart';
import 'package:slimm_app/src/features/messages/providers/reaction_toggle_queue.dart';
import 'package:slimm_app/src/providers/live_events.dart';

import '../../channel_history_harness.dart' show channelMessage;

const _wave = ':wave:';

api.Message _message({
  List<api.ReactionSummary> reactions = const [],
  api.Poll? poll,
}) {
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
    reactions: reactions,
    poll: poll,
  );
}

const _poll = api.Poll(
  question: 'q',
  options: [
    api.PollOption(position: 0, label: 'A', votes: 0),
    api.PollOption(position: 1, label: 'B', votes: 0),
  ],
  totalVotes: 0,
  votedOption: null,
  closeAt: null,
  closed: false,
);

api.ReactionsChanged _reactions(int count, {bool? reacted, int? version}) =>
    api.ReactionsChanged(
      channelId: 'c1',
      messageId: 'm1',
      reactions: [
        if (count > 0)
          api.ReactionTally(emoji: _wave, count: count, reacted: reacted),
      ],
      version: version,
    );

api.PollVoted _voted(List<int> votes, {int? version, int? votedOption}) =>
    api.PollVoted(
      channelId: 'c1',
      messageId: 'm1',
      options: [
        for (var i = 0; i < votes.length; i++)
          api.PollOptionTally(position: i, votes: votes[i]),
      ],
      version: version,
      votedOption: votedOption,
    );

({ProviderContainer container, void Function(api.ServerEvent) send}) _setUp(
  api.Message message,
) {
  final events = StreamController<api.ServerEvent>.broadcast(sync: true);
  addTearDown(events.close);
  final container = ProviderContainer(
    overrides: [liveEventsProvider.overrideWithValue(events.stream)],
  );
  addTearDown(container.dispose);
  container.read(messageExtrasProvider.notifier).applyMessages([message]);
  return (container: container, send: events.add);
}

api.ReactionSummary? _chip(ProviderContainer container) => container
    .read(messageExtrasProvider)['m1']!
    .reactions
    .where((r) => r.emoji == _wave)
    .firstOrNull;

void main() {
  test('a reaction added on another device lights the chip here', () {
    final (:container, :send) = _setUp(_message());

    send(_reactions(1, reacted: true, version: 1));

    expect((_chip(container)!.reacted, _chip(container)!.count), (true, 1));
  });

  test('a reaction removed on another device unlights the chip here', () {
    final held = [
      const api.ReactionSummary(emoji: _wave, count: 2, reacted: true),
    ];
    final (:container, :send) = _setUp(_message(reactions: held));

    send(_reactions(1, reacted: false, version: 1));

    expect((_chip(container)!.reacted, _chip(container)!.count), (false, 1));
  });

  test('a frame from an older server keeps the flag this client held', () {
    final held = [
      const api.ReactionSummary(emoji: _wave, count: 1, reacted: true),
    ];
    final (:container, :send) = _setUp(_message(reactions: held));

    send(_reactions(2));

    expect((_chip(container)!.reacted, _chip(container)!.count), (true, 2));
  });

  test('a reaction frame older than the one applied changes nothing', () {
    final (:container, :send) = _setUp(_message());

    send(_reactions(2, reacted: true, version: 20));
    send(_reactions(1, reacted: false, version: 10));

    expect((_chip(container)!.reacted, _chip(container)!.count), (true, 2));
  });

  test('while a toggle is out, a frame keeps the flag the viewer chose', () {
    final (:container, :send) = _setUp(_message());
    container.read(
      reactionTogglesInFlightProvider,
    )[(messageId: 'm1', emoji: _wave)] = null;
    container
        .read(messageExtrasProvider.notifier)
        .applyLocalReactionToggle('m1', _wave, true);

    send(_reactions(1, reacted: false, version: 1));

    expect((_chip(container)!.reacted, _chip(container)!.count), (true, 2));
  });

  test('a vote cast on another device shows as this viewer\'s pick', () {
    final (:container, :send) = _setUp(_message(poll: _poll));

    send(_voted([0, 1], version: 1, votedOption: 1));

    final poll = container.read(messageExtrasProvider)['m1']!.poll!;
    expect(poll.votedOption, 1);
    expect(poll.totalVotes, 1);
  });

  test('a vote frame older than the one applied changes nothing', () {
    final (:container, :send) = _setUp(_message(poll: _poll));

    send(_voted([2, 3], version: 20));
    send(_voted([1, 1], version: 10));

    final poll = container.read(messageExtrasProvider)['m1']!.poll!;
    expect([for (final o in poll.options) o.votes], [2, 3]);
  });

  test('a vote frame does not overwrite a vote still on its way', () {
    final (:container, :send) = _setUp(_message(poll: _poll));
    container.read(pollVotesInFlightProvider)['m1'] = null;
    container.read(messageExtrasProvider.notifier).applyLocalVote('m1', 0);

    send(_voted([0, 1], version: 1, votedOption: 1));

    final poll = container.read(messageExtrasProvider)['m1']!.poll!;
    expect(poll.votedOption, 0);
  });
}
