// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The palette under an on-screen keyboard: every result stays reachable
/// above it, and the keyboard can be put away without leaving the search.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/palette/widgets/command_palette_rows.dart';
import 'package:slimm_data/data.dart';

import '../../command_palette_harness.dart';

const _phone = Size(390, 844);
const _keyboard = 336.0;
const _keyboardTop = 844 - _keyboard;

final _input = find.byKey(const Key('command-palette-input'));
final _viewport = find.byWidgetPredicate((w) => w is SingleChildScrollView);
final _rows = find.byWidgetPredicate((w) => w is PaletteRowShell);

Future<({ProviderContainer container, SlimmDatabase db})> _open(
  WidgetTester tester, {
  double keyboard = _keyboard,
}) async {
  final setup = setupPalette(
    members: [for (var i = 0; i < 8; i++) profile('m$i', 'Member $i')],
  );
  await MessageStore(setup.db).upsertChannels([
    for (var i = 0; i < 12; i++)
      api.Channel(id: 'ch$i', name: 'room-$i', kind: 'text', createdAt: i),
  ]);
  await pump(tester, setup.container, size: _phone);
  await pressCtrlK(tester);
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  await tester.pump();
  await tester.pump();
  return setup;
}

/// Whether the field still holds the keyboard open.
bool _keyboardUp(WidgetTester tester) => tester.testTextInput.isVisible;

/// Long enough for the search pause and the palette's own exit to finish.
Future<void> _wait(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('the results end above the keyboard, and the last one scrolls '
      'into view', (tester) async {
    final setup = await _open(tester);

    expect(
      tester.getRect(_viewport).bottom,
      lessThanOrEqualTo(_keyboardTop + 0.5),
      reason: 'a list running under the keyboard hides rows nothing reaches',
    );
    expect(
      tester.getRect(_rows.last).bottom,
      greaterThan(_keyboardTop),
      reason: 'the fixture has to overflow for this to mean anything',
    );
    await tester.drag(_viewport, const Offset(0, -2000));
    await tester.pump();
    expect(
      tester.getRect(_rows.last).bottom,
      lessThanOrEqualTo(_keyboardTop + 0.5),
    );

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('the keyboard\'s own enter key puts the keyboard away and '
      'opens nothing', (tester) async {
    final setup = await _open(tester);
    await tester.enterText(_input, 'room');
    await tester.pump();
    expect(_keyboardUp(tester), isTrue);

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _wait(tester);

    expect(_input, findsOneWidget, reason: 'the search stays open');
    expect(inCompactPalette('room-0'), findsOneWidget);
    expect(_keyboardUp(tester), isFalse);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('with no keyboard on screen, enter still opens the first '
      'result', (tester) async {
    final setup = await _open(tester, keyboard: 0);
    await tester.enterText(_input, 'room-3');
    await tester.pump();

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _wait(tester);

    expect(_input, findsNothing, reason: 'a hardware Enter runs the row');

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('dragging the results puts the keyboard away', (tester) async {
    final setup = await _open(tester);
    expect(_keyboardUp(tester), isTrue);

    await tester.drag(_viewport, const Offset(0, -120));
    await tester.pump();

    expect(_keyboardUp(tester), isFalse);
    expect(_input, findsOneWidget);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('a list too short to scroll still puts the keyboard away on a '
      'drag', (tester) async {
    final setup = await _open(tester);
    await tester.enterText(_input, 'room-3');
    await _wait(tester);
    expect(tester.getRect(_rows.last).bottom, lessThan(_keyboardTop));
    expect(_keyboardUp(tester), isTrue);

    await tester.drag(_viewport, const Offset(0, -120));
    await tester.pump();

    expect(_keyboardUp(tester), isFalse);
    expect(_input, findsOneWidget);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('the field asks the keyboard for a search key', (tester) async {
    final setup = await _open(tester);

    expect(
      tester.testTextInput.setClientArgs?['inputAction'],
      'TextInputAction.search',
    );

    await teardown(tester, setup.container, setup.db);
  });
}
