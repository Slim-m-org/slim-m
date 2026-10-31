// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every admin setup step on a phone and a desktop window, light and dark,
/// with a small machine so the recommendations show. The overflow assertion
/// runs everywhere; the PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'dart:ui' show Size;

import 'package:flutter/material.dart' show Brightness;
import 'package:flutter_test/flutter_test.dart';

import 'features/admin_setup/admin_setup_harness.dart';
import 'ui_snapshot_support.dart';

const _viewports = {'phone': Size(390, 844), 'desktop': Size(1280, 800)};

const _steps = [
  'server',
  'profile',
  'joining',
  'uploads',
  'retention',
  'voice',
];

void main() {
  setUpAll(loadRealFonts);

  for (final MapEntry(key: viewport, value: size) in _viewports.entries) {
    for (final brightness in Brightness.values) {
      testWidgets('admin setup, $viewport, ${brightness.name}', (tester) async {
        await pumpAdminSetup(
          tester,
          size: size,
          brightness: brightness,
          setup: SetupFacts(
            cores: 2,
            diskFree: 6 * gib,
            diskTotal: 100 * gib,
            voice: true,
          ),
        );
        for (var i = 0; i < _steps.length; i++) {
          await writeSnapshot(
            tester,
            'admin_setup_${_steps[i]}_${viewport}_${brightness.name}',
          );
          if (i < _steps.length - 1) {
            await tester.tap(find.text('Continue'));
            await settleSetup(tester);
          }
        }
      });
    }
  }
}
