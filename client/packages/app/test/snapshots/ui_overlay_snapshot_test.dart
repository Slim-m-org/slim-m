// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Renders overlays open, not resting screens: a sheet, dialog or popover
/// shows nothing on a screenshot of what is underneath it, so each of these
/// is driven open through its real `show*` entry point and rendered while
/// mounted.
///
/// Two viewports per surface (desktop, where `showAppSheet` renders a
/// centred dialog, and a phone, where it collapses to a bottom sheet), one
/// theme (dark - light is already covered broadly by `ui_snapshot_test.dart`
/// and the golden matrix). The overflow assertion runs everywhere including
/// CI; the PNGs are written only under SLIMM_UI_SNAPSHOTS=1, matching
/// `ui_snapshot_test.dart`'s own split.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

import '../support/mid_flight_capture.dart';
import '../support/overlay_registry.dart';
import '../ui_snapshot_support.dart';

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in overlayViewports.entries) {
    for (final overlay in overlays.entries) {
      testWidgets('${overlay.key} at ${viewport.key} fits its viewport', (
        tester,
      ) async {
        tester.view.physicalSize = viewport.value;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fixture = await fixtureContainer();
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: fixture.container,
            child: RepaintBoundary(
              key: snapshotBoundary,
              child: MaterialApp.router(
                debugShowCheckedModeBanner: false,
                theme: buildTheme(Brightness.dark, AppTokens.dark),
                routerConfig: overlayRouter(overlay.value),
              ),
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.text(overlayOpenerLabel));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        // A fetch landing on the frame above mounts its fade at t=0; one more timed frame lets it land - see renderSurface's own doc.
        await tester.pump(const Duration(milliseconds: 350));

        final snapshotName = '${overlay.key}-${viewport.key}';
        await expectSettled(tester, snapshotName);
        await writeSnapshot(tester, snapshotName);

        expect(tester.takeException(), isNull);

        await teardownFixture(tester, fixture.container, fixture.db);
      });
    }
  }
}
