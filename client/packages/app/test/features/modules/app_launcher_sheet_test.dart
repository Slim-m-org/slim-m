// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The empty apps launcher used to tell every viewer the same thing -
/// "Install one from Modules first" - which a non-admin cannot act on.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/features/modules/providers/app_launch.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/features/modules/widgets/app_launcher_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _open(WidgetTester tester, {required int permissions}) async {
  final router = GoRouter(
    initialLocation: '/channels/c1',
    routes: [
      GoRoute(
        path: '/channels/:id',
        builder: (context, state) => Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () => showAppLauncherSheet(context, ref, 'c1'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: Routes.adminDock,
        builder: (context, state) => const Scaffold(body: Text('Dock screen')),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appLaunchProvider.overrideWith((ref) async => const <api.App>[]),
        myPermissionsProvider.overrideWithValue(permissions),
      ],
      child: MaterialApp.router(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: router,
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'a non-admin is told to ask, not to open a screen they cannot reach',
    (tester) async {
      await _open(tester, permissions: 0);

      expect(
        find.text(
          'No apps installed. Ask an admin to install one from '
          'Modules.',
        ),
        findsOneWidget,
      );
      expect(find.text('Open Modules'), findsNothing);
    },
  );

  testWidgets('an admin gets a real link into the Dock', (tester) async {
    await _open(tester, permissions: Perm.manageServer);

    expect(find.text('No apps installed yet.'), findsOneWidget);
    expect(find.text('Open Modules'), findsOneWidget);

    await tester.tap(find.text('Open Modules'));
    await tester.pumpAndSettle();

    expect(find.text('Dock screen'), findsOneWidget);
  });
}
