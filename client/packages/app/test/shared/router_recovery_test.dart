// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for where a signed-out user is sent.
///
/// Losing a session is ordinary: a refresh token is rejected, a device is
/// revoked, someone signs out. What must not be ordinary is being asked to
/// find and retype the server address afterwards, which is what happens when
/// the only record of the chosen server is the session that just went away.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/router.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/widgets/labeled_field.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

const _server = 'https://chat.example';

/// A container wired like the app's, with the network answering only the
/// /version probe the sign-in screen fires from initState, and the database
/// in memory so the shell can mount.
({ProviderContainer container, SlimmDatabase db}) _setup() {
  final db = SlimmDatabase(NativeDatabase.memory());
  final probeClient = MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/version') {
      return http.Response(
        jsonEncode({
          'name': 'slim-m',
          'version': '0.10.0',
          'protocol': 1,
          'push_enabled': true,
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }
    return http.Response('{}', 200);
  });
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      databaseProvider.overrideWith((ref) => db),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: ref.watch(serverUrlProvider),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(
            (_) async => throw StateError('no network in this test'),
          ),
        );
        ref.onDispose(api.close);
        return api;
      }),
      probeApiProvider.overrideWithValue(
        (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: probeClient),
      ),
    ],
  );
  return (container: container, db: db);
}

/// Drift keeps a query stream's cache alive on a timer after its last
/// listener goes; unmounting and pumping past it is what stops the pending
/// timer check firing instead of the assertion under test.
Future<void> _teardown(
  WidgetTester tester,
  ProviderContainer container,
  SlimmDatabase db,
) async {
  await tester.pumpWidget(const SizedBox());
  container.dispose();
  await tester.pump(const Duration(milliseconds: 1));
  await db.close();
}

Future<void> _pumpApp(
  WidgetTester tester,
  ProviderContainer container,
  GoRouter router,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'losing the session mid-use lands on sign-in with the server already '
    'filled in, not back at onboarding',
    (tester) async {
      final (:container, :db) = _setup();
      container.read(chosenServerProvider.notifier).restore(Uri.parse(_server));
      container.read(sessionProvider).set(_tokens);

      final router = container.read(routerProvider);
      await _pumpApp(tester, container, router);

      router.go(Routes.channel('c1'));
      await tester.pump();
      await tester.pump();

      // The session goes away underneath the user, the way a rejected refresh
      // or a revoked device ends it.
      container.read(sessionProvider).clear();
      await tester.pump();
      await tester.pump();

      expect(
        router.state.matchedLocation,
        Routes.signIn,
        reason: 'a user who already has a server does not need onboarding',
      );

      final field = tester.widget<TextField>(
        find.descendant(
          of: find.widgetWithText(LabeledField, 'Server'),
          matching: find.byType(TextField),
        ),
      );
      expect(
        field.controller!.text,
        _server,
        reason: 'the address the app already knows must not need retyping',
      );

      await _teardown(tester, container, db);
    },
  );

  testWidgets('a cold start with a remembered server opens sign-in', (
    tester,
  ) async {
    final (:container, :db) = _setup();
    container.read(chosenServerProvider.notifier).restore(Uri.parse(_server));

    final router = container.read(routerProvider);
    await _pumpApp(tester, container, router);

    expect(router.state.matchedLocation, Routes.signIn);

    await _teardown(tester, container, db);
  });

  testWidgets('a cold start with nothing remembered opens onboarding', (
    tester,
  ) async {
    final (:container, :db) = _setup();

    final router = container.read(routerProvider);
    await _pumpApp(tester, container, router);

    expect(
      router.state.matchedLocation,
      Routes.onboarding,
      reason: 'a first run has no server to go back to',
    );

    await _teardown(tester, container, db);
  });

  testWidgets('a new desktop account goes from sign-up straight to the '
      'channels, with no updates screen between', (tester) async {
    final (:container, :db) = _setup();
    container.read(chosenServerProvider.notifier).restore(Uri.parse(_server));

    final router = container.read(routerProvider);
    final visited = <String>[];
    router.routerDelegate.addListener(
      () => visited.add(router.state.matchedLocation),
    );
    await _pumpApp(tester, container, router);
    expect(router.state.matchedLocation, Routes.signIn);

    // Creating the account stores the session, which is all sign-up does now.
    container.read(sessionProvider).set(_tokens);
    await tester.pump();
    await tester.pump();

    expect(router.state.matchedLocation, Routes.channels);
    expect(visited.where((l) => l.contains('updates')), isEmpty);

    await _teardown(tester, container, db);
  });
}
