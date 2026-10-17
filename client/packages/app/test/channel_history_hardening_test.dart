// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Four findings from an adversarial review of `channel_history.dart`, split
/// out of `channel_history_test.dart` to keep both files under the line
/// budget: a page filtered entirely from view walking the whole channel over
/// the network, `atStart` outliving a sign-out, a rebuild racing a page's own
/// state write into repeating it, and a store write failure escaping the
/// catch clause meant to recover from a refused one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_history.dart';
import 'package:slimm_app/src/providers/message_extras.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/widgets/message_transcript_widgets.dart';
import 'package:slimm_data/data.dart';

import 'channel_history_harness.dart';

/// A [MessageStore] whose write can be made to fail exactly once, for the
/// case a network response is fine but the local write is not: a full disk,
/// say.
class _FailingApplyStore extends MessageStore {
  _FailingApplyStore(super.db);

  bool failNext = false;

  @override
  Future<void> applyMessages(Iterable<api.Message> messages) async {
    if (failNext) {
      failNext = false;
      throw StateError('disk full');
    }
    await super.applyMessages(messages);
  }
}

/// Unmounting deliberately, with a few more pumps, rather than leaving it to
/// flutter_test's teardown; see `channel_screen_test.dart` for why drift's
/// deferred stream cleanup needs this.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

Future<Set<String>> _storedIds(SlimmDatabase db) async =>
    (await db.select(db.messages).get()).map((m) => m.id).toSet();

List<int> _range(int from, int to) => [
  for (var seq = from; seq <= to; seq++) seq,
];

void main() {
  testWidgets(
    'a page that adds no visible rows cannot drive another one on its own',
    (tester) async {
      final harness = await mountChannel(
        tester,
        serverSeqs: _range(1, 400),
        seededSeqs: _range(351, 400),
        messageAuthorId: 'evil',
        blockedUserIds: const ['evil'],
        syncStatus: SyncStatus.live,
      );

      // Enough frames for the pre-fix code to have walked deep into the channel.
      for (var i = 0; i < 5; i++) {
        await flush(tester);
      }

      expect(
        harness.beforeCursors,
        isEmpty,
        reason:
            'every loaded row is from a blocked author, so the transcript '
            'never has anything visible to have scrolled away from - the '
            'old code read that as a scroll to the very bottom and walked '
            'the whole channel chasing content it was always going to '
            'filter back out',
      );
      expect(find.byType(ChannelStartHeader), findsNothing);

      await _unmount(tester);
    },
  );

  testWidgets(
    'signing out resets a channel\'s paged history for whoever signs in '
    'next on the device',
    (tester) async {
      final harness = await mountChannel(
        tester,
        serverSeqs: _range(1, 80),
        seededSeqs: _range(41, 80),
      );

      await scrollToOldest(tester);
      await scrollToOldest(tester);
      expect(find.byType(ChannelStartHeader), findsOneWidget);
      expect(
        harness.container.read(channelHistoryProvider('c1')).atStart,
        isTrue,
      );

      harness.container
          .read(messageExtrasProvider.notifier)
          .applyMessage(channelMessage(41));
      expect(harness.container.read(messageExtrasProvider), isNotEmpty);

      // What SyncController._endSession does on sign-out.
      harness.container.read(sessionProvider).clear();
      await flush(tester);

      expect(
        harness.container.read(channelHistoryProvider('c1')).atStart,
        isFalse,
        reason:
            'a fresh account must not inherit a stranger\'s paging state on '
            'the same device',
      );
      expect(
        harness.container.read(messageExtrasProvider),
        isEmpty,
        reason:
            'reactions, attachments and polls are keyed by message id, so a '
            'stale entry would answer just as readily for the next account',
      );

      // The next account signs in on the same device.
      harness.container
          .read(sessionProvider)
          .set(
            const api.TokenPair(
              userId: 'carol',
              accessToken: 'access2',
              refreshToken: 'refresh2',
              accessExpiresAt: 0,
            ),
          );
      await flush(tester);

      // And its own sync delivers only its own recent window.
      final beforeReseed = harness.beforeCursors.length;
      await harness.store.upsertChannels([
        const api.Channel(
          id: 'c1',
          name: 'general',
          kind: 'text',
          createdAt: 0,
        ),
      ]);
      await harness.store.applyMessages(_range(41, 80).map(channelMessage));
      await flush(tester);

      expect(
        find.byType(ChannelStartHeader),
        findsNothing,
        reason: 'the new account has not proven where this channel starts',
      );

      await scrollToOldest(tester);
      expect(
        harness.beforeCursors.length,
        greaterThan(beforeReseed),
        reason:
            'a leftover atStart would have left this at zero forever, the '
            'same channel unable to page again for anyone',
      );

      await _unmount(tester);
    },
  );

  testWidgets(
    'a build reporting a stale oldest cannot make the next page repeat the '
    'one that just landed',
    (tester) async {
      final harness = await mountChannel(
        tester,
        serverSeqs: _range(1, 200),
        seededSeqs: _range(151, 200),
      );
      final notifier = harness.container.read(
        channelHistoryProvider('c1').notifier,
      );

      notifier.syncOldest(151);
      await notifier.loadOlder();
      await flush(tester);

      expect(harness.beforeCursors, ['151']);

      // A build still running on the snapshot from before that page landed.
      notifier.syncOldest(151);
      await notifier.loadOlder();
      await flush(tester);

      expect(
        harness.beforeCursors,
        ['151', '101'],
        reason:
            'the stale report must not undo what the first page already '
            'proved, or the second page repeats the first rather than '
            'advancing past it, double-counting the window in the process',
      );

      await _unmount(tester);
    },
  );

  testWidgets('a store write failing while a page lands still recovers to a '
      'retryable state rather than a spinner stuck forever', (tester) async {
    late _FailingApplyStore failing;
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(1, 200),
      seededSeqs: _range(151, 200),
      storeFactory: (db) => failing = _FailingApplyStore(db),
    );

    failing.failNext = true;
    await scrollToOldest(tester);

    final history = harness.container.read(channelHistoryProvider('c1'));
    expect(
      history.loading,
      isFalse,
      reason:
          'a non-ApiException must clear loading too, or every later page '
          'is wedged behind a spinner with no way back',
    );
    expect(history.failed, isTrue);
    expect(find.text('Could not load earlier messages.'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await flush(tester);

    expect(
      harness.container.read(channelHistoryProvider('c1')).failed,
      isFalse,
    );
    expect(
      await _storedIds(harness.db),
      contains('m150'),
      reason:
          'the retried page must actually land once the store stops '
          'refusing it',
    );

    await _unmount(tester);
  });
}
