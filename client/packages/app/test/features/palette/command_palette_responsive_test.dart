// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the command palette's width-driven shell: a full-bleed pull-down
/// with an on-screen Cancel below `kCompactWidth`, the floating card with its
/// keyboard-hint footer above it, and the same results and ranking either way.
///
/// Shared fixtures live in `command_palette_harness.dart`; the rest of the
/// palette's own behaviour (opening, navigating, message search) lives in
/// `command_palette_test.dart` and `command_palette_search_test.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/palette/widgets/command_palette_compact.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../command_palette_harness.dart';

const _compact = Size(390, 844);
const _wide = Size(1400, 900);

void main() {
  testWidgets(
    'below kCompactWidth the palette is a full-bleed shell with a Cancel '
    'button and no keyboard-hint footer',
    (tester) async {
      final setup = setupPalette();
      await pump(tester, setup.container, size: _compact);
      await pressCtrlK(tester);

      expect(find.byType(CommandPaletteCompactShell), findsOneWidget);
      expect(find.byType(AppMenu), findsNothing);
      expect(find.byKey(const Key('command-palette-cancel')), findsOneWidget);
      expect(
        find.byType(AppKbd),
        findsNothing,
        reason: 'a touch layout has no arrow/Enter keys to explain',
      );

      await teardown(tester, setup.container, setup.db);
    },
  );

  testWidgets(
    'at or above kCompactWidth the palette is the floating card with the '
    'keyboard-hint footer and no Cancel button',
    (tester) async {
      final setup = setupPalette();
      await pump(tester, setup.container, size: _wide);
      await pressCtrlK(tester);

      expect(find.byType(AppMenu), findsOneWidget);
      expect(find.byType(CommandPaletteCompactShell), findsNothing);
      expect(
        find.byType(AppKbd),
        findsWidgets,
        reason: 'a pointer layout explains the arrow/Enter shortcuts',
      );
      expect(find.byKey(const Key('command-palette-cancel')), findsNothing);

      await teardown(tester, setup.container, setup.db);
    },
  );

  testWidgets('tapping Cancel closes the compact palette', (tester) async {
    final setup = setupPalette();
    await pump(tester, setup.container, size: _compact);
    await pressCtrlK(tester);
    expect(find.byKey(const Key('command-palette-input')), findsOneWidget);

    await tester.tap(find.byKey(const Key('command-palette-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('command-palette-input')), findsNothing);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets(
    'results, grouping and typed narrowing are identical at compact and '
    'wide widths',
    (tester) async {
      final compactSetup = setupPalette();
      await MessageStore(compactSetup.db).upsertChannels(const [
        api.Channel(id: 'ch1', name: 'general', kind: 'text', createdAt: 0),
      ]);
      await pump(tester, compactSetup.container, size: _compact);
      await pressCtrlK(tester);

      expect(inCompactPalette('CHANNELS'), findsOneWidget);
      expect(inCompactPalette('PEOPLE'), findsOneWidget);
      expect(inCompactPalette('general'), findsOneWidget);
      expect(inCompactPalette('Ren'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('command-palette-input')),
        'zzz-no-match',
      );
      await tester.pumpAndSettle();
      expect(inCompactPalette('general'), findsNothing);
      expect(find.text('No matches.'), findsOneWidget);

      await teardown(tester, compactSetup.container, compactSetup.db);

      final wideSetup = setupPalette();
      await MessageStore(wideSetup.db).upsertChannels(const [
        api.Channel(id: 'ch1', name: 'general', kind: 'text', createdAt: 0),
      ]);
      await pump(tester, wideSetup.container, size: _wide);
      await pressCtrlK(tester);

      expect(inPalette('CHANNELS'), findsOneWidget);
      expect(inPalette('PEOPLE'), findsOneWidget);
      expect(inPalette('general'), findsOneWidget);
      expect(inPalette('Ren'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('command-palette-input')),
        'zzz-no-match',
      );
      await tester.pumpAndSettle();
      expect(inPalette('general'), findsNothing);
      expect(find.text('No matches.'), findsOneWidget);

      await teardown(tester, wideSetup.container, wideSetup.db);
    },
  );

  testWidgets(
    'tapping the rail search field opens the palette at a compact width too',
    (tester) async {
      final setup = setupPalette();
      await pump(tester, setup.container, size: _compact);

      await tester.tap(find.byKey(const Key('rail-search-trigger')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('command-palette-input')), findsOneWidget);

      await teardown(tester, setup.container, setup.db);
    },
  );

  testWidgets(
    'resizing past kCompactWidth while the palette is open swaps the shell '
    'live, without closing it',
    (tester) async {
      final setup = setupPalette();
      await pump(tester, setup.container, size: _wide);
      await pressCtrlK(tester);
      expect(find.byType(AppMenu), findsOneWidget);

      tester.view.physicalSize = _compact;
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('command-palette-input')), findsOneWidget);
      expect(find.byType(AppMenu), findsNothing);
      expect(find.byType(CommandPaletteCompactShell), findsOneWidget);

      await teardown(tester, setup.container, setup.db);
    },
  );
}
