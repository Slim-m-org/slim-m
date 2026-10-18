// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A debug log entry with a stack trace expands under reduce motion without
/// animating, and animates for a viewer who asked for nothing.
///
/// Measured on the tile's own rendered height, not `hasRunningAnimations`:
/// tapping it also starts the row's own `InkWell` ripple, a second, genuinely
/// unrelated animation that is still ticking well past both cases' own
/// transition duration, which would make that a false positive either way.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/diagnostics/debug_log.dart';
import 'package:slimm_app/src/features/settings/screens/debug_log_screen.dart';
import 'package:slimm_app/src/features/settings/widgets/debug_log_entry.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _harness({required bool reduceMotion}) => ProviderScope(
  overrides: [
    debugLogProvider.overrideWith(
      (ref) => DebugLog()
        ..record(
          'flutter',
          'a caught exception',
          detail: 'the full stack trace',
        ),
    ),
  ],
  child: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: const DebugLogScreen(),
    ),
  ),
);

void main() {
  testWidgets('expanding an entry is instant under reduce motion', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(reduceMotion: true));
    await tester.tap(find.byType(DebugLogEntry));
    await tester.pump();

    final justAfterTap = tester.getSize(find.byType(DebugLogEntry)).height;
    await tester.pumpAndSettle();
    final settled = tester.getSize(find.byType(DebugLogEntry)).height;

    expect(
      justAfterTap,
      settled,
      reason: 'nothing may keep growing once the viewer has asked it not to',
    );
  });

  testWidgets('expanding an entry still animates by default', (tester) async {
    await tester.pumpWidget(_harness(reduceMotion: false));
    await tester.tap(find.byType(DebugLogEntry));
    await tester.pump();

    final justAfterTap = tester.getSize(find.byType(DebugLogEntry)).height;
    await tester.pumpAndSettle();
    final settled = tester.getSize(find.byType(DebugLogEntry)).height;

    expect(
      justAfterTap,
      lessThan(settled),
      reason:
          "a viewer who asked for nothing keeps the tile's own stock "
          "expansion rather than this app's override collapsing it",
    );
  });
}
