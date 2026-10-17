// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A real "Always reduce" viewer, dropped onto five routed surfaces
/// `ui_snapshot_test.dart` already renders, once each rather than at every
/// breakpoint that harness samples: the same broad-sweep shape, aimed at
/// motion instead of layout.
///
/// `tester.hasRunningAnimations` right after a short pump is the same
/// assertion `home_shell_canvas_test.dart` and `reduce_motion_test.dart`
/// already use per-widget; this runs it once across five real, fully wired
/// screens rather than a widget mounted in isolation, so an on-mount
/// animation that ignores the override - an `AppFadeIn` reached through a
/// path none of the narrower tests happen to cover, say - fails here even
/// with no test written for that specific screen. It does not, and cannot,
/// catch the interaction-triggered gap `reduce_motion_gate_test.dart` and
/// today's three fixes closed: nothing here taps anything, so a
/// `showDialog`/`showModalBottomSheet`/`ExpansionTile` never opens.
///
/// The pump is 5ms, not zero and not a settle, and both bounds are load-
/// bearing. Zero elapsed catches `AppMotion.reducedSize`'s own documented
/// 1ms floor mid-flight - an `AnimatedSize` can never reach a literal zero,
/// so channel_rail_frame.dart's own reads as still running at t=0 even
/// though nothing is wrong. A full `pumpAndSettle` goes too far the other
/// way: a bounded animation that ignored reduce motion still finishes and
/// stops ticking within it, indistinguishable from having never started.
/// 5ms clears the first without giving a 100ms+ animation any real chance
/// to complete.
///
/// `motionPreferenceControllerProvider` is overridden to `alwaysReduce`
/// rather than wrapping a bare `MediaQuery`, so this drives the real
/// production path: `appChromeBuilder` is what turns that choice into the
/// `MediaQuery` override every widget under test actually reads, the same
/// route a real viewer's own Personal-settings choice takes.
///
/// One more zero-duration pump follows the 5ms one, before the check: a
/// provider resolving for the first time while an `AppAsyncView`'s own
/// `LayoutBuilder` is mid-layout - true of the roles pane's first paint,
/// new to this route's coverage - schedules one deferred rebuild frame
/// through `LayoutBuilder`'s own re-entrant-layout guard, which reads as a
/// running animation to `hasRunningAnimations` even though nothing is
/// animating. A zero-duration pump flushes exactly that one callback
/// without moving the fake clock, so a real reduce-motion violation, which
/// needs elapsed virtual time to still be mid-flight, is still caught.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/features/settings/providers/display_preferences.dart';
import 'package:slimm_design_system/design_system.dart';

import 'ui_snapshot_support.dart';

class _AlwaysReduceMotion extends MotionPreferenceController {
  _AlwaysReduceMotion(super.ref) {
    state = MotionOverride.alwaysReduce;
  }
}

/// One representative width per surface, not the whole breakpoint matrix
/// `ui_snapshot_test.dart` samples: this gate is about whether anything
/// moves at all under the setting, not about where a layout branches.
const _routes = <String, String>{
  'channel': '/channels/c-general',
  'settings': '/settings',
  'space-settings': '/settings/space',
  'admin-roles': '/settings/roles',
  'thread': '/thread/c-thread',
};

Future<void> _renderReduced(WidgetTester tester, String route) async {
  tester.view.physicalSize = const Size(1400, 880);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final fixture = await fixtureContainer(
    extraOverrides: [
      motionPreferenceControllerProvider.overrideWith(_AlwaysReduceMotion.new),
    ],
  );
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
  // See this file's own library doc for why 5ms, not zero and not a settle.
  await tester.pump(const Duration(milliseconds: 5));
  // See the library doc's "one more zero-duration pump" paragraph.
  await tester.pump();

  expect(
    tester.hasRunningAnimations,
    isFalse,
    reason: 'nothing may keep ticking once the viewer has asked it not to',
  );

  await tester.pumpAndSettle();
  await teardownFixture(tester, fixture.container, fixture.db);
}

void main() {
  setUpAll(loadRealFonts);

  for (final route in _routes.entries) {
    testWidgets(
      '${route.key} settles with nothing running under reduce motion',
      (tester) async {
        await _renderReduced(tester, route.value);
      },
    );
  }
}
