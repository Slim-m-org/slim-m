// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message this build cannot parse is missing from a page, which must not
/// make a full page look short and so look like the start of the channel.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/message_page_size.dart';

import '../../channel_history_harness.dart';

List<int> _range(int from, int to) => [
  for (var seq = from; seq <= to; seq++) seq,
];

void main() {
  testWidgets('a full page with an unreadable oldest item still pages on from '
      'the raw cursor', (tester) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(1, 200),
      seededSeqs: _range(151, 200),
      messagePageSize: MessagePageSize.small,
      unreadableSeqs: {126},
    );

    await scrollToOldest(tester);

    expect(harness.beforeCursors.take(2).toList(), [
      '151',
      '126',
    ], reason: '25 items came back, one unreadable: the page was still full');

    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
  });
}
