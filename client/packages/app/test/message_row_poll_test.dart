// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The poll a message can carry, rendered inside the message row.
///
/// Split out of `message_row_test.dart`, which sits against the file budget:
/// a poll is its own widget with its own behaviour (voting, and refusing a
/// vote once closed), so it reads better beside the row's other parts than
/// buried in the row's own rendering tests.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/message_extras.dart' show MessageExtras;
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';

import 'message_row_harness.dart';

void main() {
  api.Poll poll({int? votedOption, bool closed = false}) => api.Poll(
    question: 'Best editor?',
    options: const [
      api.PollOption(position: 0, label: 'Vim', votes: 2),
      api.PollOption(position: 1, label: 'Emacs', votes: 1),
    ],
    totalVotes: 3,
    votedOption: votedOption,
    closeAt: null,
    closed: closed,
  );

  testWidgets('renders the question and every option', (tester) async {
    await tester.pumpWidget(
      harness(
        MessageRow(
          message: message(),
          grouped: false,
          showNewDivider: false,
          knownUsernames: const {},
          actions: noActions,
          editing: false,
          callbacks: MessageRowCallbacks(
            onRetry: () {},
            onDiscard: () {},
            onPickReaction: (_) {},
            onReactionTap: (_) {},
            onVote: (_) {},
            onSubmitEdit: (_) {},
            onCancelEdit: () {},
          ),
          extras: MessageExtras(poll: poll()),
        ),
      ),
    );

    expect(find.text('Best editor?'), findsOneWidget);
    expect(find.text('Vim'), findsOneWidget);
    expect(find.text('Emacs'), findsOneWidget);
    expect(find.text('3 votes'), findsOneWidget);
  });

  testWidgets('tapping an option casts a vote for its position', (
    tester,
  ) async {
    int? voted;
    await tester.pumpWidget(
      harness(
        MessageRow(
          message: message(),
          grouped: false,
          showNewDivider: false,
          knownUsernames: const {},
          actions: noActions,
          editing: false,
          callbacks: MessageRowCallbacks(
            onRetry: () {},
            onDiscard: () {},
            onPickReaction: (_) {},
            onReactionTap: (_) {},
            onVote: (option) => voted = option,
            onSubmitEdit: (_) {},
            onCancelEdit: () {},
          ),
          extras: MessageExtras(poll: poll()),
        ),
      ),
    );

    await tester.tap(find.text('Emacs'));
    expect(voted, 1);
  });

  testWidgets('a closed poll does not accept a tap', (tester) async {
    int? voted;
    await tester.pumpWidget(
      harness(
        MessageRow(
          message: message(),
          grouped: false,
          showNewDivider: false,
          knownUsernames: const {},
          actions: noActions,
          editing: false,
          callbacks: MessageRowCallbacks(
            onRetry: () {},
            onDiscard: () {},
            onPickReaction: (_) {},
            onReactionTap: (_) {},
            onVote: (option) => voted = option,
            onSubmitEdit: (_) {},
            onCancelEdit: () {},
          ),
          extras: MessageExtras(poll: poll(closed: true)),
        ),
      ),
    );

    await tester.tap(find.text('Vim'));
    expect(voted, isNull);
    expect(find.text('3 votes'), findsOneWidget);
    expect(find.text('CLOSED'), findsOneWidget);
  });
}
