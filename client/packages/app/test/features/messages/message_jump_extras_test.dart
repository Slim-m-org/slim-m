// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message reached by a jump must show what it carries - its attachments
/// above all - even when the local store already held the row from an earlier
/// session. Those rows were never fetched this session, and attachments live
/// only in memory, so a jump that merely widens the window over them shows a
/// header and a timestamp with nothing underneath.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/channel_search_controller.dart';
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

Map<String, dynamic> _searchHit(int seq) => {
  'id': 'm$seq',
  'channel_id': 'c1',
  'author_id': 'alice',
  'author_display_name': 'alice',
  'seq': seq,
  'content': 'message $seq',
  'created_at': seq * 60000,
  'edited_at': null,
};

void main() {
  testWidgets('a search result already in the store shows its attachment', (
    tester,
  ) async {
    // The store holds all 351 rows from an earlier session; this session has fetched only the newest 50.
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(250, 600),
      seededSeqs: _range(250, 600),
      attachmentSeqs: [250],
      searchHits: [_searchHit(250)],
    );

    harness.container.read(channelSearchProvider('c1').notifier).toggle();
    await flush(tester);
    await harness.container
        .read(channelSearchProvider('c1').notifier)
        .run('message 250');
    await flush(tester);
    await tester.tap(find.text('message 250'));
    for (var i = 0; i < 5; i++) {
      await flush(tester);
    }

    expect(find.text('message 250'), findsOneWidget);
    expect(
      find.text(attachmentFilename(250)),
      findsOneWidget,
      reason: 'the jumped-to row must carry its attachment chip',
    );

    await tester.pump(const Duration(seconds: 3));
    await _unmount(tester);
  });

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
