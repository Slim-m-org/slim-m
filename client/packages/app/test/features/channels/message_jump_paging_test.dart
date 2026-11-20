// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opening a search hit that sits far back in a channel's history, the way
/// the palette does: the owner's "Win11_24H2_English_x64.iso" report, where
/// tapping the hit did nothing.
///
/// Drives the real [ChannelScreen] at 390x844 with a fake server that pages
/// history the way the real one does, jumping to a message outside what is
/// loaded; how it is going shows above the transcript, never as a snack bar.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

final _flash = find.byWidgetPredicate((w) => w is MessageJumpHighlight);

/// The transcript's own list, whose rect is what "on screen" means here.
final _transcript = find.byWidgetPredicate((w) => w is Scrollable).first;
final _snackBar = find.byWidgetPredicate((w) => w is SnackBar);

Future<HistoryHarness> _mountPhone(
  WidgetTester tester, {
  required List<int> serverSeqs,
  required List<int> seededSeqs,
  required int hitSeq,
  bool holdOlderPages = false,
  bool olderPagesFail = false,
}) async {
  final harness = await mountChannel(
    tester,
    serverSeqs: serverSeqs,
    seededSeqs: seededSeqs,
    searchHits: [_fileHit(hitSeq)],
    holdOlderPages: holdOlderPages,
    olderPagesFail: olderPagesFail,
  );
  tester.view.physicalSize = const Size(390, 844);
  await flush(tester);
  return harness;
}

/// Unmounting deliberately; see `channel_history_test.dart` for why.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

/// What picking the hit in the palette does once the palette has closed.
Future<void> _openHit(
  WidgetTester tester,
  HistoryHarness harness,
  int seq,
) async {
  unawaited(
    harness.container.read(messageJumpProvider.notifier).jumpTo('c1', 'm$seq'),
  );
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
    await _openHit(tester, harness, 100);

    expect(await _untilLanded(tester, harness), isTrue);

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
    await _openHit(tester, harness, 400);

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
    await _openHit(tester, harness, 300);

    expect(await _untilLanded(tester, harness), isTrue);

    await tester.pump(const Duration(seconds: 3));
    await _unmount(tester);
  });

  testWidgets('it says it is finding the message while pages load', (
    tester,
  ) async {
    final harness = await _mountPhone(
      tester,
      serverSeqs: _range(1, 400),
      seededSeqs: _range(351, 400),
      hitSeq: 100,
      holdOlderPages: true,
    );
    await _openHit(tester, harness, 100);
    await flush(tester);

    expect(
      find.text('Finding that message'),
      findsOneWidget,
      reason: 'a tap with no sign of progress reads as a tap that did nothing',
    );

    harness.releaseOlderPages();
    expect(await _untilLanded(tester, harness), isTrue);

    await tester.pump(const Duration(seconds: 3));
    await _unmount(tester);
  });

  testWidgets('a hit past what the transcript can hold opens a window '
      'around it, and Jump to present returns', (tester) async {
    final harness = await _mountPhone(
      tester,
      serverSeqs: _range(1, 1600),
      seededSeqs: _range(1551, 1600),
      hitSeq: 100,
    );
    await _openHit(tester, harness, 100);

    expect(await _untilLanded(tester, harness), isTrue);
    await tester.pump(const Duration(seconds: 1));

    final viewport = tester.getRect(_transcript);
    final target = tester.getRect(find.text('message 100'));
    expect(viewport.contains(target.center), isTrue);
    expect(find.text('message 1600'), findsNothing);
    expect(find.text('Jump to present'), findsOneWidget);
    expect(_snackBar, findsNothing);

    await tester.tap(find.text('Jump to present'));
    await flush(tester);

    expect(find.text('Jump to present'), findsNothing);
    final live = tester.getRect(find.text('message 1600'));
    expect(tester.getRect(_transcript).contains(live.center), isTrue);
    expect(find.text('message 100'), findsNothing);

    await tester.pump(const Duration(seconds: 3));
    await _unmount(tester);
  });

  testWidgets('a hit the server no longer has is explained above the '
      'transcript, not in a snack bar', (tester) async {
    final harness = await _mountPhone(
      tester,
      serverSeqs: _range(2, 1600),
      seededSeqs: _range(1551, 1600),
      hitSeq: 1,
    );
    await _openHit(tester, harness, 1);

    expect(await _untilLanded(tester, harness), isFalse);
    await flush(tester);

    expect(find.textContaining('Could not find that message'), findsOneWidget);
    expect(_snackBar, findsNothing);

    await _unmount(tester);
  });

  testWidgets(
    'a page that cannot be fetched offers a retry above the transcript',
    (tester) async {
      final harness = await _mountPhone(
        tester,
        serverSeqs: _range(1, 200),
        seededSeqs: _range(151, 200),
        hitSeq: 100,
        olderPagesFail: true,
      );
      await _openHit(tester, harness, 100);

      expect(await _untilLanded(tester, harness), isFalse);
      await flush(tester);

      expect(
        find.text('Could not load older messages to find it. Try again.'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
      expect(_snackBar, findsNothing);

      await _unmount(tester);
    },
  );
}
