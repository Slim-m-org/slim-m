// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message reached by a jump must show what it carries - its attachments
/// above all - even when the local store already held the row from an earlier
/// session. Those rows were never fetched this session, and attachments live
/// only in memory, so a jump that merely widens the window over them shows a
/// header and a timestamp with nothing underneath.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/message_jump.dart';

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
  testWidgets('a jump into the store shows the attachment on arrival', (
    tester,
  ) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(250, 600),
      seededSeqs: _range(250, 600),
      attachmentSeqs: [250],
    );

    await harness.container
        .read(messageJumpProvider.notifier)
        .jumpTo('c1', 'm250');
    for (var i = 0; i < 5; i++) {
      await flush(tester);
    }

    expect(find.text('message 250'), findsOneWidget);
    expect(find.text(attachmentFilename(250)), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await _unmount(tester);
  });
}
