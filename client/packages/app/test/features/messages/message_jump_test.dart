// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Jumping to a message end to end, over a real [ChannelScreen]: a message
/// already loaded is scrolled to and flashed; one that needs older history
/// paged in gets there the same way once paging catches up; and one that can
/// never be found says so rather than leaving the reader scrolled nowhere.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/message_jump.dart';
import 'package:slimm_app/src/features/messages/widgets/message_jump.dart';

import '../../channel_history_harness.dart';

List<int> _range(int from, int to) => [
  for (var seq = from; seq <= to; seq++) seq,
];

/// Unmounting deliberately; see `channel_history_test.dart` for why.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  testWidgets(
    'a jump to a message already loaded scrolls to it and flashes it',
    (tester) async {
      final harness = await mountChannel(
        tester,
        serverSeqs: _range(41, 80),
        seededSeqs: _range(41, 80),
      );

      expect(find.text('message 50'), findsNothing);

      await harness.container
          .read(messageJumpProvider.notifier)
          .jumpTo('c1', 'm50');
      await flush(tester);

      expect(
        find.text('message 50'),
        findsOneWidget,
        reason: 'the target has to actually be scrolled to, not merely found',
      );
      expect(
        find.byType(MessageJumpHighlight),
        findsOneWidget,
        reason: 'the arrival is marked while the flash is still playing',
      );

      // Past the flash's hold and fade, the arrival is told back as handled.
      await tester.pump(const Duration(seconds: 3));

      expect(
        harness.container.read(messageJumpProvider),
        isA<MessageJumpIdle>(),
        reason: 'a handled arrival must not keep re-triggering on rebuilds',
      );

      await _unmount(tester);
    },
  );

  testWidgets('a jump pages history backwards until the target is loaded', (
    tester,
  ) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(1, 200),
      seededSeqs: _range(151, 200),
    );

    // m100 is older than anything seeded locally: reaching it needs paging.
    await harness.container
        .read(messageJumpProvider.notifier)
        .jumpTo('c1', 'm100');
    for (var i = 0; i < 5; i++) {
      await flush(tester);
    }

    expect(
      harness.beforeCursors,
      isNotEmpty,
      reason: 'the jump has to have paged backwards to reach it at all',
    );
    expect(find.text('message 100'), findsOneWidget);

    await _unmount(tester);
  });

  testWidgets(
    'a jump that can never find its target says so rather than a silent '
    'no-op',
    (tester) async {
      final harness = await mountChannel(
        tester,
        serverSeqs: _range(1, 80),
        seededSeqs: _range(41, 80),
      );

      await harness.container
          .read(messageJumpProvider.notifier)
          .jumpTo('c1', 'does-not-exist');
      // Short of the SnackBar's own default auto-dismiss so it is still up.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.text('Could not find that message.'),
        findsOneWidget,
        reason:
            'a message that cannot be reached must say so plainly, never '
            'scroll to nothing and stay silent about it',
      );
      expect(
        harness.container.read(messageJumpProvider),
        isA<MessageJumpIdle>(),
        reason: 'the notice, once shown, is not repeated on a later rebuild',
      );

      await _unmount(tester);
    },
  );
}
