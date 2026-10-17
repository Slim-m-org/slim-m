// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the command palette's own message search: it went unfiltered
/// when blocking was wired up everywhere else, and it used to collapse
/// every search failure to "no matches" rather than explaining a 403.
///
/// Split out of `command_palette_test.dart`, which crossed the file's
/// 500-line hard budget; shared fixtures live in
/// `command_palette_harness.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_jump.dart';
import 'package:slimm_data/data.dart';

import '../../command_palette_harness.dart';

void main() {
  /// The palette runs its own message search, separate from
  /// `channelSearchProvider`, and renders both the body and the author's name.
  /// It went unfiltered when blocking was wired up everywhere else, so pressing
  /// Ctrl+K and typing a word a blocked person had used showed it in full.
  testWidgets('a blocked author is absent from the palette message results', (
    tester,
  ) async {
    final setup = setupPalette(
      blocked: ['pest'],
      hits: [
        {
          'id': 'm1',
          'channel_id': 'c1',
          'author_id': 'pest',
          'author_display_name': 'Pest',
          'seq': 1,
          'content': 'from a pest',
          'created_at': 0,
          'edited_at': null,
        },
        {
          'id': 'm2',
          'channel_id': 'c1',
          'author_id': 'other',
          'author_display_name': 'Ren',
          'seq': 2,
          'content': 'from a friend',
          'created_at': 0,
          'edited_at': null,
        },
      ],
    );
    await MessageStore(setup.db).upsertChannels(const [
      api.Channel(id: 'ch1', name: 'general', kind: 'text', createdAt: 0),
    ]);
    await pump(tester, setup.container, initial: '/channels/ch1');
    await pressCtrlK(tester);

    await tester.enterText(
      find.byKey(const Key('command-palette-input')),
      'from',
    );
    await tester.pumpAndSettle();

    expect(inPalette('from a friend'), findsOneWidget);
    expect(
      inPalette('from a pest'),
      findsNothing,
      reason: 'a second search path is still a search path',
    );

    await teardown(tester, setup.container, setup.db);
  });

  /// The palette used to scope message search to whichever channel was
  /// open, and skip it entirely with none open at all - there was no
  /// cross-channel search endpoint to call. `GET /search/messages` changed
  /// that: a hit surfaces here with no channel selected.
  testWidgets('message search runs with no channel open at all', (
    tester,
  ) async {
    final setup = setupPalette(
      hits: [
        {
          'id': 'm1',
          'channel_id': 'ch1',
          'author_id': 'other',
          'author_display_name': 'Ren',
          'seq': 1,
          'content': 'found from nowhere in particular',
          'created_at': 0,
          'edited_at': null,
        },
      ],
    );
    await pump(tester, setup.container, initial: '/channels');
    await pressCtrlK(tester);

    await tester.enterText(
      find.byKey(const Key('command-palette-input')),
      'nowhere',
    );
    await tester.pumpAndSettle();

    expect(inPalette('found from nowhere in particular'), findsOneWidget);

    await teardown(tester, setup.container, setup.db);
  });

  /// The palette used to collapse every message-search failure to an empty
  /// result; it now gains the 403 distinction `channelSearchProvider` already
  /// had, through the shared `searchChannelMessages` helper.
  testWidgets('a 403 on message search explains the denial, not "no matches"', (
    tester,
  ) async {
    final setup = setupPalette(searchForbidden: true);
    await MessageStore(setup.db).upsertChannels(const [
      api.Channel(id: 'ch1', name: 'general', kind: 'text', createdAt: 0),
    ]);
    await pump(tester, setup.container, initial: '/channels/ch1');
    await pressCtrlK(tester);

    await tester.enterText(
      find.byKey(const Key('command-palette-input')),
      'from',
    );
    await tester.pumpAndSettle();

    expect(
      inPalette('You do not have permission to search this channel.'),
      findsOneWidget,
    );
    expect(find.text('No matches.'), findsNothing);

    await teardown(tester, setup.container, setup.db);
  });

  /// The palette's message row used to read the current channel with
  /// `selectedChannelId(context)` from inside its own dialog, which needs a
  /// `GoRouterState` that only resolves inside a route's own builder - the
  /// palette's context is a dialog sitting outside all of them, so selecting
  /// a result threw a `GoError` rather than jumping anywhere.
  testWidgets('selecting a message result closes the palette and jumps to it', (
    tester,
  ) async {
    final setup = setupPalette(
      hits: [
        {
          'id': 'm1',
          'channel_id': 'ch1',
          'author_id': 'other',
          'author_display_name': 'Ren',
          'seq': 1,
          'content': 'a message worth finding',
          'created_at': 0,
          'edited_at': null,
        },
      ],
    );
    await MessageStore(setup.db).upsertChannels(const [
      api.Channel(id: 'ch1', name: 'general', kind: 'text', createdAt: 0),
    ]);
    await pump(tester, setup.container, initial: '/channels/ch1');
    await pressCtrlK(tester);

    await tester.enterText(
      find.byKey(const Key('command-palette-input')),
      'worth finding',
    );
    await tester.pumpAndSettle();

    await tester.tap(inPalette('a message worth finding'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('command-palette-input')), findsNothing);
    expect(
      setup.container.read(messageJumpProvider),
      isNot(isA<MessageJumpIdle>()),
      reason: 'the jump itself has to actually have been asked for',
    );

    await teardown(tester, setup.container, setup.db);
  });
}
