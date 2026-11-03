// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The idle voice channel (design 13, decision 0066): join bar, last call's
/// lanes and moments, and earlier calls, at desktop and phone width in both
/// themes. PNGs are written only under SLIMM_UI_SNAPSHOTS=1; otherwise this
/// asserts the pane lays out without overflow.
library;

import 'package:flutter/painting.dart' show Size;
import 'package:flutter_test/flutter_test.dart';

import '../support/voice_idle_scene.dart';
import '../ui_snapshot_support.dart';

void main() {
  setUpAll(loadRealFonts);

  const sizes = {'desktop': Size(1100, 1000), 'phone': Size(390, 900)};
  for (final theme in const ['dark', 'light']) {
    for (final entry in sizes.entries) {
      testWidgets('idle voice channel at ${entry.key} ($theme)', (
        tester,
      ) async {
        await pumpIdle(tester, size: entry.value, dark: theme == 'dark');
        await tester.pumpAndSettle();
        expect(find.textContaining("Nobody's here"), findsOneWidget);
        expect(find.text('Last call'), findsOneWidget);
        await writeSnapshot(tester, 'voice-idle-${entry.key}-$theme');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
