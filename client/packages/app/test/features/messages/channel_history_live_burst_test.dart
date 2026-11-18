// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A live burst slides the transcript's newest-N window up past rows it had
/// already paged, so the next page must widen the window down to what it
/// fetched, or the start of the channel is announced above a later message.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_transcript_widgets.dart';

import '../../channel_history_harness.dart';

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  testWidgets('the start is announced above the first message after a live '
      'burst, not above where the window slid to', (tester) async {
    final serverSeqs = [for (var s = 1; s <= 80; s++) s];
    final harness = await mountChannel(
      tester,
      serverSeqs: serverSeqs,
      seededSeqs: [for (var s = 31; s <= 80; s++) s],
    );

    final burst = [for (var s = 81; s <= 280; s++) s];
    serverSeqs.addAll(burst);
    await harness.store.applyMessages(burst.map(channelMessage));
    await flush(tester);

    await scrollToOldest(tester);
    await scrollToOldest(tester);

    expect(
      find.byWidgetPredicate((w) => w is ChannelStartHeader),
      findsOneWidget,
    );
    expect(
      find.text('message 1'),
      findsOneWidget,
      reason:
          'the header claims nothing is older than the row under it, so that '
          'row has to be the channel first message',
    );

    await _unmount(tester);
  });
}
