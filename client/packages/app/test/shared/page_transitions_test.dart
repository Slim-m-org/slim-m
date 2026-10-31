// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [fadeThroughRoute] carries [fadeThroughPage]'s own transition to the one
/// place a route is pushed imperatively (`Navigator.push`) rather than
/// through go_router: the onboarding server-identity steps. A route pushed
/// over another should behave the same way everywhere, so this pins the same
/// two properties `modal_page_test.dart` pins for the other transition.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/routing/page_transitions.dart';
import 'package:slimm_design_system/design_system.dart';

const Size _phone = Size(390, 844);
const Size _desktop = Size(1280, 900);

const Key _newScreenKey = Key('new-screen');

/// The route [fadeThroughRoute] hands back, without pushing it, the same way
/// `modal_page_test.dart` reads `modalPage`'s: the transition is a property
/// of the route, and reading it says what a viewer would get.
Future<PageRouteBuilder<void>> _routeFor(
  WidgetTester tester,
  Size window, {
  required bool reduceMotion,
}) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  late PageRouteBuilder<void> route;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(
        tester.view,
      ).copyWith(disableAnimations: reduceMotion),
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Builder(
          builder: (context) {
            route = fadeThroughRoute<void>(
              context,
              (context) => const SizedBox.shrink(),
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return route;
}

/// Pushes a real route through a real [Navigator], so the transition's own
/// `transitionsBuilder` runs with a genuine [BuildContext] to read
/// [LayoutClass] from - reading properties off the route object alone cannot
/// see that branch. Stops with the new route freshly mounted, its animation
/// not yet advanced: the tap's own gesture resolution costs the framework
/// one frame before the pushed route's `pageBuilder` is actually built, so
/// this settles that first frame before a caller times the transition itself.
Future<void> _pushNewScreen(WidgetTester tester, Size window) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                fadeThroughRoute<void>(
                  context,
                  (context) => const Scaffold(
                    body: Center(child: Text('new', key: _newScreenKey)),
                  ),
                ),
              ),
              child: const Text('old'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('old'));
  await tester.pump();
  await tester.pump();
}

void main() {
  group('reduce motion', () {
    testWidgets('leaves the transition running by default', (tester) async {
      final route = await _routeFor(tester, _desktop, reduceMotion: false);
      expect(route.transitionDuration, AppMotion.base);
      expect(route.reverseTransitionDuration, AppMotion.base);
    });

    testWidgets('collapses the route to an instant swap', (tester) async {
      final route = await _routeFor(tester, _desktop, reduceMotion: true);
      expect(route.transitionDuration, Duration.zero);
      expect(route.reverseTransitionDuration, Duration.zero);
    });
  });

  testWidgets('a compact window slides the new screen in from the edge', (
    tester,
  ) async {
    await _pushNewScreen(tester, _phone);

    // Two nested SlideTransitions (entrance, then underlay role); outermost is the entrance.
    SlideTransition outermost() => tester
        .widgetList<SlideTransition>(
          find.ancestor(
            of: find.byKey(_newScreenKey),
            matching: find.byType(SlideTransition),
          ),
        )
        .last;
    // Freshly mounted: still at its off-screen starting offset.
    expect(outermost().position.value.dx, 1);

    await tester.pumpAndSettle();
    expect(outermost().position.value, Offset.zero);
  });

  testWidgets(
    'a wide window holds the new screen invisible before fading it through',
    (tester) async {
      await _pushNewScreen(tester, _desktop);

      final fadeFinder = find
          .ancestor(
            of: find.byKey(_newScreenKey),
            matching: find.byType(FadeTransition),
          )
          .first;
      // Entrance is delayed to the back 65%, so freshly mounted it is still transparent.
      expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, 0);

      // A third of the way through the duration: still inside the delay.
      await tester.pump(AppMotion.base ~/ 3);
      expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, 0);

      await tester.pumpAndSettle();
      expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, 1);
    },
  );
}
