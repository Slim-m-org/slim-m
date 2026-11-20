// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The palette as the app's one message search: a conversation's search
/// button opens it with an `in:` chip, filter keys autocomplete into chips,
/// and the keyboard does all of it - arrows, Enter, Tab and Backspace.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_jump.dart';
import 'package:slimm_app/src/features/palette/widgets/conversation_search.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../command_palette_harness.dart';

Map<String, dynamic> _hit(int seq) => {
  'id': 'm$seq',
  'channel_id': 'c1',
  'author_id': 'other',
  'author_display_name': 'Ren',
  'seq': seq,
  'content': 'hello number $seq',
  'created_at': seq,
  'edited_at': null,
};

final _input = find.byKey(const Key('command-palette-input'));

Finder _chip(String text) => find.text(text, findRichText: true);

typedef _Opened = ({
  List<Uri> searches,
  ({ProviderContainer container, SlimmDatabase db}) setup,
});

Future<_Opened> _openInGeneral(
  WidgetTester tester, {
  List<Map<String, dynamic>> hits = const [],
}) async {
  final searches = <Uri>[];
  final setup = setupPalette(hits: hits, onSearch: searches.add);
  await MessageStore(setup.db).upsertChannels(const [
    api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
    api.Channel(id: 'c2', name: 'random', kind: 'text', createdAt: 0),
  ]);
  await pump(tester, setup.container, initial: '/channels/c1');
  unawaited(
    openConversationSearch(
      tester.element(find.text('conversation')),
      channelId: 'c1',
      label: '#general',
    ),
  );
  await _frames(tester);
  return (searches: searches, setup: setup);
}

/// Bounded frames: the field's caret blink keeps a frame pending forever.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

String _fieldText(WidgetTester tester) =>
    tester.widget<AppInput>(_input).controller!.text;

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(_input, text);
  await _frames(tester);
}

Future<void> _close(WidgetTester tester, _Opened opened) =>
    teardown(tester, opened.setup.container, opened.setup.db);

/// A raw Enter never reaches `onSubmitted` under flutter_test; the IME action does.
Future<void> _enter(WidgetTester tester) async {
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await _frames(tester);
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await _frames(tester);
}

