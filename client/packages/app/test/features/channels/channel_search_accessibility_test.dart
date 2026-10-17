// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Accessibility coverage for real search hits: a result row's accessible
/// name and the live region that announces how many came back, both of
/// which need real messages over a real [ChannelScreen] rather than the
/// bare `ChannelSearchResults` `channel_search_test.dart` already covers.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/channel_search_controller.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_search.dart';

import '../../channel_history_harness.dart';

/// Unmounting deliberately; see `channel_history_test.dart` for why -
/// `ChannelScreen` schedules timers a bare `flush` never drains.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  testWidgets(
    'a search hit is one accessible node naming its author and content',
    (tester) async {
      final harness = await mountChannel(
        tester,
        serverSeqs: const [1],
        seededSeqs: const [1],
        searchHits: [
          {
            'id': 'm50',
            'channel_id': 'c1',
            'author_id': 'alice',
            'author_display_name': 'alice',
            'seq': 50,
            'content': 'a very findable message',
            'created_at': 0,
            'edited_at': null,
          },
        ],
      );

      harness.container.read(channelSearchProvider('c1').notifier).toggle();
      await flush(tester);
      await harness.container
          .read(channelSearchProvider('c1').notifier)
          .run('findable');
      await flush(tester);

      expect(
        find.bySemanticsLabel(
          RegExp('Message from .+: a very findable message'),
        ),
        findsOneWidget,
      );
      await _unmount(tester);
    },
  );

  testWidgets('a search hit announces a result count as a live region', (
    tester,
  ) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: const [1],
      seededSeqs: const [1],
      searchHits: [
        {
          'id': 'm50',
          'channel_id': 'c1',
          'author_id': 'alice',
          'author_display_name': 'alice',
          'seq': 50,
          'content': 'one match',
          'created_at': 0,
          'edited_at': null,
        },
      ],
    );

    harness.container.read(channelSearchProvider('c1').notifier).toggle();
    await flush(tester);
    await harness.container
        .read(channelSearchProvider('c1').notifier)
        .run('match');
    await flush(tester);

    final region = tester.widget<Semantics>(
      find.byKey(ChannelSearchResults.liveRegionKey),
    );
    expect(region.properties.liveRegion, isTrue);
    expect(region.properties.label, '1 result found.');
    await _unmount(tester);
  });
}
