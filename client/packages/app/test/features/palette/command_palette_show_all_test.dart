// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A section with more matches than the palette lists says how many there are
/// and ends in a row that lists them all, keeping the palette open.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/palette/widgets/command_palette_items.dart';
import 'package:slimm_app/src/features/palette/widgets/palette_person_body.dart';
import 'package:slimm_data/data.dart';

import '../../command_palette_harness.dart';
import '../../support/async_wait.dart';

String _name(int i) => 'scale-${i.toString().padLeft(2, '0')}';

final _personRows = find.byWidgetPredicate((w) => w is PalettePersonBody);

void main() {
  testWidgets('a long channel list shows its count and a way to all of it', (
    tester,
  ) async {
    final setup = setupPalette();
    await MessageStore(setup.db).upsertChannels([
      for (var i = 0; i < 12; i++)
        api.Channel(id: 'c$i', name: _name(i), kind: 'text', createdAt: i),
    ]);
    await pump(tester, setup.container);
    await pressCtrlK(tester);
    await tester.enterText(
      find.byKey(const Key('command-palette-input')),
      'scale',
    );
    await pumpFrames(tester);

    expect(inPalette('12'), findsOneWidget);
    expect(inPalette(_name(paletteResultLimit)), findsNothing);
    await tester.tap(inPalette('Show all 12 channels'));
    await pumpFrames(tester);

    expect(find.byKey(const Key('command-palette-input')), findsOneWidget);
    expect(find.text('#scale'), findsOneWidget);
    await tester.ensureVisible(inPalette(_name(11)));
    expect(inPalette(_name(11)), findsOneWidget);
    expect(inPalette('Show all 12 channels'), findsNothing);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('2000 members build only a screenful of people rows', (
    tester,
  ) async {
    final setup = setupPalette(
      members: [for (var i = 0; i < 2000; i++) profile('p$i', 'Person $i')],
    );
    await pump(tester, setup.container);
    await pressCtrlK(tester);
    await pumpFrames(tester);

    expect(_personRows.evaluate().length, lessThan(30));
    await tester.tap(inPalette('Show all 2000 people'));
    await pumpFrames(tester);

    expect(find.text('@'), findsOneWidget);
    expect(
      _personRows.evaluate().length,
      lessThanOrEqualTo(palettePeopleScopeLimit),
    );

    await teardown(tester, setup.container, setup.db);
  });

  test('a section that fits gets no show-all row', () {
    final items = [
      for (var i = 0; i < paletteResultLimit; i++)
        PaletteResultItem(label: '$i', onSelect: (_, _) async {}),
    ];
    expect(capWithShowAll(items, noun: 'channels', showAll: () {}), items);
  });
}
