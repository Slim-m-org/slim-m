// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An address that matches no route showed go_router's own page, with the
/// raw exception text in it. The app now answers in its own words.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/router.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

void main() {
  for (final size in [const Size(390, 844), const Size(1280, 900)]) {
    testWidgets('an unknown route at ${size.width} px shows the not-found '
        'state with a reachable way home', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(
            api.SessionStore(
              tokens: const api.TokenPair(
                userId: 'u',
                accessToken: 't',
                refreshToken: 'r',
                accessExpiresAt: 0,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final router = container.read(routerProvider);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            theme: buildTheme(Brightness.light, AppTokens.light),
            routerConfig: router,
          ),
        ),
      );
      router.go('/nope/not-a-page');
      await tester.pumpAndSettle();

      expect(find.text('This page does not exist.'), findsOneWidget);
      expect(find.textContaining('GoException'), findsNothing);
      expect(find.text('Page Not Found'), findsNothing);
      final action = find.text('Back to channels');
      expect(action, findsOneWidget);
      expect(tester.getRect(action).right, lessThanOrEqualTo(size.width));
    });
  }
}
