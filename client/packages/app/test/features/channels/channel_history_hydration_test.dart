// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Attachments, reactions and polls live only in memory, while the local store
/// keeps rows across sessions: so every row a transcript shows has to have
/// been fetched this session, or it is drawn bare. Driven over a real
/// [ChannelScreen] with a store that already holds the rows, as after a
/// restart.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/channel_history.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/features/messages/providers/message_jump.dart';
import 'package:slimm_app/src/features/messages/providers/retention_sweep.dart';

import '../../channel_history_harness.dart';

List<int> _range(int from, int to) => [
  for (var seq = from; seq <= to; seq++) seq,
];

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  testWidgets('opening a channel fetches every page its window shows', (
    tester,
  ) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(1, 300),
      seededSeqs: _range(1, 300),
      attachmentSeqs: [150],
    );

    expect(
      harness.beforeCursors,
      ['251', '201', '151'],
      reason:
          'the window holds the newest 200 rows, 101 to 300; the newest 50 '
          'are one request and these are the pages for the other 150',
    );
    expect(await scrollUntilBuilt(tester, find.text('message 150')), isTrue);
    expect(find.text(attachmentFilename(150)), findsOneWidget);

    await _unmount(tester);
  });

  testWidgets('a second open does not fetch the pages it already holds', (
    tester,
  ) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(1, 300),
      seededSeqs: _range(1, 300),
    );
    final requestsBefore = harness.historyRequests.length;

    await harness.container
        .read(channelHistoryProvider('c1').notifier)
        .hydrate();

    expect(
      harness.historyRequests.length - requestsBefore,
      1,
      reason: 'only the newest page is refetched, to correct what changed',
    );
    await _unmount(tester);
  });

  testWidgets('a sweep that dropped the extras makes the next open refetch', (
    tester,
  ) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(1, 300),
      seededSeqs: _range(1, 300),
      attachmentSeqs: [150],
    );
    final extras = harness.container.read(messageExtrasProvider.notifier);
    expect(extras.extrasFor('m150').attachments, isNotEmpty);

    await runRetentionSweep(harness.store, extras, const {});
    expect(extras.extrasFor('m150').attachments, isEmpty);
    await harness.container
        .read(channelHistoryProvider('c1').notifier)
        .hydrate();

    expect(
      extras.extrasFor('m150').attachments,
      isNotEmpty,
      reason: 'the rows are still in the window; their extras must come back',
    );
    await _unmount(tester);
  });

  testWidgets('a jump leaves the window alone until its pages arrive', (
    tester,
  ) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(250, 600),
      seededSeqs: _range(250, 600),
      attachmentSeqs: [250],
      holdOlderPages: true,
    );
    final jump = harness.container.read(messageJumpProvider.notifier);
    final running = jump.jumpTo('c1', 'm250');
    await flush(tester);

    expect(
      harness.container.read(messageJumpProvider),
      isA<MessageJumpSeeking>(),
    );
    expect(harness.container.read(channelHistoryProvider('c1')).window, 200);

    harness.releaseOlderPages();
    await running;
    for (var i = 0; i < 5; i++) {
      await flush(tester);
    }

    expect(harness.container.read(channelHistoryProvider('c1')).window, 351);
    expect(find.text(attachmentFilename(250)), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('a jump whose pages cannot be fetched fails and widens nothing', (
    tester,
  ) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(250, 600),
      seededSeqs: _range(250, 600),
      olderPagesFail: true,
    );
    final seen = <MessageJumpState>[];
    harness.container.listen(messageJumpProvider, (_, n) => seen.add(n));

    await harness.container
        .read(messageJumpProvider.notifier)
        .jumpTo('c1', 'm250');
    await flush(tester);

    expect(seen.whereType<MessageJumpArrived>(), isEmpty);
    expect(seen.whereType<MessageJumpFailed>(), hasLength(1));
    expect(harness.container.read(channelHistoryProvider('c1')).window, 200);
    expect(
      find.text('Could not load older messages to find it. Try again.'),
      findsOneWidget,
    );
    await _unmount(tester);
  });

  testWidgets(
    'a channel closed while its newest page loads still gets extras',
    (tester) async {
      final gate = Completer<void>();
      final harness = await mountChannel(
        tester,
        serverSeqs: _range(1, 60),
        seededSeqs: _range(1, 60),
        attachmentSeqs: [55],
        answerFirst: (request) async {
          final isRecentPage =
              request.url.path == '/channels/c1/messages' &&
              !request.url.queryParameters.containsKey('before');
          if (isRecentPage) await gate.future;
          return null;
        },
      );
      await _unmount(tester);

      gate.complete();
      await flush(tester);

      final extras = harness.container.read(messageExtrasProvider.notifier);
      expect(extras.extrasFor('m55').attachments, isNotEmpty);
    },
  );

  testWidgets('a page that lands after the session ended is dropped', (
    tester,
  ) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(1, 200),
      seededSeqs: _range(151, 200),
      holdOlderPages: true,
    );
    final running = harness.container
        .read(channelHistoryProvider('c1').notifier)
        .loadOlder();
    await flush(tester);

    // What signing out does to every channel's history.
    harness.container.invalidate(channelHistoryProvider);
    await flush(tester);
    harness.releaseOlderPages();
    await running;
    await flush(tester);

    expect(await harness.store.hasMessage('c1', 'm149'), isFalse);
    expect(
      harness.container.read(messageExtrasProvider).containsKey('m149'),
      isFalse,
    );
    await _unmount(tester);
  });
}