void main() {
  testWidgets('a conversation search opens on its in: chip with the options '
      'to narrow it, and searches nothing yet', (tester) async {
    final opened = await _openInGeneral(tester);
    final searches = opened.searches;

    expect(_chip('in: #general'), findsOneWidget);
    expect(inPalette('Search messages'), findsOneWidget);
    expect(inPalette('SEARCH OPTIONS'), findsOneWidget);
    for (final key in ['from:', 'mentions:', 'has:', 'pinned:', 'during:']) {
      expect(inPalette(key), findsOneWidget, reason: key);
    }
    expect(inPalette('People'), findsNothing, reason: 'a message search only');
    expect(searches, isEmpty);

    await _close(tester, opened);
  });

  testWidgets('a key offers its values, Enter makes the highlighted one a '
      'chip, and the text after it searches this channel', (tester) async {
    final opened = await _openInGeneral(tester, hits: [_hit(1)]);
    final searches = opened.searches;

    await _type(tester, 'from:re');
    expect(inPalette('Ren'), findsOneWidget);
    expect(inPalette('@ren'), findsOneWidget);
    expect(searches, isEmpty, reason: 'a value still being typed is not run');

    await _enter(tester);
    expect(_chip('from: Ren'), findsOneWidget);
    expect(_fieldText(tester), '');

    await _type(tester, 'hello');
    expect(searches.last.path, '/channels/c1/messages/search');
    expect(searches.last.queryParameters['from'], 'ren');
    expect(searches.last.queryParameters['q'], 'hello');
    expect(searches.last.queryParameters.containsKey('in'), isFalse);
    expect(inPalette('MESSAGES'), findsOneWidget);

    await _close(tester, opened);
  });

  testWidgets('Tab completes a key, arrows pick a value, and Backspace in an '
      'empty field takes the chips back off one by one', (tester) async {
    final opened = await _openInGeneral(tester);

    await _type(tester, 'ha');
    await _key(tester, LogicalKeyboardKey.tab);
    expect(_fieldText(tester), 'has:');
    expect(inPalette('Images and GIFs'), findsOneWidget);

    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _enter(tester);
    expect(_chip('has: video'), findsOneWidget);

    await _key(tester, LogicalKeyboardKey.backspace);
    expect(_chip('has: video'), findsNothing);
    expect(_chip('in: #general'), findsOneWidget);

    await _key(tester, LogicalKeyboardKey.backspace);
    expect(_chip('in: #general'), findsNothing);
    expect(
      inPalette('Search channels, people and messages'),
      findsOneWidget,
      reason: 'with no chips left it is the whole palette again',
    );

    await _close(tester, opened);
  });

  testWidgets('Left from the field steps onto the chips, so a middle one can '
      'be removed by keyboard, and Right comes back', (tester) async {
    final opened = await _openInGeneral(tester);
    await _type(tester, 'pinned:true has:image ');
    expect(_chip('pinned: true'), findsOneWidget);
    expect(_fieldText(tester), '');

    String? focused() => FocusManager.instance.primaryFocus?.debugLabel;
    await _key(tester, LogicalKeyboardKey.arrowLeft);
    expect(focused(), 'palette-filter-2');
    await _key(tester, LogicalKeyboardKey.arrowLeft);
    expect(focused(), 'palette-filter-1');

    await _key(tester, LogicalKeyboardKey.delete);
    expect(_chip('pinned: true'), findsNothing);
    expect(_chip('has: image'), findsOneWidget);
    expect(_chip('in: #general'), findsOneWidget);
    expect(focused(), 'palette-filter-0', reason: 'the chip before it');

    await _key(tester, LogicalKeyboardKey.arrowRight);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(
      tester.widget<AppInput>(_input).focusNode!.hasFocus,
      isTrue,
      reason: 'right past the last chip is the field again',
    );

    await _close(tester, opened);
  });

  testWidgets('a finished filter typed by hand becomes a chip, and tapping a '
      'chip removes it', (tester) async {
    final opened = await _openInGeneral(tester);
    final searches = opened.searches;

    await _type(tester, 'pinned:true launch');
    expect(_chip('pinned: true'), findsOneWidget);
    expect(searches.last.queryParameters['pinned'], 'true');
    expect(searches.last.queryParameters['q'], 'launch');

    await tester.tap(_chip('pinned: true'));
    await _frames(tester);
    expect(_chip('pinned: true'), findsNothing);
    expect(searches.last.queryParameters.containsKey('pinned'), isFalse);

    await _close(tester, opened);
  });

  testWidgets('fast typing sends one search, for the words it settled on', (
    tester,
  ) async {
    final opened = await _openInGeneral(tester);
    final searches = opened.searches;

    for (final text in ['l', 'la', 'lau', 'laun', 'launch']) {
      await tester.enterText(_input, text);
      await tester.pump(const Duration(milliseconds: 60));
    }
    await _frames(tester);

    expect(searches, hasLength(1));
    expect(searches.single.queryParameters['q'], 'launch');

    await _close(tester, opened);
  });

  testWidgets('a conversation\'s search comes back as it was left, and '
      'another conversation\'s starts clean', (tester) async {
    final opened = await _openInGeneral(tester, hits: [_hit(3)]);
    await _type(tester, 'pinned:true launch');
    await _key(tester, LogicalKeyboardKey.escape);
    expect(_input, findsNothing);

    Future<void> reopen(String channelId, String label) async {
      unawaited(
        openConversationSearch(
          tester.element(find.text('conversation')),
          channelId: channelId,
          label: label,
        ),
      );
      await _frames(tester);
    }

    final before = opened.searches.length;
    await reopen('c1', '#general');
    expect(_chip('in: #general'), findsOneWidget);
    expect(_chip('pinned: true'), findsOneWidget);
    expect(_fieldText(tester), 'launch');
    expect(opened.searches.length, before + 1, reason: 'its hits come back');
    expect(inPalette('MESSAGES'), findsOneWidget);
    await _key(tester, LogicalKeyboardKey.escape);

    await reopen('c2', '#random');
    expect(_chip('in: #random'), findsOneWidget);
    expect(_chip('pinned: true'), findsNothing);
    expect(_fieldText(tester), '');

    await _close(tester, opened);
  });

  testWidgets('a full page offers more, fetched after the last hit shown', (
    tester,
  ) async {
    final opened = await _openInGeneral(
      tester,
      hits: [for (var seq = 30; seq > 5; seq--) _hit(seq)],
    );
    final searches = opened.searches;

    await _type(tester, 'hello');
    final more = inPalette('Show more messages');
    await tester.ensureVisible(more);
    await _frames(tester);
    await tester.tap(more);
    await _frames(tester);

    expect(searches.last.queryParameters['before_id'], 'm6');
    expect(inPalette('Search messages'), findsOneWidget, reason: 'still open');

    await _close(tester, opened);
  });

  testWidgets('Enter on a hit closes the palette and jumps to the message', (
    tester,
  ) async {
    final opened = await _openInGeneral(tester, hits: [_hit(7)]);
    final container = ProviderScope.containerOf(
      tester.element(find.text('conversation')),
    );

    await _type(tester, 'hello ');
    expect(inPalette('SEARCH OPTIONS'), findsNothing);
    await _enter(tester);

    expect(_input, findsNothing);
    final jump = container.read(messageJumpProvider);
    expect(jump, isNot(isA<MessageJumpIdle>()));

    await _close(tester, opened);
  });
}
