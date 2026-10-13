// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A poll with a closing time counts down and closes on time on its own,
/// without waiting for the server to say so.
library;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/widgets/poll_view.dart';
import 'package:slimm_design_system/design_system.dart';

api.Poll _poll(int? closeAt, {int votes = 2}) => api.Poll(
  question: 'Lunch?',
  options: [
    api.PollOption(position: 0, label: 'Tacos', votes: votes),
    const api.PollOption(position: 1, label: 'Ramen', votes: 0),
  ],
  totalVotes: votes,
  votedOption: null,
  closeAt: closeAt,
  closed: false,
);

Future<List<int>> _pump(WidgetTester tester, api.Poll poll) async {
  final votes = <int>[];
  await tester.pumpWidget(
    MaterialApp(
      builder: (_, child) => ProviderScope(child: child!),
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: PollView(poll: poll, onVote: votes.add),
      ),
    ),
  );
  return votes;
}

void main() {
  testWidgets('counts down, then closes and stops taking taps', (tester) async {
    final closeAt = clock.now().add(const Duration(seconds: 90));
    final votes = await _pump(tester, _poll(closeAt.millisecondsSinceEpoch));

    expect(find.text('2 votes - Closes in 1 min.'), findsOneWidget);
    expect(find.text('CLOSED'), findsNothing);

    await tester.pump(const Duration(seconds: 60));
    expect(find.text('2 votes - Closes in under a minute.'), findsOneWidget);

    await tester.pump(const Duration(seconds: 31));
    expect(find.text('CLOSED'), findsOneWidget);
    expect(find.text('2 votes'), findsOneWidget);
    await tester.tap(find.text('Ramen'));
    expect(votes, isEmpty, reason: 'a poll past its close takes no vote');
  });

  testWidgets('a far-off close reads in hours, then days', (tester) async {
    final now = clock.now();
    await _pump(
      tester,
      _poll(now.add(const Duration(hours: 5)).millisecondsSinceEpoch),
    );
    expect(find.text('2 votes - Closes in 5 h.'), findsOneWidget);

    await _pump(
      tester,
      _poll(now.add(const Duration(days: 3)).millisecondsSinceEpoch, votes: 0),
    );
    expect(
      find.text('No votes yet. Tap an option to vote. Closes in 3 days.'),
      findsOneWidget,
    );
  });

  testWidgets('a poll with no close says nothing about closing', (
    tester,
  ) async {
    await _pump(tester, _poll(null));
    expect(find.text('2 votes'), findsOneWidget);
  });
}
