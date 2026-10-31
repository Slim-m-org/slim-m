// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A 429 on a history page is a moment's wait, not a failure: the pane retries
/// after the time the server names and only shows the persistent error once
/// that budget is spent. Opening a channel also resolves its authors in one
/// request instead of one each.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/rate_limit_retry.dart';

import '../../channel_history_harness.dart';

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

List<int> _range(int from, int to) => [
  for (var seq = from; seq <= to; seq++) seq,
];

void main() {
  testWidgets('a page refused with Retry-After is retried and loads without '
      'the error state', (tester) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(1, 200),
      seededSeqs: _range(151, 200),
      olderPageRateLimits: 2,
      rateLimitRetryAfter: 3,
    );
    final before = transcriptItemCount(tester);

    await scrollToOldest(tester);

    expect(find.text('Could not load earlier messages.'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(harness.rateLimitWaits, [
      const Duration(seconds: 3),
      const Duration(seconds: 3),
    ]);
    expect(
      harness.beforeCursors.take(3).toSet(),
      hasLength(1),
      reason: 'two refusals and then the same page answered, same cursor',
    );
    expect(harness.beforeCursors.length, greaterThanOrEqualTo(3));
    expect(
      transcriptItemCount(tester),
      greaterThan(before),
      reason: 'the retried page landed in the transcript',
    );

    await _unmount(tester);
  });

  testWidgets('with no hint from the server the wait backs off', (
    tester,
  ) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(1, 200),
      seededSeqs: _range(151, 200),
      olderPageRateLimits: 3,
    );

    await scrollToOldest(tester);

    expect(find.text('Could not load earlier messages.'), findsNothing);
    expect(harness.rateLimitWaits, [
      rateLimitFallbackWait,
      rateLimitFallbackWait * 2,
      rateLimitFallbackWait * 4,
    ]);

    await _unmount(tester);
  });

  testWidgets('a refusal that outlasts the retry budget shows the persistent '
      'error, never a snackbar', (tester) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(1, 200),
      seededSeqs: _range(151, 200),
      olderPageRateLimits: 99,
      rateLimitRetryAfter: 1,
    );

    await scrollToOldest(tester);

    expect(find.text('Could not load earlier messages.'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(harness.rateLimitWaits, hasLength(rateLimitRetries));
    expect(harness.beforeCursors, hasLength(rateLimitRetries + 1));

    await _unmount(tester);
  });

  testWidgets('a wait longer than a background read should sit through is '
      'reported at once', (tester) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(1, 200),
      seededSeqs: _range(151, 200),
      olderPageRateLimits: 99,
      rateLimitRetryAfter: 120,
    );

    await scrollToOldest(tester);

    expect(find.text('Could not load earlier messages.'), findsOneWidget);
    expect(harness.rateLimitWaits, isEmpty);
    expect(harness.beforeCursors, hasLength(1));

    await _unmount(tester);
  });

  testWidgets('opening a channel with forty unseen authors asks for them in '
      'one request', (tester) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(161, 200),
      seededSeqs: _range(161, 200),
      authorFor: (seq) => 'author-$seq',
    );

    final batches = harness.userRequests.where((u) => u.path == '/users');
    final singles = harness.userRequests.where(
      (u) => u.path.startsWith('/users/'),
    );
    expect(singles, isEmpty, reason: 'no GET /users/{id} per author');
    expect(batches, hasLength(1), reason: 'one batch for the whole page');
    expect(
      batches.single.queryParameters['ids']!.split(',').toSet().length,
      greaterThan(5),
      reason: 'the lazy list built a real share of the forty rows',
    );

    await _unmount(tester);
  });
}
