// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The redesigned command palette rows: channel glyphs and visibility, people
/// with avatar, presence and bot badge, the message second line, match
/// highlighting, the current-channel marker, section keyboard paths, the `#`
/// and `@` filters, and the same rows at phone width.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/presence_view.dart';
import 'package:slimm_app/src/widgets/channel_kind_icon.dart';
import 'package:slimm_app/src/widgets/command_palette_compact.dart';
import 'package:slimm_app/src/widgets/command_palette_rows.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'command_palette_harness.dart';

const _input = Key('command-palette-input');

final _kiki = api.UserProfile(
  id: 'other',
  username: 'kiki',
  displayName: 'Kiki',
  createdAt: 0,
  roles: const ['Moderator'],
);
final _modLog = api.UserProfile(
  id: 'modlog',
  username: 'modlog',
  displayName: 'Mod Log',
  createdAt: 0,
  isBot: true,
);

Future<void> _seed(SlimmDatabase db) async {
  final store = MessageStore(db);
  await store.upsertCategory(
    const api.ChannelCategory(
      id: 'cat-mod',
      name: 'Moderation',
      position: 0,
      createdAt: 0,
    ),
  );
  await store.upsertChannels(const [
    api.Channel(
      id: 'ch1',
      name: 'automod-log',
      kind: 'text',
      createdAt: 0,
      categoryId: 'cat-mod',
      restricted: true,
    ),
    api.Channel(id: 'ch2', name: 'modlog', kind: 'text', createdAt: 1),
    api.Channel(
      id: 'ch3',
      name: 'mod-lounge',
      kind: 'voice',
      createdAt: 2,
      restricted: true,
    ),
  ]);
}

Future<void> _open(
  WidgetTester tester,
  ({ProviderContainer container, SlimmDatabase db}) setup, {
  String initial = '/channels',
  Size size = const Size(1400, 900),
  String? type,
}) async {
  await _seed(setup.db);
  await pump(tester, setup.container, initial: initial, size: size);
  await pressCtrlK(tester);
  if (type != null) {
    await tester.enterText(find.byKey(_input), type);
    await tester.pumpAndSettle();
  }
}

({ProviderContainer container, SlimmDatabase db}) _setup({
  List<Map<String, dynamic>> hits = const [],
  List<Override> overrides = const [],
}) => setupPalette(members: [_kiki, _modLog], hits: hits, overrides: overrides);

Finder _boldRun(String text) => find.byWidgetPredicate(
  (w) =>
      w is Text &&
      (w.textSpan?.toPlainText().isNotEmpty ?? false) &&
      _hasBold(w.textSpan!, text),
);

bool _hasBold(InlineSpan span, String text) {
  var found = false;
  span.visitChildren((s) {
    if (s is TextSpan &&
        s.text == text &&
        s.style?.fontWeight == AppWeights.semi) {
      found = true;
    }
    return true;
  });
  return found;
}

