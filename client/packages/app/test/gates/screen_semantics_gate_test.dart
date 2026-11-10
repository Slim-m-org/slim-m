// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Everything painted on a routed screen must also exist in its semantics
/// tree: `support/semantics_audit.dart`'s check, run over every screen the
/// snapshot matrix pictures, at a phone and a desktop width in the dark
/// theme. Its doc has the #1126 story this exists for; the overlay gate
/// covers sheets and dialogs, this covers the screens beneath them.
///
/// Mounted the way `renderSurface` mounts a snapshot, minus the picture:
/// the same fixture container, router, chrome builder and settling pumps, so
/// the tree under review is the one the app would really build.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_design_system/design_system.dart';

import '../support/semantics_audit.dart';
import '../support/surface_registry.dart';
import '../ui_snapshot_support.dart';

const _shapes = ['phone-portrait', 'desktop'];

void main() {
  setUpAll(loadRealFonts);

  for (final surface in snapshotSurfaces.entries) {
    for (final viewport in _shapes) {
      testWidgets(
        '${surface.key} at $viewport is fully reachable by semantics',
        (tester) async {
          tester.view.physicalSize = viewports[viewport]!;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          final handle = tester.ensureSemantics();

          final fixture = await fixtureContainer();
          try {
            final route = surface.value.route;
            final router = fixtureRouter(route);
            await tester.pumpWidget(
              UncontrolledProviderScope(
                container: fixture.container,
                child: MaterialApp.router(
                  debugShowCheckedModeBanner: false,
                  theme: buildTheme(Brightness.dark, AppTokens.dark),
                  routerConfig: router,
                  builder: appChromeBuilder,
                ),
              ),
            );
            if (isModalFixtureRoute(route)) {
              await tester.pump();
              unawaited(router.push(route));
            }
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 350));
            await tester.pump(const Duration(milliseconds: 350));
            await tester.pump(const Duration(milliseconds: 350));

            final problems = semanticsProblems(tester);
            expect(
              problems,
              isEmpty,
              reason:
                  '${surface.key} at $viewport paints widgets a screen reader '
                  'cannot reach:\n  ${problems.join('\n  ')}',
            );
            expect(tester.takeException(), isNull);
          } finally {
            handle.dispose();
            await teardownFixture(tester, fixture.container, fixture.db);
          }
        },
      );
    }
  }
}
