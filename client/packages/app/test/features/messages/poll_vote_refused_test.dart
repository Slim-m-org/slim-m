// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A vote the server refuses comes back off the poll, and the poll says so with
/// a way to send the same ballot again.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_actions.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/features/messages/providers/poll_local_vote.dart';
import 'package:slimm_app/src/features/messages/providers/poll_vote_failure.dart';
import 'package:slimm_app/src/features/composer/widgets/poll_view.dart';
import 'package:slimm_app/src/features/messages/widgets/poll_vote_failure_line.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../channel_history_harness.dart' show channelMessage;
import '../../support/fake_api.dart';
import '../../support/fake_sync.dart';
import 'message_row_harness.dart';

const _tokens = api.TokenPair(
  userId: 'u1',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 9999999999999,
);

api.Poll _poll({
  int? voted,
  List<int>? ranking,
  List<int> votes = const [2, 1],
  bool ranked = false,
}) => api.Poll(
  question: 'Best editor?',
  options: [
    for (var i = 0; i < votes.length; i++)
      api.PollOption(position: i, label: 'option $i', votes: votes[i]),
  ],
  totalVotes: votes.fold(0, (a, b) => a + b),
  votedOption: voted,
  votedRanking: ranking,
  closeAt: null,
  closed: false,
  ranked: ranked,
);

api.Message _withPoll(api.Poll poll) {
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

class _Votes {
  _Votes(this.status);

  int status;
  final List<http.Request> puts = [];

  /// When set, a request waits in [waiting] until the test answers it.
  bool hold = false;
  final List<Completer<void>> waiting = [];

  Future<http.Response> handle(http.Request request) async {
    if (request.method != 'PUT') return http.Response('', 404);
    puts.add(request);
    if (hold) {
      final gate = Completer<void>();
      waiting.add(gate);
      await gate.future;
    }
    if (status == 204) return http.Response('', 204);
    return http.Response(
      jsonEncode({'error': 'poll is closed'}),
      status,
      headers: {'content-type': 'application/json'},
    );
  }
}

/// Mounts a probe so [castVote] and [castRanking] get a real [WidgetRef].
Future<(ProviderContainer, WidgetRef)> _mount(
  WidgetTester tester,
  _Votes votes, {
  required api.Poll poll,
  Widget Function(WidgetRef ref)? child,
}) async {
  late WidgetRef probe;
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
      mockApiOverride(votes.handle),
    ],
  );
  addTearDown(container.dispose);
  container.read(messageExtrasProvider.notifier).applyMessages([
    _withPoll(poll),
  ]);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              probe = ref;
              return child?.call(ref) ?? const SizedBox();
            },
          ),
        ),
      ),
    ),
  );
  return (container, probe);
}

Widget _pollRow(api.Poll poll) => MessageRow(
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
  extras: MessageExtras(poll: poll),
);