void main() {
  test('paletteHighlightSpans bolds only the first match, any case', () {
    final spans = paletteHighlightSpans('Automod mod', 'MOD');
    expect(
      [for (final s in spans) (s as TextSpan).text],
      ['Auto', 'mod', ' mod'],
    );
    expect((spans[1] as TextSpan).style?.fontWeight, AppWeights.semi);
    expect((spans[2] as TextSpan).style, isNull);
    expect(paletteHighlightSpans('abc', '').length, 1);
  });

  testWidgets('channel rows carry the kind glyph, visibility and category', (
    tester,
  ) async {
    final setup = _setup();
    await _open(tester, setup, type: 'mod');

    final glyphs = tester
        .widgetList<ChannelKindIcon>(find.byType(ChannelKindIcon))
        .map((g) => (g.isVoice, g.restricted))
        .toList();
    expect(glyphs, contains((false, true)));
    expect(glyphs, contains((false, false)));
    expect(glyphs, contains((true, true)));
    expect(inPalette('Moderation'), findsOneWidget);
    expect(inPalette('CHANNELS'), findsOneWidget);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('the matched characters are bold', (tester) async {
    final setup = _setup();
    await _open(tester, setup, type: 'mod');

    expect(_boldRun('mod'), findsWidgets);
    await tester.enterText(find.byKey(_input), 'zzz-nothing');
    await tester.pumpAndSettle();
    expect(_boldRun('mod'), findsNothing);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('people rows show avatar, presence, bot badge and reason', (
    tester,
  ) async {
    final setup = _setup(
      overrides: [
        presenceForProvider('other').overrideWith((ref) => AppPresence.online),
      ],
    );
    await _open(tester, setup, type: 'mod');

    final avatars = tester
        .widgetList<AppAvatar>(
          find.descendant(
            of: find.byType(AppMenu),
            matching: find.byType(AppAvatar),
          ),
        )
        .map((a) => a.name)
        .toList();
    expect(avatars, containsAll(['Kiki', 'Mod Log']));
    final kiki = tester.widget<AppAvatar>(
      find.descendant(
        of: find.byType(AppMenu),
        matching: find.byWidgetPredicate(
          (w) => w is AppAvatar && w.name == 'Kiki',
        ),
      ),
    );
    expect(kiki.status, AppPresence.online);
    expect(
      find.descendant(
        of: find.byType(AppMenu),
        matching: find.widgetWithText(AppBadge, 'BOT'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Role: ', findRichText: true), findsOneWidget);
    expect(_boldRun('Mod'), findsWidgets);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('a message hit has a second line with author, channel, day', (
    tester,
  ) async {
    final setup = _setup(
      hits: [
        {
          'id': 'm1',
          'channel_id': 'ch1',
          'author_id': 'other',
          'author_display_name': 'Ren',
          'seq': 1,
          'content': 'weird gap log from mod bot',
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'edited_at': null,
        },
      ],
    );
    await _open(tester, setup, type: 'mod');

    expect(inPalette('MESSAGES'), findsOneWidget);
    expect(inPalette('Ren'), findsOneWidget);
    expect(inPalette(' in #automod-log · Today'), findsOneWidget);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('the open channel says "You\'re here" with an accent bar', (
    tester,
  ) async {
    final setup = _setup();
    await _open(tester, setup, initial: '/channels/ch2', type: 'mod');

    expect(inPalette("You're here"), findsOneWidget);
    expect(find.byKey(const Key('palette-current-bar')), findsOneWidget);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('the highlighted row carries an Enter keycap that follows it', (
    tester,
  ) async {
    final setup = _setup();
    await _open(tester, setup, type: 'mod');

    expect(find.text('↵'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.text('↵'), findsOneWidget);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('Tab jumps to the first person and Enter opens them', (
    tester,
  ) async {
    final setup = _setup();
    await _open(tester, setup, type: 'mod');

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    final context = tester.element(find.text('conversation').first);
    expect(GoRouterState.of(context).uri.path, '/channels/dm-1');

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('Shift+Tab steps back to the previous section', (tester) async {
    final setup = _setup();
    await _open(tester, setup, type: 'mod');

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    final context = tester.element(find.text('conversation').first);
    expect(GoRouterState.of(context).uri.path, startsWith('/channels/ch'));

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('a leading # narrows to channels and @ to people', (
    tester,
  ) async {
    final setup = _setup();
    await _open(tester, setup, type: '#mod');
    expect(inPalette('CHANNELS'), findsOneWidget);
    expect(inPalette('PEOPLE'), findsNothing);
    expect(inPalette('ACTIONS'), findsNothing);

    await tester.enterText(find.byKey(_input), '@mod');
    await tester.pumpAndSettle();
    expect(inPalette('PEOPLE'), findsOneWidget);
    expect(inPalette('CHANNELS'), findsNothing);

    await tester.enterText(find.byKey(_input), '#');
    await tester.pumpAndSettle();
    expect(inPalette('CHANNELS'), findsOneWidget);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('tapping the Esc keycap closes the palette', (tester) async {
    final setup = _setup();
    await _open(tester, setup);

    await tester.tap(find.byKey(const Key('palette-esc')));
    await tester.pumpAndSettle();
    expect(find.byKey(_input), findsNothing);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('the footer names the keys and the # and @ prefixes', (
    tester,
  ) async {
    final setup = _setup();
    await _open(tester, setup);

    expect(find.text('Move'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Next section'), findsOneWidget);
    expect(find.textContaining('channels', findRichText: true), findsWidgets);
    expect(find.textContaining('people', findRichText: true), findsWidgets);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('phone width draws the same rows without keycaps', (
    tester,
  ) async {
    final setup = _setup();
    await _open(
      tester,
      setup,
      initial: '/channels/ch2',
      size: const Size(390, 844),
      type: 'mod',
    );

    final shell = find.byType(CommandPaletteCompactShell);
    expect(
      find.descendant(of: shell, matching: find.byType(ChannelKindIcon)),
      findsWidgets,
    );
    expect(
      find.descendant(of: shell, matching: find.byType(AppAvatar)),
      findsWidgets,
    );
    expect(
      find.descendant(of: shell, matching: find.text("You're here")),
      findsOneWidget,
    );
    expect(find.byType(AppKbd), findsNothing);
    expect(tester.takeException(), isNull);

    await teardown(tester, setup.container, setup.db);
  });
}
