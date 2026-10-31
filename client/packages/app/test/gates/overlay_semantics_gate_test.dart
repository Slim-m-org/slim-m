// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Everything painted on an overlay must also exist in its semantics tree:
/// `support/semantics_audit.dart`'s check, run over every registered overlay
/// in both shipped shapes. Its doc has the #1126 story this exists for.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

import '../support/overlay_registry.dart';
import '../support/semantics_audit.dart';
import '../ui_snapshot_support.dart';

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in overlayViewports.entries) {
    for (final overlay in overlays.entries) {
      testWidgets(
        '${overlay.key} at ${viewport.key} is fully reachable by semantics',
        (tester) async {
          tester.view.physicalSize = viewport.value;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          final handle = tester.ensureSemantics();

          final fixture = await fixtureContainer();
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: fixture.container,
              child: MaterialApp.router(
                debugShowCheckedModeBanner: false,
                theme: buildTheme(Brightness.dark, AppTokens.dark),
                routerConfig: overlayRouter(overlay.value),
              ),
            ),
          );
          await tester.pump();
          await tester.tap(find.text(overlayOpenerLabel));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pump(const Duration(milliseconds: 350));

          final problems = semanticsProblems(
            tester,
            ignoreTexts: const {overlayOpenerLabel},
          );
          expect(
            problems,
            isEmpty,
            reason:
                '${overlay.key} at ${viewport.key} paints widgets a screen '
                'reader cannot reach:\n  ${problems.join('\n  ')}',
          );
          expect(tester.takeException(), isNull);

          handle.dispose();
          await teardownFixture(tester, fixture.container, fixture.db);
        },
      );
    }
  }
}
