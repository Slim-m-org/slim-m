// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A jump whose history page cannot be fetched says so, instead of claiming
/// the message does not exist.
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
  testWidgets('a failed history page is a failure, not a missing message', (
    tester,
  ) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(1, 200),
      seededSeqs: _range(151, 200),
      olderPagesFail: true,
    );
    final seen = <MessageJumpState>[];
    harness.container.listen(messageJumpProvider, (_, n) => seen.add(n));

    await harness.container
        .read(messageJumpProvider.notifier)
        .jumpTo('c1', 'm100');

    expect(seen.whereType<MessageJumpUnreachable>(), isEmpty);
    expect(seen.last, isA<MessageJumpFailed>());
    await _unmount(tester);
  });

  testWidgets(
    'the notice says the fetch failed, not that the message is missing',
    (tester) async {
      final harness = await mountChannel(
        tester,
        serverSeqs: _range(1, 200),
        seededSeqs: _range(151, 200),
        olderPagesFail: true,
      );

      await harness.container
          .read(messageJumpProvider.notifier)
          .jumpTo('c1', 'm100');
      await flush(tester);

      expect(
        find.text('Could not load older messages to find it. Try again.'),
        findsOneWidget,
      );
      expect(find.text('Could not find that message.'), findsNothing);
      expect(
        harness.container.read(messageJumpProvider),
        isA<MessageJumpIdle>(),
      );
      await _unmount(tester);
    },
  );
}
