// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Searching a channel on a phone and tapping a hit that sits far back in its
/// history: the owner's "Win11_24H2_English_x64.iso" report, where the hit
/// listed "Found in" its file name and tapping it did nothing.
///
/// Drives the real [ChannelScreen] at 390x844 with the real search field, a
/// fake server that pages history the way the real one does, and a search
/// route that names a message outside what is loaded.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/channel_search_controller.dart';
import 'package:slimm_app/src/features/channels/widgets/compact_channel_search.dart';
import 'package:slimm_app/src/features/messages/providers/message_jump.dart';
import 'package:slimm_app/src/features/messages/widgets/message_jump.dart';

import '../../channel_history_harness.dart';

List<int> _range(int from, int to) => [
  for (var seq = from; seq <= to; seq++) seq,
];

const _fileName = 'Win11_24H2_English_x64.iso';

/// An attachment-only message, found through the file's name.
Map<String, dynamic> _fileHit(int seq, {String channelId = 'c1'}) => {
  'id': 'm$seq',
  'channel_id': channelId,
  'author_id': 'alice',
  'author_display_name': 'alice',
  'seq': seq,
  'content': '',
  'created_at': seq * 60000,
  'edited_at': null,
  'attachments': [
    {
      'id': 'a$seq',
      'filename': _fileName,
      'content_type': 'application/octet-stream',
      'size': 5000000000,
    },
  ],
  'matched_attachment_id': 'a$seq',
};

final _searchBar = find.byWidgetPredicate((w) => w is CompactChannelSearchBar);

/// The hit row, whose text is the file's name since only the file matched.
final _hit = find.text(_fileName);
final _flash = find.byWidgetPredicate((w) => w is MessageJumpHighlight);
final _snackBar = find.byWidgetPredicate((w) => w is SnackBar);

/// The compact app bar's magnifier toggles this same provider, so opening it
/// here is the tap; the query itself is typed into the real field.
Future<void> _searchFor(WidgetTester tester, HistoryHarness harness) async {
  harness.container.read(channelSearchProvider('c1').notifier).toggle();
  await flush(tester);
  await tester.enterText(_searchBar, 'iso');
  await tester.pump(channelSearchDebounce);
  await flush(tester);
}

Future<HistoryHarness> _mountPhone(
  WidgetTester tester, {
  required List<int> serverSeqs,
  required List<int> seededSeqs,
  required int hitSeq,
  bool holdOlderPages = false,
  bool olderPagesFail = false,
  String hitChannelId = 'c1',
  bool typeQuery = true,
}) async {
  final harness = await mountChannel(
    tester,
    serverSeqs: serverSeqs,
    seededSeqs: seededSeqs,
    searchHits: [_fileHit(hitSeq, channelId: hitChannelId)],
    holdOlderPages: holdOlderPages,
    olderPagesFail: olderPagesFail,
  );
  tester.view.physicalSize = const Size(390, 844);
  await flush(tester);
  if (typeQuery) {
    await _searchFor(tester, harness);
  } else {
    harness.container.read(channelSearchProvider('c1').notifier).toggle();
    await flush(tester);
  }
  return harness;
}

/// Unmounting deliberately; see `channel_history_test.dart` for why.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

Future<void> _tapHit(WidgetTester tester) async {
  expect(_hit, findsOneWidget);
  await tester.tap(_hit);
  await tester.pump();
}

/// Lets the jump run until the row is flashing or the jump has ended without
/// arriving. Stopping there matters: the flash is consumed after about three
/// seconds, and a longer wait would read a handled arrival as none.
Future<bool> _untilLanded(WidgetTester tester, HistoryHarness harness) async {
  for (var i = 0; i < 600; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (_flash.evaluate().isNotEmpty) return true;
    final state = harness.container.read(messageJumpProvider);
    if (state is! MessageJumpSeeking && state is! MessageJumpArrived) {
      return false;
    }
  }
  return false;
}

