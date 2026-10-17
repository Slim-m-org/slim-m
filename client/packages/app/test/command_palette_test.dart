// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the command palette itself: opening it (by key and by tap),
/// grouped results, keyboard navigation, the channel/member/settings
/// destinations it opens, and that closing it restores focus.
///
/// The palette's own message search is a separate concern with its own
/// fakes (a controllable set of hits and a 403 case) and lives in
/// `command_palette_search_test.dart`; shared fixtures for both are in
/// `command_palette_harness.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/features/palette/widgets/command_palette.dart';
import 'package:slimm_app/src/features/palette/widgets/command_palette_compact.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'command_palette_harness.dart';

void main() {
  testWidgets('Ctrl+K opens the command palette', (tester) async {
    final setup = setupPalette();
    await MessageStore(setup.db).upsertChannels(const [
      api.Channel(id: 'ch1', name: 'general', kind: 'text', createdAt: 0),
    ]);
    await pump(tester, setup.container);

    expect(find.byKey(const Key('command-palette-input')), findsNothing);
    await pressCtrlK(tester);
    expect(find.byKey(const Key('command-palette-input')), findsOneWidget);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('tapping the rail search field opens the command palette', (
    tester,
  ) async {
    final setup = setupPalette();
    await pump(tester, setup.container);

    await tester.tap(find.byKey(const Key('rail-search-trigger')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('command-palette-input')), findsOneWidget);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('results are grouped, and typing narrows them', (tester) async {
    final setup = setupPalette();
    await MessageStore(setup.db).upsertChannels(const [
      api.Channel(id: 'ch1', name: 'general', kind: 'text', createdAt: 0),
    ]);
    await pump(tester, setup.container);
    await pressCtrlK(tester);

    // Scoped: the rail behind it has its own "CHANNELS" header now (item 55).
    expect(inPalette('CHANNELS'), findsOneWidget);
    expect(inPalette('PEOPLE'), findsOneWidget);
    expect(inPalette('ACTIONS'), findsOneWidget);
    expect(inPalette('general'), findsOneWidget);
    expect(inPalette('Ren'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('command-palette-input')),
      'zzz-no-match',
    );
    await tester.pumpAndSettle();
    expect(inPalette('general'), findsNothing);
    expect(inPalette('Ren'), findsNothing);
    expect(find.text('No matches.'), findsOneWidget);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('typing crossfades the results rather than hard-cutting them', (
    tester,
  ) async {
    final setup = setupPalette();
    await MessageStore(setup.db).upsertChannels(const [
      api.Channel(id: 'ch1', name: 'general', kind: 'text', createdAt: 0),
    ]);
    await pump(tester, setup.container);
    await pressCtrlK(tester);

    await tester.enterText(
      find.byKey(const Key('command-palette-input')),
      'zzz-no-match',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    // Mid-crossfade: the old rows and the new empty state coexist.
    expect(inPalette('general'), findsOneWidget);
    expect(find.text('No matches.'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(inPalette('general'), findsNothing);
    expect(find.text('No matches.'), findsOneWidget);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('selecting a channel result navigates to it and closes', (
    tester,
  ) async {
    final setup = setupPalette();
    await MessageStore(setup.db).upsertChannels(const [
      api.Channel(id: 'ch1', name: 'general', kind: 'text', createdAt: 0),
    ]);
    await pump(tester, setup.container);
    await pressCtrlK(tester);

    await tester.tap(inPalette('general'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('command-palette-input')), findsNothing);
    final context = tester.element(find.text('conversation').first);
    expect(GoRouterState.of(context).uri.path, '/channels/ch1');

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('arrow keys move the highlight and Enter runs it', (
    tester,
  ) async {
    final setup = setupPalette();
    await MessageStore(setup.db).upsertChannels(const [
      api.Channel(id: 'ch1', name: 'general', kind: 'text', createdAt: 0),
      api.Channel(id: 'ch2', name: 'random', kind: 'text', createdAt: 1),
    ]);
    await pump(tester, setup.container);
    await pressCtrlK(tester);

    // Both channels are in the same, first group; one arrow-down from the
    // default top highlight ("general") moves it onto "random".
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    // flutter_test's own docs: a raw Enter key never reaches `onSubmitted`,
    // since on a real device the engine, not Flutter, turns it into one.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('command-palette-input')), findsNothing);
    final context = tester.element(find.text('conversation').first);
    expect(GoRouterState.of(context).uri.path, '/channels/ch2');

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('Escape closes the palette', (tester) async {
    final setup = setupPalette();
    await pump(tester, setup.container);
    await pressCtrlK(tester);
    expect(find.byKey(const Key('command-palette-input')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('command-palette-input')), findsNothing);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('selecting a member opens a DM and closes the palette', (
    tester,
  ) async {
    final setup = setupPalette();
    await pump(tester, setup.container);
    await pressCtrlK(tester);

    await tester.tap(inPalette('Ren'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('command-palette-input')), findsNothing);
    final context = tester.element(find.text('conversation').first);
    expect(GoRouterState.of(context).uri.path, '/channels/dm-1');

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets(
    'selecting "Open personal settings" navigates to personal settings',
    (tester) async {
      final setup = setupPalette();
      await pump(tester, setup.container);
      await pressCtrlK(tester);

      await tester.tap(find.text('Open personal settings'));
      await tester.pumpAndSettle();

      expect(find.text('personal-settings-screen'), findsOneWidget);

      await teardown(tester, setup.container, setup.db);
    },
  );

  testWidgets(
    '"Open Space settings" is offered, and reaches it, only for a caller '
    'who can manage the Space',
    (tester) async {
      final setup = setupPalette(permissions: Perm.manageMessages);
      await pump(tester, setup.container);
      await pressCtrlK(tester);

      await tester.tap(find.text('Open Space settings'));
      await tester.pumpAndSettle();

      expect(find.text('space-settings-screen'), findsOneWidget);

      await teardown(tester, setup.container, setup.db);
    },
  );

  testWidgets('"Open Space settings" is absent for a caller with none of the '
      'gating bits', (tester) async {
    final setup = setupPalette();
    await pump(tester, setup.container);
    await pressCtrlK(tester);

    expect(find.text('Open Space settings'), findsNothing);

    await teardown(tester, setup.container, setup.db);
  });

  /// The personal-space-in-search round trip lives in its own file,
  /// `personal_space_search_test.dart`: adding it here crossed the file's
  /// 500-line hard budget.
  testWidgets('closing the palette restores focus to what held it before', (
    tester,
  ) async {
    final setup = setupPalette();
    final fieldFocus = FocusNode();
    addTearDown(fieldFocus.dispose);

    // openCommandPalette reads the current route, so even this isolated
    // harness needs a real GoRouter ancestor rather than a bare MaterialApp.
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: Column(
              children: [
                TextField(focusNode: fieldFocus, autofocus: true),
                ElevatedButton(
                  onPressed: () => openCommandPalette(context),
                  child: const Text('open'),
                ),
              ],
            ),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: setup.container,
        child: MaterialApp.router(
          theme: buildTheme(Brightness.light, AppTokens.light),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(fieldFocus.hasFocus, isTrue);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(fieldFocus.hasFocus, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(fieldFocus.hasFocus, isTrue);

    await teardown(tester, setup.container, setup.db);
  });

  /// overlays.md: the palette's fixed 480-wide `AppMenu` used to overflow a
  /// 390-wide phone symmetrically by 45px a side, cropping the leading edge
  /// of every row - the one overlay in the set that never adopted
  /// `showAppSheet`'s own phone/desktop split. It now drops the floating
  /// card at compact widths entirely; the width-driven shell split itself
  /// lives in `command_palette_responsive_test.dart`.
  testWidgets('the palette never grows wider than the phone viewport', (
    tester,
  ) async {
    final setup = setupPalette();
    await pump(tester, setup.container, size: const Size(390, 844));

    await pressCtrlK(tester);

    expect(
      find.byType(AppMenu),
      findsNothing,
      reason: 'compact drops the floating card for the full-bleed shell',
    );
    expect(find.byType(CommandPaletteCompactShell), findsOneWidget);

    await teardown(tester, setup.container, setup.db);
  });
}
