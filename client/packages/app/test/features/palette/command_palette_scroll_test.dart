// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Arrow keys and Tab walk a result list taller than its scroll view, so the
/// highlighted row (the one Enter opens) has to be scrolled into view.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/palette/widgets/command_palette_rows.dart';
import 'package:slimm_data/data.dart';

import '../../command_palette_harness.dart';

final _viewport = find.byWidgetPredicate((w) => w is SingleChildScrollView);
final _highlighted = find.byWidgetPredicate(
  (w) => w is PaletteRowShell && w.highlighted,
);

Future<({ProviderContainer container, SlimmDatabase db})> _open(
  WidgetTester tester,
  Size size,
) async {
  final setup = setupPalette(
    members: [for (var i = 0; i < 8; i++) profile('m$i', 'Member $i')],
  );
  await MessageStore(setup.db).upsertChannels([
    for (var i = 0; i < 12; i++)
      api.Channel(id: 'ch$i', name: 'room-$i', kind: 'text', createdAt: i),
  ]);
  await pump(tester, setup.container, size: size);
  await pressCtrlK(tester);
  return setup;
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
  await tester.pump();
}

void _expectInside(WidgetTester tester, Finder target, String what) {
  final view = tester.getRect(_viewport);
  final rect = tester.getRect(target);
  expect(
    rect.top >= view.top - 0.5 && rect.bottom <= view.bottom + 0.5,
    isTrue,
    reason: '$what $rect is outside the results viewport $view',
  );
}

void main() {
  for (final (name, size) in [
    ('desktop', const Size(1400, 900)),
    ('compact', const Size(390, 600)),
  ]) {
    testWidgets('$name: the highlighted row stays in view as arrows walk it', (
      tester,
    ) async {
      final setup = await _open(tester, size);
      await _press(tester, LogicalKeyboardKey.arrowUp);
      _expectInside(tester, _highlighted, 'the wrapped-to last row');
      for (var i = 0; i < 40; i++) {
        await _press(tester, LogicalKeyboardKey.arrowDown);
        _expectInside(tester, _highlighted, 'step $i');
      }

      await teardown(tester, setup.container, setup.db);
    });
  }

  testWidgets('wrapping to the top shows the first section header too', (
    tester,
  ) async {
    final setup = await _open(tester, const Size(1400, 900));

    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(
      tester.getRect(_highlighted).bottom,
      greaterThan(tester.getRect(_viewport).bottom - 1),
      reason: 'the last row sits at the bottom of the scrolled list',
    );
    await _press(tester, LogicalKeyboardKey.arrowDown);

    _expectInside(tester, _highlighted, 'the first row');
    _expectInside(tester, inPalette('CHANNELS'), 'its section header');

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('Tab into a lower section brings its header and row into view', (
    tester,
  ) async {
    final setup = await _open(tester, const Size(1400, 900));

    await _press(tester, LogicalKeyboardKey.tab);
    await _press(tester, LogicalKeyboardKey.tab);

    _expectInside(tester, _highlighted, 'the highlighted row');
    _expectInside(tester, inPalette('ACTIONS'), 'the section header');

    await teardown(tester, setup.container, setup.db);
  });
}
