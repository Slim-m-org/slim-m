// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A jump cancelled by a channel switch must stop paging, and its page bound
/// counts messages, not pages, so the page-size setting does not move it.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/message_jump.dart';
import 'package:slimm_app/src/providers/message_page_size.dart';

import 'channel_history_harness.dart';

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
  testWidgets('cancelFor stops a seek that is still paging', (tester) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(1, 200),
      seededSeqs: _range(151, 200),
      holdOlderPages: true,
    );
    final seen = <MessageJumpState>[];
    harness.container.listen(messageJumpProvider, (_, n) => seen.add(n));
    final jump = harness.container.read(messageJumpProvider.notifier);
    final running = jump.jumpTo('c1', 'm100');
    await flush(tester);
    expect(
      harness.container.read(messageJumpProvider),
      isA<MessageJumpSeeking>(),
    );

    jump.cancelFor('c1');
    expect(harness.container.read(messageJumpProvider), isA<MessageJumpIdle>());

    harness.releaseOlderPages();
    await tester.runAsync(() => running);
    for (var i = 0; i < 5; i++) {
      await flush(tester);
    }

    expect(
      seen.whereType<MessageJumpArrived>(),
      isEmpty,
      reason:
          'the jump was cancelled; it must never write Arrived afterwards '
          '(states seen: ${seen.map((e) => e.runtimeType).toList()})',
    );
    await _unmount(tester);
  });

  testWidgets(
    'a target 300 messages back is found with the smaller page size',
    (tester) async {
      final harness = await mountChannel(
        tester,
        serverSeqs: _range(1, 400),
        seededSeqs: _range(351, 400),
        messagePageSize: MessagePageSize.small,
      );
      final seen = <MessageJumpState>[];
      harness.container.listen(messageJumpProvider, (_, n) => seen.add(n));
      await harness.container
          .read(messageJumpProvider.notifier)
          .jumpTo('c1', 'm100');
      expect(
        seen.whereType<MessageJumpArrived>(),
        isNotEmpty,
        reason:
            'states seen: ${seen.map((e) => e.runtimeType).toList()}; '
            'm100 is 300 messages back, inside the documented 500 bound',
      );
      await _unmount(tester);
    },
  );

  testWidgets('a target past 500 messages is unreachable with the larger page '
      'size too', (tester) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(1, 900),
      seededSeqs: _range(851, 900),
      messagePageSize: MessagePageSize.large,
    );
    final seen = <MessageJumpState>[];
    harness.container.listen(messageJumpProvider, (_, n) => seen.add(n));
    await harness.container
        .read(messageJumpProvider.notifier)
        .jumpTo('c1', 'm150');
    expect(seen.whereType<MessageJumpUnreachable>(), isNotEmpty);
    expect(seen.whereType<MessageJumpArrived>(), isEmpty);
    await _unmount(tester);
  });
}
