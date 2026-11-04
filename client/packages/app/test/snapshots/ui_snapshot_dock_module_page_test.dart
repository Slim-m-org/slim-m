// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module page for a game with no settings, a levels module with settings
/// and display slots, and a module with host access, at phone and desktop
/// width, folded and with the roles and Details open. PNGs only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/dock_module_page_fixtures.dart';
import '../ui_snapshot_support.dart';

const _widths = {'phone': Size(390, 2600), 'desktop': Size(1000, 2200)};

void main() {
  setUpAll(loadRealFonts);

  for (final module in dockPageModules.keys) {
    for (final MapEntry(key: width, value: size) in _widths.entries) {
      testWidgets('module page $module at $width lays out', (tester) async {
        await pumpDockModulePage(tester, module, size: size);
        expect(tester.takeException(), isNull);
        await writeSnapshot(tester, 'dock-module-$module-$width');
        for (final fold in ['roles', 'details']) {
          final toggle = find.byKey(Key('dock-$fold-toggle'));
          await tester.ensureVisible(toggle);
          await tester.tap(toggle);
          for (var i = 0; i < 3; i++) {
            await tester.pump(const Duration(milliseconds: 350));
          }
          expect(tester.takeException(), isNull);
        }
        expect(find.text('Limits per run'), findsOneWidget);
        await writeSnapshot(tester, 'dock-module-$module-$width-open');
      });
    }
  }
}
