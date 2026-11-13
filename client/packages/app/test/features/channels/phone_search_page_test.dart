// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the phone's search page leaves alone and what it says: the transcript
/// underneath keeps its place across a look through search, and the page names
/// the channel it actually searched, hit by hit.
///
/// Drives the real [ChannelScreen] in the harness's 500-wide (compact) window.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_search_controller.dart';
import 'package:slimm_app/src/features/messages/providers/message_jump.dart';
import 'package:slimm_app/src/features/palette/widgets/command_palette_rows.dart'
    show PaletteResultRow;

import '../../channel_history_harness.dart';

final _cancel = find.byKey(const Key('channel-search-cancel'));
final _field = find.byWidgetPredicate((w) => w is EditableText);
final _row = find.byWidgetPredicate((w) => w is PaletteResultRow);

List<int> _range(int from, int to) => [
  for (var seq = from; seq <= to; seq++) seq,
];

Map<String, dynamic> _hit({String channelId = 'c1'}) => {
  'id': 'm50',
  'channel_id': channelId,
  'author_id': 'alice',
  'author_display_name': 'alice',
  'seq': 50,
  'content': 'a very findable message',
  'created_at': DateTime.now().millisecondsSinceEpoch,
  'edited_at': null,
};

Future<void> _open(WidgetTester tester, HistoryHarness harness) async {
  harness.container.read(channelSearchProvider('c1').notifier).toggle();
  await flush(tester);
}

Future<void> _type(WidgetTester tester, String query) async {
  await tester.enterText(_field.first, query);
  await tester.pump(channelSearchDebounce);
  await flush(tester);
}

/// Unmounting deliberately; see `channel_history_test.dart` for why.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  testWidgets('Cancel gives back a transcript still scrolled where it was', (
    tester,
  ) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(1, 200),
      seededSeqs: _range(1, 200),
      searchHits: [_hit()],
    );
    final scroll = transcriptScroll(tester);
    scroll.jumpTo(1500);
    await flush(tester);
    expect(scroll.offset, 1500);

    await _open(tester, harness);
    await tester.tap(_cancel);
    await flush(tester);
    expect(scroll.offset, 1500, reason: 'an empty page never touched it');

    await _open(tester, harness);
    await _type(tester, 'findable');
    await tester.tap(_cancel);
    await flush(tester);
    expect(scroll.offset, 1500, reason: 'nor did a search that found a hit');
    await _unmount(tester);
  });

  testWidgets('a refused jump is not shown again on the next search', (
    tester,
  ) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: [..._range(1, 49), ..._range(51, 1600)],
      seededSeqs: _range(1551, 1600),
      searchHits: [_hit()],
    );
    await _open(tester, harness);
    await _type(tester, 'findable');
    await tester.tap(find.text('a very findable message'));
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      harness.container.read(messageJumpProvider),
      isA<MessageJumpUnreachable>(),
    );
    expect(find.textContaining('Could not find that message'), findsOneWidget);

    await tester.tap(_cancel);
    await flush(tester);
    await _open(tester, harness);

    expect(find.textContaining('Could not find that message'), findsNothing);
    expect(harness.container.read(messageJumpProvider), isA<MessageJumpIdle>());
    await _unmount(tester);
  });

  testWidgets('a search in another channel is headed by that channel and '
      'each hit names its own', (tester) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(1, 3),
      seededSeqs: _range(1, 3),
      searchHits: [
        _hit(),
        _hit(channelId: 'c2')..['id'] = 'm51',
      ],
    );
    await harness.store.upsertChannels([
      const api.Channel(id: 'c2', name: 'random', kind: 'text', createdAt: 0),
    ]);
    await _open(tester, harness);

    await _type(tester, 'findable');
    expect(find.text('MESSAGES IN #GENERAL'), findsOneWidget);

    await _type(tester, 'in:random findable');
    expect(find.text('MESSAGES IN #RANDOM'), findsOneWidget);
    expect(find.text('MESSAGES IN #GENERAL'), findsNothing);
    expect(find.textContaining(' in #random \u00B7'), findsOneWidget);
    expect(find.textContaining(' in #general \u00B7'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('a hit is a palette message row a keyboard can open', (
    tester,
  ) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(1, 3),
      seededSeqs: _range(1, 3),
      searchHits: [_hit()],
    );
    await _open(tester, harness);
    await _type(tester, 'findable');
    expect(_row, findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(
      harness.container.read(messageJumpProvider),
      isNot(isA<MessageJumpIdle>()),
      reason: 'Enter on the focused hit starts the jump to it',
    );
    await _unmount(tester);
  });
}
