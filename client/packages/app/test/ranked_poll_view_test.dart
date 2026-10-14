// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Ranked polls: a ballot is built tap by tap and sent once, whole; the
/// results show the runoff's last round with the winner marked; and a
/// ranked poll's runoff and the viewer's own ranking survive the live merge.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/message_extras.dart';
import 'package:slimm_app/src/widgets/poll_view.dart';
import 'package:slimm_design_system/design_system.dart';

import 'channel_history_harness.dart';

const _labels = ['Beach', 'City', 'Hills'];

api.Poll _poll({
  List<int> firstChoices = const [0, 0, 0],
  List<int>? votedRanking,
  api.PollRunoff? runoff,
  bool closed = false,
}) => api.Poll(
  question: 'Where to?',
  options: [
    for (var i = 0; i < _labels.length; i++)
      api.PollOption(position: i, label: _labels[i], votes: firstChoices[i]),
  ],
  totalVotes: firstChoices.fold(0, (a, b) => a + b),
  votedOption: votedRanking?.first,
  closeAt: null,
  closed: closed,
  ranked: true,
  votedRanking: votedRanking,
  runoff: runoff,
);

const _decided = api.PollRunoff(
  rounds: [
    {0: 2, 1: 1, 2: 2},
    {0: 2, 2: 3},
  ],
  winner: 2,
);

Future<List<List<int>>> _pump(WidgetTester tester, api.Poll poll) async {
  final sent = <List<int>>[];
  await tester.pumpWidget(
    MaterialApp(
      builder: (_, child) => ProviderScope(child: child!),
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: PollView(poll: poll, onVote: (_) {}, onRank: sent.add),
      ),
    ),
  );
  return sent;
}

Finder _rankMark(String label, int rank) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
  matching: find.text('$rank'),
);

void main() {
  testWidgets('taps build a numbered ballot that is sent once, whole', (
    tester,
  ) async {
    final sent = await _pump(tester, _poll());
    expect(find.text('Tap options in order of preference.'), findsOneWidget);

    await tester.tap(find.text('Hills'));
    await tester.pump();
    await tester.tap(find.text('Beach'));
    await tester.pump();
    expect(_rankMark('Hills', 1), findsOneWidget);
    expect(_rankMark('Beach', 2), findsOneWidget);
    expect(
      sent,
      isEmpty,
      reason: 'nothing is sent until the ballot is submitted',
    );

    await tester.tap(find.text('Submit ranking'));
    await tester.pump();
    expect(sent, [
      [2, 0],
    ]);
  });

  testWidgets('tapping a ranked option takes it off and renumbers the rest', (
    tester,
  ) async {
    final sent = await _pump(tester, _poll());
    for (final label in ['City', 'Beach', 'Hills']) {
      await tester.tap(find.text(label));
      await tester.pump();
    }
    await tester.tap(find.text('City'));
    await tester.pump();
    expect(_rankMark('Beach', 1), findsOneWidget);
    expect(_rankMark('Hills', 2), findsOneWidget);

    await tester.tap(find.text('Submit ranking'));
    await tester.pump();
    expect(sent.single, [0, 2]);
  });

  testWidgets('results show the last round, the winner and your ranks', (
    tester,
  ) async {
    final sent = await _pump(
      tester,
      _poll(firstChoices: [2, 1, 2], votedRanking: [1, 2], runoff: _decided),
    );
    expect(find.text('40%'), findsOneWidget);
    expect(find.text('60%'), findsOneWidget);
    expect(find.text('Out'), findsOneWidget, reason: 'City dropped out');
    expect(find.byIcon(AppIcons.pollLeading), findsOneWidget);
    expect(find.text('5 votes - decided in round 2'), findsOneWidget);
    expect(_rankMark('City', 1), findsOneWidget);
    expect(_rankMark('Hills', 2), findsOneWidget);

    await tester.tap(find.text('Beach'));
    await tester.pump();
    expect(
      sent,
      isEmpty,
      reason: 'a cast ballot is not changed by a stray tap',
    );

    await tester.tap(find.text('Change ranking'));
    await tester.pump();
    expect(find.text('Submit ranking'), findsOneWidget);
    expect(
      _rankMark('City', 1),
      findsNothing,
      reason: 'a new ballot starts empty',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(_rankMark('City', 1), findsOneWidget);
  });

  testWidgets('a closed, tied poll says so and takes no ballot', (
    tester,
  ) async {
    final sent = await _pump(
      tester,
      _poll(
        firstChoices: [2, 2, 0],
        closed: true,
        runoff: const api.PollRunoff(
          rounds: [
            {0: 2, 1: 2, 2: 0},
            {0: 2, 1: 2},
          ],
          winner: null,
        ),
      ),
    );
    expect(find.text('4 votes - tied'), findsOneWidget);
    expect(find.text('Submit ranking'), findsNothing);
    expect(find.text('Change ranking'), findsNothing);
    expect(find.byIcon(AppIcons.pollLeading), findsNothing);
    await tester.tap(find.text('Beach'));
    await tester.pump();
    expect(sent, isEmpty);
  });

  test(
    'the live merge keeps a ranked poll ranked and takes the new runoff',
    () async {
      final events = StreamController<api.ServerEvent>.broadcast();
      addTearDown(events.close);
      final container = ProviderContainer(
        overrides: [liveEventsProvider.overrideWithValue(events.stream)],
      );
      addTearDown(container.dispose);
      final extras = container.read(messageExtrasProvider.notifier);
      final base = channelMessage(1);
      extras.applyMessages([
        api.Message(
          id: base.id,
          channelId: base.channelId,
          authorId: base.authorId,
          authorDisplayName: base.authorDisplayName,
          seq: base.seq,
          content: base.content,
          createdAt: base.createdAt,
          editedAt: null,
          poll: _poll(),
        ),
      ]);

      extras.applyLocalVote(base.id, 2, ranking: [2, 0]);
      var poll = extras.extrasFor(base.id).poll!;
      expect(poll.ranked, isTrue);
      expect(poll.votedRanking, [2, 0]);
      expect(poll.options[2].votes, 1);

      events.add(
        api.PollVoted(
          channelId: base.channelId,
          messageId: base.id,
          options: const [api.PollOptionTally(position: 2, votes: 1)],
          runoff: const api.PollRunoff(
            rounds: [
              {0: 0, 1: 0, 2: 1},
            ],
            winner: 2,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      poll = extras.extrasFor(base.id).poll!;
      expect(poll.runoff?.winner, 2);
      expect(poll.votedRanking, [
        2,
        0,
      ], reason: 'the broadcast never carries it');
      expect(poll.ranked, isTrue);
    },
  );
}
