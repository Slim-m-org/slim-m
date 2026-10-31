// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The what's-new sheet rendered open, at a phone and a desktop width in both
/// themes. The overflow check runs everywhere; PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1, like `ui_snapshot_test.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/whats_new/whats_new_content.dart';
import 'package:slimm_app/src/widgets/whats_new_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

import '../support/mid_flight_capture.dart';
import '../ui_snapshot_support.dart';

void main() {
  setUpAll(loadRealFonts);

  const viewports = {'390': Size(390, 844), '1280': Size(1280, 800)};
  const themes = {
    'light': (Brightness.light, AppTokens.light),
    'dark': (Brightness.dark, AppTokens.dark),
  };

  final openers = <String, Future<void> Function(BuildContext)>{
    'whats-new': (context) => showWhatsNewSheet(
      context,
      whatsNewEntries.sublist(whatsNewEntries.length - 3),
    ),
    'release-notes': showReleaseNotesSheet,
  };

  for (final o in openers.entries) {
    for (final v in viewports.entries) {
      for (final t in themes.entries) {
        final name = '${o.key}-${v.key}-${t.key}';
        testWidgets('$name fits', (tester) async {
          tester.view.physicalSize = v.value;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          await tester.pumpWidget(
            RepaintBoundary(
              key: snapshotBoundary,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: buildTheme(t.value.$1, t.value.$2),
                home: Builder(
                  builder: (context) => Scaffold(
                    body: Center(
                      child: TextButton(
                        onPressed: () => o.value(context),
                        child: const Text('open'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('open'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          await expectSettled(tester, name);
          await writeSnapshot(tester, name);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
