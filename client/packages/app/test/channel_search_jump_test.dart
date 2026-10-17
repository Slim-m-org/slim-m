// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tapping an in-channel search result over a real [ChannelScreen]: it has
/// to close the search panel, scroll to the message, and flash it - the
/// third render site for a message hit, alongside the pins sheet and the
/// command palette.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/channel_search_controller.dart';
import 'package:slimm_app/src/features/messages/widgets/message_jump.dart';

import 'channel_history_harness.dart';

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
    'tapping a search result closes the panel, scrolls to it and flashes it',
    (tester) async {
      final harness = await mountChannel(
        tester,
        serverSeqs: _range(41, 80),
        seededSeqs: _range(41, 80),
        searchHits: [
          {
            'id': 'm50',
            'channel_id': 'c1',
            'author_id': 'alice',
            'author_display_name': 'alice',
            'seq': 50,
            'content': 'message 50',
            'created_at': 50 * 60000,
            'edited_at': null,
          },
        ],
      );

      harness.container.read(channelSearchProvider('c1').notifier).toggle();
      await flush(tester);
      await harness.container
          .read(channelSearchProvider('c1').notifier)
          .run('message 50');
      await flush(tester);

      expect(find.text('message 50'), findsOneWidget);
      await tester.tap(find.text('message 50'));
      await flush(tester);

      expect(
        harness.container.read(channelSearchProvider('c1')).open,
        isFalse,
        reason: 'the search panel must close on the way to the message',
      );
      expect(
        find.text('message 50'),
        findsOneWidget,
        reason: 'the target has to be visible in the real transcript now',
      );
      expect(find.byType(MessageJumpHighlight), findsOneWidget);

      // Past the flash's hold and fade, so no timer is left pending at unmount.
      await tester.pump(const Duration(seconds: 3));
      await _unmount(tester);
    },
  );
}
