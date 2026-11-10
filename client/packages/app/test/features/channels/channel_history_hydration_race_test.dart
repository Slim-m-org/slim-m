// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The races around fetching what a window shows: a jump whose target moves
/// while its pages load, a jump or a channel that goes away mid-walk, the
/// queue that keeps two walks from fetching one page twice, and a sign-out
/// during a fetch. Over a real [ChannelScreen] with a store that already
/// holds the rows, as after a restart.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_history.dart';
import 'package:slimm_app/src/features/messages/providers/hydrated_ranges.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/features/messages/providers/message_jump.dart';
import 'package:slimm_app/src/features/messages/providers/retention_sweep.dart';
import 'package:slimm_data/data.dart';

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

/// Lets the arrival's flash finish, so no timer is left pending at unmount.
Future<void> _settle(WidgetTester tester) async {
  await flush(tester);
  await tester.pump(const Duration(seconds: 3));
}

/// A store whose page writes wait on [hold] once a test sets it.
class _GatedStore extends MessageStore {
  _GatedStore(super.db);

  Future<void>? hold;

  @override
  Future<void> applyMessages(
    Iterable<api.Message> messages, {
    CursorAdvance advance = CursorAdvance.whenContiguous,
  }) async {
    await hold;
    await super.applyMessages(messages, advance: advance);
  }
}

void main() {
  testWidgets('a target that moves deeper while its pages load is still shown', (
    tester,
  ) async {
    // The store has a hole between the two runs, which the open-time fetch fills while the jump waits.
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(50, 600),
      seededSeqs: [..._range(50, 100), ..._range(550, 600)],
      holdOlderPages: true,
    );
    final windowsAtArrival = <int>[];
    harness.container.listen(messageJumpProvider, (_, next) {
      if (next is! MessageJumpArrived) return;
      windowsAtArrival.add(
        harness.container.read(channelHistoryProvider('c1')).window,
      );
    });
    final running = harness.container
        .read(messageJumpProvider.notifier)
        .jumpTo('c1', 'm50');
    await flush(tester);

    harness.releaseOlderPages();
    await running;
    await _settle(tester);

    expect(
      windowsAtArrival,
      hasLength(1),
      reason: 'arrives once, with m50 551 rows down, never earlier',
    );
    expect(windowsAtArrival.single, greaterThanOrEqualTo(551));
    expect(find.text('message 50'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('a jump that was superseded stops walking pages', (tester) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(250, 600),
      seededSeqs: _range(250, 600),
      holdOlderPages: true,
    );
    final jump = harness.container.read(messageJumpProvider.notifier);
    final running = jump.jumpTo('c1', 'm250');
    await flush(tester);

    jump.cancelFor('c1');
    harness.releaseOlderPages();
    await running;
    await flush(tester);

    expect(harness.beforeCursors, [
      '551',
      '501',
      '451',
    ], reason: 'only the open-time walk over the 200-row window may fetch');
    await _unmount(tester);
  });

  testWidgets('a channel closed mid-walk fetches no further pages', (
    tester,
  ) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(250, 600),
      seededSeqs: _range(250, 600),
      holdOlderPages: true,
    );
    await _unmount(tester);

    harness.releaseOlderPages();
    await flush(tester);

    expect(harness.beforeCursors, [
      '551',
    ], reason: 'the page already in flight lands; the walk then stops');
  });

  testWidgets(
    'a jump to rows already fetched does not wait on a running walk',
    (tester) async {
      final harness = await mountChannel(
        tester,
        serverSeqs: _range(250, 600),
        seededSeqs: _range(250, 600),
        holdOlderPages: true,
      );
      final seen = <MessageJumpState>[];
      harness.container.listen(
        messageJumpProvider,
        (_, next) => seen.add(next),
      );

      unawaited(
        harness.container
            .read(messageJumpProvider.notifier)
            .jumpTo('c1', 'm580'),
      );
      await flush(tester);

      expect(
        seen.whereType<MessageJumpArrived>(),
        hasLength(1),
        reason: 'm580 is in the newest page, which is already fetched',
      );
      harness.releaseOlderPages();
      await _settle(tester);
      await _unmount(tester);
    },
  );

  testWidgets('a swept channel reopens at its initial window', (tester) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(1, 600),
      seededSeqs: _range(1, 600),
    );
    final history = harness.container.read(
      channelHistoryProvider('c1').notifier,
    )..widenWindowTo(500);
    final extras = harness.container.read(messageExtrasProvider.notifier);
    await runRetentionSweep(harness.store, extras, const {});
    final opened = harness.beforeCursors.length;

    await history.hydrate();

    expect(harness.container.read(channelHistoryProvider('c1')).window, 200);
    expect(harness.beforeCursors.sublist(opened), [
      '551',
      '501',
      '451',
    ], reason: 'the pages for 200 rows, not for the 500 it had grown to');
    await _unmount(tester);
  });

  testWidgets('hydrate and a jump fetch the pages they share once', (
    tester,
  ) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(250, 600),
      seededSeqs: _range(250, 600),
      holdOlderPages: true,
    );
    final running = harness.container
        .read(messageJumpProvider.notifier)
        .jumpTo('c1', 'm250');
    await flush(tester);

    harness.releaseOlderPages();
    await running;

    final cursors = harness.beforeCursors;
    expect(cursors.toSet(), hasLength(cursors.length), reason: '$cursors');
    expect(cursors, ['551', '501', '451', '401', '351', '301', '251']);
    await _settle(tester);
    await _unmount(tester);
  });

  testWidgets('pages loaded by scrolling back are not fetched again', (
    tester,
  ) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(1, 200),
      seededSeqs: _range(151, 200),
    );
    final history = harness.container.read(
      channelHistoryProvider('c1').notifier,
    );
    await history.loadOlder();
    await flush(tester);
    final loaded = harness.historyRequests.length;

    await harness.container
        .read(messageJumpProvider.notifier)
        .jumpTo('c1', 'm120');
    expect(harness.historyRequests.length, loaded, reason: 'a jump needs none');

    await history.hydrate();
    expect(harness.historyRequests.length, loaded + 1);
    expect(
      harness.historyRequests.last.queryParameters.containsKey('before'),
      isFalse,
      reason: 'only the newest page is refetched',
    );
    await _settle(tester);
    await _unmount(tester);
  });

  testWidgets('a sign-out during a fetch leaves no extras or ranges behind', (
    tester,
  ) async {
    late _GatedStore store;
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(1, 60),
      seededSeqs: _range(1, 60),
      attachmentSeqs: [55],
      storeFactory: (db) => store = _GatedStore(db),
    );
    final extras = harness.container.read(messageExtrasProvider.notifier);
    extras.clear();
    final gate = Completer<void>();
    store.hold = gate.future;
    final running = harness.container
        .read(channelHistoryProvider('c1').notifier)
        .hydrate();
    await flush(tester);

    // What the end of a session does.
    harness.container.invalidate(channelHistoryProvider);
    extras.clear();
    await flush(tester);
    gate.complete();
    await running;
    await flush(tester);

    expect(extras.extrasFor('m55').attachments, isEmpty);
    expect(extras.highestUnhydrated('c1', 1), HydratedRanges.newest);
    await _unmount(tester);
  });
}