void main() {
  testWidgets('a refused vote comes back off the tally and is reported', (
    tester,
  ) async {
    final votes = _Votes(403);
    final (container, ref) = await _mount(tester, votes, poll: _poll());
    final extras = container.read(messageExtrasProvider.notifier);

    await tester.runAsync(() => castVote(ref, 'm1', 1));

    final poll = extras.extrasFor('m1').poll!;
    expect(poll.votedOption, isNull);
    expect(poll.options[1].votes, 1);
    expect(poll.totalVotes, 3);
    final failure = container.read(pollVoteFailureProvider('m1'))!;
    expect(failure.message, startsWith('Could not cast your vote'));
    expect(failure.ballot.option, 1);
  });

  testWidgets('a refused change of vote restores the earlier choice', (
    tester,
  ) async {
    final votes = _Votes(403);
    final (container, ref) = await _mount(
      tester,
      votes,
      poll: _poll(voted: 0, votes: const [3, 1]),
    );
    final extras = container.read(messageExtrasProvider.notifier);

    await tester.runAsync(() => castVote(ref, 'm1', 1));

    final poll = extras.extrasFor('m1').poll!;
    expect(poll.votedOption, 0);
    expect([for (final o in poll.options) o.votes], [3, 1]);
  });

  testWidgets('a refused ranked ballot is taken back and kept for a retry', (
    tester,
  ) async {
    final votes = _Votes(403);
    final (container, ref) = await _mount(
      tester,
      votes,
      poll: _poll(votes: const [0, 0, 0], ranked: true),
    );
    final extras = container.read(messageExtrasProvider.notifier);

    await tester.runAsync(() => castRanking(ref, 'm1', [2, 0]));

    final poll = extras.extrasFor('m1').poll!;
    expect(poll.votedRanking, isNull);
    expect(poll.votedOption, isNull);
    expect(container.read(pollVoteFailureProvider('m1'))!.ballot.ranking, [
      2,
      0,
    ]);
  });

  testWidgets('a vote that lands leaves the tally and no failure', (
    tester,
  ) async {
    final votes = _Votes(204);
    final (container, ref) = await _mount(tester, votes, poll: _poll());

    await tester.runAsync(() => castVote(ref, 'm1', 1));

    final poll = container
        .read(messageExtrasProvider.notifier)
        .extrasFor('m1')
        .poll!;
    expect(poll.votedOption, 1);
    expect(poll.options[1].votes, 2);
    expect(container.read(pollVoteFailureProvider('m1')), isNull);
  });

  testWidgets('the poll shows the refusal and Retry sends the ballot again', (
    tester,
  ) async {
    final votes = _Votes(204);
    final poll = _poll();
    final (container, _) = await _mount(
      tester,
      votes,
      poll: poll,
      child: (ref) => _pollRow(poll),
    );
    container
        .read(pollVoteFailureProvider('m1').notifier)
        .state = const PollVoteFailure(
      'Could not cast your vote: too many requests just now.',
      PollBallot(option: 1),
    );
    await tester.pump();

    expect(find.textContaining('Could not cast your vote'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    expect(votes.puts.single.url.path, '/messages/m1/polls/vote');
    expect(jsonDecode(votes.puts.single.body), {'option': 1});
    expect(container.read(pollVoteFailureProvider('m1')), isNull);
    expect(find.textContaining('Could not cast your vote'), findsNothing);
  });

  testWidgets('a second tap waits for the first vote, so two refusals leave '
      'the poll as it was', (tester) async {
    final votes = _Votes(403)..hold = true;
    final (container, ref) = await _mount(tester, votes, poll: _poll());
    final extras = container.read(messageExtrasProvider.notifier);

    await tester.runAsync(() async {
      final first = castVote(ref, 'm1', 0);
      final second = castVote(ref, 'm1', 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      for (final gate in votes.waiting) {
        gate.complete();
      }
      await Future.wait([first, second]);
    });

    final poll = extras.extrasFor('m1').poll!;
    expect(votes.puts, hasLength(1));
    expect(poll.votedOption, isNull);
    expect([for (final o in poll.options) o.votes], [2, 1]);
    expect(container.read(pollVoteFailureProvider('m1'))!.ballot.option, 0);

    votes.hold = false;
    await tester.runAsync(() => castVote(ref, 'm1', 1));
    expect(votes.puts, hasLength(2));
  });

  testWidgets('the refusal line is no wider than the poll card above it', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1200, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final poll = _poll();
    final (container, _) = await _mount(
      tester,
      _Votes(204),
      poll: poll,
      child: (ref) => _pollRow(poll),
    );
    container
        .read(pollVoteFailureProvider('m1').notifier)
        .state = const PollVoteFailure(
      'Could not cast your vote: too many requests just now.',
      PollBallot(option: 1),
    );
    await tester.pump();

    final card = tester.getSize(find.bySubtype<PollView>());
    final line = tester.getSize(find.bySubtype<PollVoteFailureLine>());
    expect(line.width, card.width);
  });

  test('a broadcast tally that arrived meanwhile is not rolled back', () {
    final before = _poll(votes: const [2, 1]);
    final applied = pollAfterLocalVote(before, 1)!;
    final current = _poll(votes: const [5, 4], voted: 1);

    final reverted = pollAfterRevertedVote(
      before: before,
      applied: applied,
      current: current,
    );

    expect([for (final o in reverted.options) o.votes], [5, 4]);
    expect(reverted.totalVotes, 9);
    expect(reverted.votedOption, isNull);
  });

  test('a later vote is not undone by an earlier one being refused', () {
    final before = _poll(votes: const [2, 1]);
    final applied = pollAfterLocalVote(before, 1)!;
    final later = pollAfterLocalVote(applied, 0)!;

    final reverted = pollAfterRevertedVote(
      before: before,
      applied: applied,
      current: later,
    );

    expect(reverted.votedOption, 0);
    expect(
      [for (final o in reverted.options) o.votes],
      [for (final o in later.options) o.votes],
    );
  });
}
