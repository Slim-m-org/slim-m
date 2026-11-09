// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Searching one channel at phone width, the way a thumb does it: the search
/// is a full page in the command palette's own shape (a field with Cancel, a
/// section header, palette rows), not a second bar stacked under the app bar.
///
/// The harness's 500-wide window is compact, so these drive the real
/// [ChannelScreen] at the width the owner hit "Win" finding nothing and "iso"
/// finding a file in. The wide panel's own behaviour is pinned at the end.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/channel_search_controller.dart';
import 'package:slimm_app/src/features/channels/widgets/compact_channel_search.dart'
    show channelSearchScope;
import 'package:slimm_app/src/features/messages/providers/message_jump.dart';
import 'package:slimm_app/src/features/messages/widgets/message_jump.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../channel_history_harness.dart';

const _fileName = 'Win11_24H2_English_x64.iso';

final _cancel = find.byKey(const Key('channel-search-cancel'));
final _field = find.byWidgetPredicate((w) => w is EditableText);
final _richText = find.byWidgetPredicate((w) => w is RichText);

Map<String, dynamic> _textHit() => {
  'id': 'm50',
  'channel_id': 'c1',
  'author_id': 'alice',
  'author_display_name': 'alice',
  'seq': 50,
  'content': 'a very findable message',
  'created_at': DateTime.now().millisecondsSinceEpoch,
  'edited_at': null,
};

Map<String, dynamic> _fileHit() => {
  'id': 'm51',
  'channel_id': 'c1',
  'author_id': 'alice',
  'author_display_name': 'alice',
  'seq': 51,
  'content': '',
  'created_at': DateTime.now().millisecondsSinceEpoch,
  'edited_at': null,
  'attachments': [
    {
      'id': 'a51',
      'filename': _fileName,
      'content_type': 'application/octet-stream',
      'size': 5000000000,
    },
  ],
  'matched_attachment_id': 'a51',
};

Future<HistoryHarness> _mount(
  WidgetTester tester, {
  List<Map<String, dynamic>> hits = const [],
}) => mountChannel(
  tester,
  serverSeqs: const [1, 2, 3],
  seededSeqs: const [1, 2, 3],
  searchHits: hits,
);

Future<void> _open(WidgetTester tester, HistoryHarness harness) async {
  harness.container.read(channelSearchProvider('c1').notifier).toggle();
  await flush(tester);
}

Future<void> _type(WidgetTester tester, String query) async {
  await tester.enterText(_field.first, query);
  await tester.pump(channelSearchDebounce);
  await flush(tester);
}

/// What is drawn bold by a highlight: the one place the rows use semi-bold.
List<String> _highlighted(WidgetTester tester) {
  final words = <String>[];
  for (final rich in tester.widgetList<RichText>(_richText)) {
    rich.text.visitChildren((span) {
      if (span is TextSpan &&
          span.style?.fontWeight == AppWeights.semi &&
          span.text != null) {
        words.add(span.text!);
      }
      return true;
    });
  }
  return words;
}

/// Unmounting deliberately; see `channel_history_test.dart` for why.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  testWidgets('opening search puts a page with Cancel over the transcript', (
    tester,
  ) async {
    final harness = await _mount(tester);
    expect(find.text('message 3'), findsOneWidget);
    expect(find.text('Message #general'), findsOneWidget);

    await _open(tester, harness);

    expect(_cancel, findsOneWidget);
    expect(find.text('Search #general'), findsOneWidget);
    expect(find.text('MESSAGES IN #GENERAL'), findsOneWidget);
    expect(find.text('Type to search.'), findsOneWidget);
    expect(
      find.text('message 3'),
      findsNothing,
      reason: 'the transcript is not what an empty search shows',
    );
    expect(
      find.text('Message #general'),
      findsNothing,
      reason: 'a composer under a search field reads as a second field',
    );
    await _unmount(tester);
  });

  testWidgets('typing lists the hits as palette rows with the match marked', (
    tester,
  ) async {
    final harness = await _mount(tester, hits: [_textHit(), _fileHit()]);
    await _open(tester, harness);

    await _type(tester, 'findable');

    expect(find.textContaining('Today'), findsWidgets);
    expect(find.text('a very findable message'), findsOneWidget);
    expect(_highlighted(tester), contains('findable'));
    await _unmount(tester);
  });

  testWidgets('a file hit says which file it was found in, match marked', (
    tester,
  ) async {
    final harness = await _mount(tester, hits: [_fileHit()]);
    await _open(tester, harness);

    await _type(tester, 'win');

    expect(find.text(_fileName), findsOneWidget);
    expect(find.textContaining('\u00B7 in $_fileName'), findsOneWidget);
    expect(_highlighted(tester), contains('Win'));
    await _unmount(tester);
  });

  testWidgets('a search with no hits says so under the same scope', (
    tester,
  ) async {
    final harness = await _mount(tester);
    await _open(tester, harness);

    await _type(tester, 'nothing');

    expect(find.text('No matches.'), findsOneWidget);
    expect(find.text('MESSAGES IN #GENERAL'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('Cancel closes the page and gives the channel back', (
    tester,
  ) async {
    final harness = await _mount(tester, hits: [_textHit()]);
    await _open(tester, harness);
    await _type(tester, 'findable');

    await tester.tap(_cancel);
    await flush(tester);

    expect(harness.container.read(channelSearchProvider('c1')).open, isFalse);
    expect(_cancel, findsNothing);
    expect(find.text('message 3'), findsOneWidget);
    expect(find.text('Message #general'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('a wide window keeps the panel under the header, with no '
      'Cancel', (tester) async {
    final harness = await _mount(tester, hits: [_textHit()]);
    tester.view.physicalSize = const Size(900, 800);
    await flush(tester);
    await _open(tester, harness);

    expect(find.text('Search this channel'), findsOneWidget);
    expect(_cancel, findsNothing);
    expect(find.text('MESSAGES IN #GENERAL'), findsNothing);
    expect(find.text('Message #general'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('a wide window leaves an open, empty search bar alone when a '
      'jump lands', (tester) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: List.generate(120, (i) => i + 1),
      seededSeqs: List.generate(50, (i) => i + 71),
    );
    tester.view.physicalSize = const Size(900, 800);
    await flush(tester);
    await _open(tester, harness);

    unawaited(
      harness.container.read(messageJumpProvider.notifier).jumpTo('c1', 'm100'),
    );
    final flash = find.byWidgetPredicate((w) => w is MessageJumpHighlight);
    for (var i = 0; i < 100 && flash.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(flash, findsOneWidget);
    expect(harness.container.read(channelSearchProvider('c1')).open, isTrue);
    await tester.pump(const Duration(seconds: 3));
    await _unmount(tester);
  });

  test('a search is named for what it covers', () {
    String scope(String? name, {bool voice = false, bool thread = false}) =>
        channelSearchScope(name: name, isVoice: voice, isThread: thread);

    expect(scope('general'), '#general');
    expect(scope('Lounge', voice: true), 'Lounge');
    expect(scope('ignored', thread: true), 'this thread');
    expect(scope(null), 'this conversation');
    expect(scope(''), 'this conversation');
  });
}
