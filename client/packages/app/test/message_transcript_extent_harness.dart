// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Fixtures for `message_transcript_extent_test.dart`: a transcript long and
/// unevenly built enough for the scrollbar bug to be visible in it, and the
/// scroll-and-sample loop that measures what the scrollbar reads.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it. It
/// exists because the transcript takes twenty-odd required callbacks and the
/// measurements below are long enough to have pushed that suite past the
/// 500-line ceiling on their own.
///
/// The fixture is built to make the old and new answers genuinely disagree,
/// which for this bug means two things a smaller one would quietly fail to
/// exercise. Rows must vary sharply in height, since a list of uniform rows
/// has a stable average and so no jitter to find - the suite asserts that of
/// [messages] rather than trusting it. And there must be far more rows than
/// fit the laid-out window, since the extent is only ever estimated at all
/// while rows remain unbuilt.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' hide Message;
import 'package:slimm_app/src/providers/channel_history.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/widgets/message_transcript.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'message_row_harness.dart';
import 'support/fake_sync.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// Every fourth message wraps to many lines and the author changes every third,
/// so the list carries both of the height differences a real transcript has: a
/// long message against a short one, and a headed row against a grouped
/// continuation that drops its avatar and header.
List<Message> messages(int count) => [
  for (var i = 0; i < count; i++)
    Message(
      id: 'm$i',
      channelId: 'c1',
      authorId: 'author-${(i ~/ 3) % 2}',
      authorDisplayName: 'Author ${(i ~/ 3) % 2}',
      seq: i + 1,
      content: i % 4 == 0
          ? List.filled(12, 'a long wrapping line of message content').join(' ')
          : 'short',
      createdAt: 1700000000000 + i * 60000,
      pending: false,
      failed: false,
    ),
];

/// The same count of rows with none of the tall ones, so a channel built from
/// these is genuinely shorter than one built from [messages].
List<Message> shortMessages(int count) => [
  for (var i = 0; i < count; i++)
    Message(
      id: 's$i',
      channelId: 'c2',
      authorId: 'author-${(i ~/ 3) % 2}',
      authorDisplayName: 'Author ${(i ~/ 3) % 2}',
      seq: i + 1,
      content: 'short',
      createdAt: 1700000000000 + i * 60000,
      pending: false,
      failed: false,
    ),
];

Widget app(Widget transcript) => ProviderScope(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
    syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(body: transcript),
  ),
);

MessageTranscript transcript({
  required ScrollController controller,
  required int count,
  String channelId = 'c1',
  bool short = false,
  Key? key,
}) => MessageTranscript(
  key: key,
  channelId: channelId,
  messages: short ? shortMessages(count) : messages(count),
  syncStatus: SyncStatus.live,
  historyKnown: true,
  channelName: 'general',
  scrollController: controller,
  lastReadSeq: 999999,
  selfId: 'self',
  knownUsernames: const {},
  customEmoji: const {},
  history: const ChannelHistory(atStart: true),
  onLoadOlder: () {},
  onRetryOlder: () {},
  actionsFor: (_, _) => noActions,
  onRetry: (_) {},
  onDiscard: (_) {},
  onPickReaction: (_, _) {},
  onReactionTap: (_, _) {},
  onVote: (_, _) {},
  onSubmitEdit: (_, _) {},
  onCancelEdit: () {},
  onJumpToReply: (_) {},
);

/// A desktop-sized viewport, where a scrollbar is drawn automatically and so
/// where this bug is seen.
void sizeViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// What the scrollbar actually reads, sampled while scrolling steadily toward
/// older history one wheel-sized step at a time.
class Travel {
  Travel({
    required this.steps,
    required this.backwardsSteps,
    required this.worstBackwards,
    required this.minExtent,
    required this.maxExtent,
  });

  final int steps;

  /// Frames on which the thumb moved *against* the direction of scrolling.
  final int backwardsSteps;

  /// The largest single backwards move, as a fraction of the whole track.
  final double worstBackwards;

  final double minExtent;
  final double maxExtent;

  double get swing => (maxExtent - minExtent) / maxExtent;
}

/// A single step small enough to be a realistic wheel tick: the jitter is a
/// per-frame effect, so sampling it in large jumps would stride over most of it.
const double step = 60;

/// A short read into history: enough real layouts for the estimator to have
/// settled, and far short of the end of any fixture here.
///
/// Ten rather than a bare pump or two because only a real layout takes a fresh
/// reading - pumping an idle tree measures nothing - and ten is about a sixth
/// of a second of scrolling.
Future<void> readAWhile(
  WidgetTester tester,
  ScrollController controller,
) async {
  for (var i = 0; i < 10; i++) {
    controller.jumpTo(controller.position.pixels + step);
    await tester.pump();
  }
}

Future<Travel> scrollThrough(
  WidgetTester tester,
  ScrollController controller,
) async {
  var backwardsSteps = 0;
  var worstBackwards = 0.0;
  var previousFraction = 0.0;
  var minExtent = double.infinity;
  var maxExtent = 0.0;
  var steps = 0;
  while (steps <= 400) {
    final position = controller.position;
    minExtent = minExtent < position.maxScrollExtent
        ? minExtent
        : position.maxScrollExtent;
    maxExtent = maxExtent > position.maxScrollExtent
        ? maxExtent
        : position.maxScrollExtent;
    final fraction = position.pixels / position.maxScrollExtent;
    final backwards = previousFraction - fraction;
    if (backwards > worstBackwards) worstBackwards = backwards;
    // A hair of slack, so float noise is not counted as a visible move.
    if (backwards > 0.0005) backwardsSteps++;
    previousFraction = fraction;
    final next = position.pixels + step;
    if (next > position.maxScrollExtent) break;
    controller.jumpTo(next);
    await tester.pump();
    steps++;
  }
  return Travel(
    steps: steps,
    backwardsSteps: backwardsSteps,
    worstBackwards: worstBackwards,
    minExtent: minExtent,
    maxExtent: maxExtent,
  );
}
