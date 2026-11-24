// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A role deleted while its detail screen is open closes that screen once,
/// however often the roles list refreshes during the pop transition.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/role_detail_screen.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  testWidgets('refreshes during the pop transition close only the detail', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        rolesProvider.overrideWith((ref) async => const <api.Role>[]),
      ],
    );
    addTearDown(container.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigator,
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: Text('base')),
        ),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('roles list')),
      ),
    );
    await pumpFrames(tester, frames: 40);
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const RoleDetailScreen(roleId: 'gone'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    for (var i = 0; i < 3; i++) {
      container.invalidate(rolesProvider);
      await tester.pump(const Duration(milliseconds: 20));
    }
    await pumpFrames(tester, frames: 40);

    expect(find.text('roles list'), findsOneWidget);
  });
}
