// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The not-found page says what happened, offers the way back, and does not
/// overflow on a small phone or at large text.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/not_found_screen.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, Size size, double scale) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final router = GoRouter(
    initialLocation: '/lost',
    routes: [
      GoRoute(path: '/lost', builder: (_, _) => const NotFoundScreen()),
      GoRoute(path: Routes.channels, builder: (_, _) => const Text('channels')),
    ],
  );
  await tester.pumpWidget(
    MaterialApp.router(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      routerConfig: router,
    ),
  );
  await tester.pump();
}

void main() {
  for (final (size, scale) in [
    (const Size(1200, 900), 1.0),
    (const Size(320, 480), 2.0),
  ]) {
    testWidgets('renders without overflow at $size, text x$scale', (
      tester,
    ) async {
      await _pump(tester, size, scale);
      expect(find.text('Nothing lives here'), findsOneWidget);
      expect(find.text('Back to channels'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Back to channels goes to the channels route', (tester) async {
    await _pump(tester, const Size(800, 600), 1.0);
    await tester.tap(find.text('Back to channels'));
    await tester.pump();
    await tester.pump();
    expect(find.text('channels'), findsOneWidget);
  });
}
