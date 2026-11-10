// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The real router and a share from the OS sheet: it outranks wherever the
/// person was, waits through sign-in, and never traps them once it is placed.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/share/providers/incoming_share.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/routing/router.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../support/fake_api.dart';
import '../support/fake_sync.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

const _share = PendingShare(IncomingShare(text: 'hello'));

Future<({ProviderContainer container, SlimmDatabase db, GoRouter router})>
_pump(
  WidgetTester tester, {
  bool signedIn = true,
  PendingShare? pending,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final db = SlimmDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      syncControllerProvider.overrideWith(NoopSyncController.new),
      databaseProvider.overrideWith((ref) => db),
      mockApiOverride((_) async => throw StateError('no network')),
    ],
  );
  container
      .read(chosenServerProvider.notifier)
      .restore(Uri.parse('http://localhost:8080'));
  if (signedIn) container.read(sessionProvider).set(_tokens);
  container.read(pendingShareProvider.notifier).state = pending;
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
  await tester.pump();
  await tester.pump();
  return (container: container, db: db, router: router);
}

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

void main() {
  testWidgets('a share waiting at launch opens the picker, not the channels', (
    tester,
  ) async {
    final (:container, :db, :router) = await _pump(tester, pending: _share);

    expect(router.state.matchedLocation, Routes.share);

    await _teardown(tester, container, db);
  });

  testWidgets('a share arriving later takes the person there from anywhere', (
    tester,
  ) async {
    final (:container, :db, :router) = await _pump(tester);
    router.go(Routes.channel('c1'));
    await tester.pump();
    await tester.pump();
    expect(router.state.matchedLocation, '/channels/c1');

    container.read(pendingShareProvider.notifier).state = _share;
    await tester.pump();
    await tester.pump();

    expect(router.state.matchedLocation, Routes.share);

    await _teardown(tester, container, db);
  });

  testWidgets('once placed, going to a channel is not bounced back', (
    tester,
  ) async {
    final (:container, :db, :router) = await _pump(tester, pending: _share);

    container.read(pendingShareProvider.notifier).state = null;
    router.go(Routes.channel('c1'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(router.state.matchedLocation, '/channels/c1');

    await _teardown(tester, container, db);
  });

  testWidgets('signed out, the share waits and sign-in resumes it', (
    tester,
  ) async {
    final (:container, :db, :router) = await _pump(
      tester,
      signedIn: false,
      pending: _share,
    );
    expect(router.state.matchedLocation, Routes.signIn);
    expect(container.read(pendingShareProvider), isNotNull);

    container.read(sessionProvider).set(_tokens);
    await tester.pump();
    await tester.pump();

    expect(router.state.matchedLocation, Routes.share);

    await _teardown(tester, container, db);
  });

  testWidgets('the picker with nothing pending is not a place to stay', (
    tester,
  ) async {
    final (:container, :db, :router) = await _pump(tester);

    router.go(Routes.share);
    await tester.pump();
    await tester.pump();

    expect(router.state.matchedLocation, Routes.channels);

    await _teardown(tester, container, db);
  });
}
