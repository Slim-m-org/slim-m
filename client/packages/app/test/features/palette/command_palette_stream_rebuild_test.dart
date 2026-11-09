// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A keystroke in the palette rebuilds its channel list once: the palette
/// holds its drift streams rather than handing `StreamBuilder` new ones, which
/// drift answers by replaying a snapshot and rebuilding the list again.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../command_palette_harness.dart';

void main() {
  testWidgets('typing rebuilds the palette channel list once per keystroke', (
    tester,
  ) async {
    final setup = setupPalette();
    await MessageStore(setup.db).upsertChannels(const [
      api.Channel(id: 'ch1', name: 'general', kind: 'text', createdAt: 0),
    ]);
    await pump(tester, setup.container);
    await pressCtrlK(tester);

    final rebuilt = <String>[];
    debugOnRebuildDirtyWidget = (element, _) {
      final inPalette = element.findAncestorWidgetOfExactType<AppMenu>();
      if (inPalette != null && element.widget is StreamBuilder<List<Channel>>) {
        rebuilt.add('channel list');
      }
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    await tester.enterText(find.byKey(const Key('command-palette-input')), 'g');
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }

    expect(rebuilt, ['channel list']);

    debugOnRebuildDirtyWidget = null;
    await teardown(tester, setup.container, setup.db);
  });
}
