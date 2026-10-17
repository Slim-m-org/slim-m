// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The voice call screen with a bot on it, phone and desktop, both themes,
/// with and without the canvas. PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1; otherwise this asserts every shape lays out without
/// overflow.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'features/settings/home_shell_harness.dart' show teardown;
import 'support/call_screen_phone_harness.dart';
import 'ui_snapshot_support.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await loadRealFonts();
  });

  const sizes = {'phone': Size(390, 844), 'desktop': Size(1280, 800)};
  for (final entry in sizes.entries) {
    for (final dark in const [true, false]) {
      for (final canvas in const [false, true]) {
        final name =
            'call-${entry.key}-${canvas ? 'canvas' : 'call'}-'
            '${dark ? 'dark' : 'light'}';
        testWidgets('call screen $name', (tester) async {
          final s = await pumpCallScreen(
            tester,
            entry.value,
            canvas: canvas,
            brightness: dark ? Brightness.dark : Brightness.light,
          );

          await writeSnapshot(tester, name);
          expect(tester.takeException(), isNull);
          await teardown(tester, s.container, s.db);
        });
      }
    }
  }
}
