// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The read-only window a search hit too old to page to opens around itself:
/// the bar over it must never hide a row, and a send from it must land in the
/// live channel where the sent message can be seen.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/messages/providers/message_context_window.dart';
import 'package:slimm_app/src/features/messages/widgets/context_window_bar.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';

import '../../channel_history_harness.dart';

List<int> _range(int from, int to) => [
  for (var seq = from; seq <= to; seq++) seq,
];

final _bar = find.byWidgetPredicate((w) => w is ContextWindowBar);
final _composerField = find.byWidgetPredicate((w) => w is TextField).last;

/// The transcript's own list, whose rect is what "on screen" means here.
final _transcript = find.byWidgetPredicate((w) => w is Scrollable).first;

/// Echoes a send back as the server's copy, one past the newest seq.
Future<http.Response?> _answerSend(http.Request request) async {
  if (request.method != 'POST' || request.url.path != '/channels/c1/messages') {
    return null;
  }
  final body = jsonDecode(request.body) as Map<String, dynamic>;
  return http.Response(
    jsonEncode({
      'id': body['id'],
      'channel_id': 'c1',
      'author_id': 'bob',
      'author_display_name': 'bob',
      'seq': 1601,
      'content': body['content'],
      'created_at': 1601 * 60000,
    }),
    201,
    headers: {'content-type': 'application/json'},
  );
}

Future<HistoryHarness> _mountInContext(
  WidgetTester tester, {
  List<String>? reads,
}) async {
  final harness = await mountChannel(
    tester,
    serverSeqs: _range(1, 1600),
    seededSeqs: _range(1551, 1600),
    syncStatus: SyncStatus.live,
    overrides: [
      myChannelPermissionsProvider.overrideWith((ref, _) => Perm.sendMessages),
    ],
    answerFirst: (request) async {
      if (request.method == 'PUT' && request.url.path == '/channels/c1/read') {
        reads?.add(request.body);
      }
      return _answerSend(request);
    },
  );
  await harness.container
      .read(messageContextWindowProvider('c1').notifier)
      .open('m100');
  await flush(tester);
  expect(_bar, findsOneWidget);
  return harness;
}

/// Drift's stream teardown leaves a zero-length timer that a bare end of test
/// reports as pending.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('the window\'s newest message clears the bar at the bottom', (
    tester,
  ) async {
    await _mountInContext(tester);
    transcriptScroll(tester).jumpTo(0);
    await flush(tester);

    final newest = tester.getRect(find.text('message 150'));
    expect(
      newest.bottom,
      lessThanOrEqualTo(tester.getRect(_bar).top),
      reason: 'a reversed list cannot scroll past its newest row',
    );

    await _unmount(tester);
  });

  testWidgets('sending from the window returns to the live channel and '
      'shows the sent message', (tester) async {
    final harness = await _mountInContext(tester);

    await tester.enterText(_composerField, 'replying from the past');
    await flush(tester);
    await tester.tap(find.byTooltip('Send message'));
    await flush(tester);

    expect(harness.container.read(messageContextWindowProvider('c1')), isNull);
    expect(_bar, findsNothing);
    final sent = find.text('replying from the past');
    expect(sent, findsOneWidget);
    expect(
      tester.getRect(_transcript).contains(tester.getCenter(sent)),
      isTrue,
    );

    await _unmount(tester);
  });

  testWidgets('at the bottom of the window, messages that arrived since are '
      'not marked read until Jump to present', (tester) async {
    final reads = <String>[];
    final harness = await _mountInContext(tester, reads: reads);
    final before = (await harness.store.channelRow('c1'))!.lastReadSeq;
    reads.clear();

    await harness.store.applyMessage(channelMessage(1601));
    await flush(tester);
    expect((await harness.store.channelRow('c1'))!.cursor, 1601);
    transcriptScroll(tester).jumpTo(40);
    await flush(tester);
    transcriptScroll(tester).jumpTo(0);
    await flush(tester);

    expect(reads, isEmpty, reason: 'nothing past the window was shown');
    expect((await harness.store.channelRow('c1'))!.lastReadSeq, before);

    await tester.tap(find.text('Jump to present'));
    await flush(tester);
    expect((await harness.store.channelRow('c1'))!.lastReadSeq, 1601);

    await _unmount(tester);
  });
}
