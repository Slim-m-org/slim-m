// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Notes is a button beside the rail's gear, not a Direct messages row
/// (decision 0111's 2026-11-16 section). These drive the real shell the way a
/// person does: the button, its shortcut, and next/previous from Notes.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/dms.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_notes_button.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart' show SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import '../../ui_snapshot_support.dart';

const _notesId = 'c-notes';

final _footer = find.byKey(const Key('rail-footer-padding'));

/// The footer's Notes button, never the notebook the open channel's header draws.
AppIconButton _notesButton(WidgetTester tester) => tester.widget(
  find.ancestor(
    of: find.descendant(of: _footer, matching: find.byIcon(AppIcons.notebook)),
    matching: find.byWidgetPredicate((w) => w is AppIconButton),
  ),
);

String _path(WidgetTester tester) => GoRouter.of(
  tester.element(_footer),
).routerDelegate.currentConfiguration.uri.path;

Future<({ProviderContainer container, SlimmDatabase db})> _pumpShell(
  WidgetTester tester, {
  String route = '/channels/c-general',
  List<Override> overrides = const [],
  bool withNotes = true,
}) async {
  tester.view.physicalSize = const Size(1400, 880);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final fixture = await fixtureContainer(extraOverrides: overrides);
  if (withNotes) {
    final store = await fixture.container.read(storeProvider.future);
    await store.upsertChannels(const [
      api.Channel(
        id: _notesId,
        name: personalSpaceName,
        kind: dmChannelKind,
        createdAt: 0,
        isPersonalSpace: true,
        dmParticipantId: 'user-nick',
      ),
    ]);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: fixtureRouter(route),
      ),
    ),
  );
  await pumpFrames(tester, frames: 20);
  return (container: fixture.container, db: fixture.db);
}

Future<void> _chord(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await pumpFrames(tester, frames: 20);
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('the bar button opens Notes and shows active while it is open', (
    tester,
  ) async {
    final shell = await _pumpShell(tester);
    expect(
      find.text(personalSpaceName),
      findsNothing,
      reason: 'no Notes row in Direct messages',
    );
    expect(_notesButton(tester).active, isFalse);

    await tester.tap(find.bySemanticsLabel('Notes'));
    await pumpFrames(tester, frames: 20);

    expect(_path(tester), '/channels/$_notesId');
    expect(_notesButton(tester).active, isTrue);
    await teardownFixture(tester, shell.container, shell.db);
  });

  testWidgets('Ctrl+Shift+N opens Notes from any channel', (tester) async {
    final shell = await _pumpShell(tester);

    await _chord(tester, LogicalKeyboardKey.keyN, shift: true);

    expect(_path(tester), '/channels/$_notesId');
    await teardownFixture(tester, shell.container, shell.db);
  });

  testWidgets('from Notes, next goes to the first row and previous to the '
      'last, never back onto Notes', (tester) async {
    final shell = await _pumpShell(tester, route: '/channels/$_notesId');

    await _chord(tester, LogicalKeyboardKey.tab);
    final first = _path(tester);
    expect(first, isNot('/channels/$_notesId'));

    await tester.tap(find.bySemanticsLabel('Notes'));
    await pumpFrames(tester, frames: 20);
    await _chord(tester, LogicalKeyboardKey.tab, shift: true);
    final last = _path(tester);
    expect(last, isNot('/channels/$_notesId'));
    expect(last, isNot(first), reason: 'previous wraps to the bottom');
    await teardownFixture(tester, shell.container, shell.db);
  });

  testWidgets('a failed first open says so over the rail', (tester) async {
    final shell = await _pumpShell(
      tester,
      withNotes: false,
      overrides: [
        notesOpenFailureProvider.overrideWith((ref) => 'Could not open Notes.'),
      ],
    );

    expect(find.text('Could not open Notes.'), findsOneWidget);
    await teardownFixture(tester, shell.container, shell.db);
  });
}
