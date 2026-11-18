// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A floating page loaded straight from the address bar gets the channels
/// shell beneath it, so it floats over the app rather than a bare backdrop.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_app/src/routing/cold_modal_launch.dart';
import 'package:slimm_app/src/routing/routes.dart';

GoRouter _router(String initial) => GoRouter(
  initialLocation: initial,
  routes: [
    GoRoute(
      path: Routes.signIn,
      builder: (context, state) => const Text('sign in'),
    ),
    GoRoute(
      path: Routes.personalSettings,
      pageBuilder: (context, state) =>
          const MaterialPage(child: Text('settings')),
    ),
    ShellRoute(
      builder: (context, state, child) => Column(
        children: [
          const Text('shell'),
          Expanded(child: child),
        ],
      ),
      routes: [
        GoRoute(
          path: Routes.channels,
          builder: (context, state) => const Text('no channel'),
        ),
      ],
    ),
  ],
);

Future<GoRouter> _launch(WidgetTester tester, String location) async {
  final router = _router(location);
  addTearDown(router.dispose);
  putShellUnderColdModal(router, launch: location);
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return router;
}

void main() {
  testWidgets('a settings page loaded cold opens over the shell', (
    tester,
  ) async {
    final router = await _launch(tester, Routes.personalSettings);

    expect(find.text('settings'), findsOne);
    expect(find.text('shell', skipOffstage: false), findsOne);
    expect(router.canPop(), isTrue);
  });

  testWidgets('a page that is its own screen is left alone', (tester) async {
    await _launch(tester, Routes.signIn);

    expect(find.text('sign in'), findsOne);
    expect(find.text('shell', skipOffstage: false), findsNothing);
  });
}