void main() {
  testWidgets('a hit already loaded takes the reader to its row', (
    tester,
  ) async {
    final harness = await _mountPhone(
      tester,
      serverSeqs: _range(1, 120),
      seededSeqs: _range(71, 120),
      hitSeq: 100,
    );
    await _tapHit(tester);

    expect(await _untilLanded(tester, harness), isTrue);
    expect(harness.container.read(channelSearchProvider('c1')).open, isFalse);

    await tester.pump(const Duration(seconds: 3));
    await _unmount(tester);
  });

  testWidgets('a hit held locally but outside the transcript window still '
      'lands on its row', (tester) async {
    // 700 rows held, as after scrolling back last session; the transcript opens on 200.
    final harness = await _mountPhone(
      tester,
      serverSeqs: _range(1, 1000),
      seededSeqs: _range(301, 1000),
      hitSeq: 400,
    );
    await _tapHit(tester);

    expect(
      await _untilLanded(tester, harness),
      isTrue,
      reason: 'the hit is in the store, so the transcript must show its row',
    );

    await tester.pump(const Duration(seconds: 3));
    await _unmount(tester);
  });

  testWidgets('a hit 700 messages back, past the old 500 bound, is paged in '
      'and landed on', (tester) async {
    final harness = await _mountPhone(
      tester,
      serverSeqs: _range(1, 1000),
      seededSeqs: _range(951, 1000),
      hitSeq: 300,
    );
    await _tapHit(tester);

    expect(await _untilLanded(tester, harness), isTrue);

    await tester.pump(const Duration(seconds: 3));
    await _unmount(tester);
  });

  testWidgets('the panel says it is finding the message while pages load', (
    tester,
  ) async {
    final harness = await _mountPhone(
      tester,
      serverSeqs: _range(1, 400),
      seededSeqs: _range(351, 400),
      hitSeq: 100,
      holdOlderPages: true,
    );
    await _tapHit(tester);
    await flush(tester);

    expect(
      find.text('Finding that message'),
      findsOneWidget,
      reason: 'a tap with no sign of progress reads as a tap that did nothing',
    );
    expect(_searchBar, findsOneWidget);

    harness.releaseOlderPages();
    expect(await _untilLanded(tester, harness), isTrue);

    await tester.pump(const Duration(seconds: 3));
    await _unmount(tester);
  });

  testWidgets('a hit past what the transcript can hold is explained in the '
      'panel, not in a snack bar', (tester) async {
    final harness = await _mountPhone(
      tester,
      serverSeqs: _range(1, 1600),
      seededSeqs: _range(1551, 1600),
      hitSeq: 100,
    );
    await _tapHit(tester);

    expect(await _untilLanded(tester, harness), isFalse);
    await flush(tester);

    expect(find.textContaining('Could not find that message'), findsOneWidget);
    expect(_searchBar, findsOneWidget, reason: 'the hits stay for another try');
    expect(_hit, findsOneWidget);
    expect(_snackBar, findsNothing);

    await _unmount(tester);
  });

  testWidgets('a page that cannot be fetched offers a retry in the panel', (
    tester,
  ) async {
    final harness = await _mountPhone(
      tester,
      serverSeqs: _range(1, 200),
      seededSeqs: _range(151, 200),
      hitSeq: 100,
      olderPagesFail: true,
    );
    await _tapHit(tester);

    expect(await _untilLanded(tester, harness), isFalse);
    await flush(tester);

    expect(
      find.text('Could not load older messages to find it. Try again.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
    expect(_searchBar, findsOneWidget);
    expect(_snackBar, findsNothing);

    await _unmount(tester);
  });

  testWidgets('a hit in another channel clears this search on the way out', (
    tester,
  ) async {
    await _mountPhone(
      tester,
      serverSeqs: _range(1, 120),
      seededSeqs: _range(71, 120),
      hitSeq: 100,
      hitChannelId: 'c2',
    );
    final container = ProviderScope.containerOf(tester.element(_searchBar));
    await _tapHit(tester);
    await tester.pump(const Duration(milliseconds: 100));

    expect(container.read(channelSearchProvider('c1')).open, isFalse);

    await tester.pump(const Duration(seconds: 3));
    await _unmount(tester);
  });

  testWidgets('a jump from elsewhere closes an empty search page, so the '
      'row it lands on can be seen', (tester) async {
    final harness = await _mountPhone(
      tester,
      serverSeqs: _range(1, 120),
      seededSeqs: _range(71, 120),
      hitSeq: 100,
      typeQuery: false,
    );
    unawaited(
      harness.container.read(messageJumpProvider.notifier).jumpTo('c1', 'm100'),
    );

    expect(await _untilLanded(tester, harness), isTrue);
    expect(harness.container.read(channelSearchProvider('c1')).open, isFalse);
    expect(_searchBar, findsNothing);

    await tester.pump(const Duration(seconds: 3));
    await _unmount(tester);
  });

  testWidgets('typing a new query drops the hit that was being found', (
    tester,
  ) async {
    final harness = await _mountPhone(
      tester,
      serverSeqs: _range(1, 400),
      seededSeqs: _range(351, 400),
      hitSeq: 100,
      holdOlderPages: true,
    );
    await _tapHit(tester);
    await flush(tester);
    expect(find.text('Finding that message'), findsOneWidget);

    await tester.enterText(_searchBar, 'iso image');
    await tester.pump(channelSearchDebounce);
    harness.releaseOlderPages();
    await flush(tester);
    await flush(tester);

    expect(find.text('Finding that message'), findsNothing);
    expect(_flash, findsNothing);
    expect(harness.container.read(channelSearchProvider('c1')).open, isTrue);
    expect(_hit, findsOneWidget);

    await _unmount(tester);
  });
}
