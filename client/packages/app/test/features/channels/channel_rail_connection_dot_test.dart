// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `SpaceConnectionDot`, the header indicator that replaced the profile
/// footer's own override of a person's presence with the socket's state
/// (owner request, 2026-08-03). Split out of `channel_rail_test.dart`, which
/// is already at its line budget.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/sync/providers/sync_failure.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_frame.dart';
import 'package:slimm_app/src/widgets/space_connection_dot.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_sync.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ProviderContainer _setup(
  SyncStatus status, {
  bool hasFailedSinceLive = false,
  SyncFailure? failure,
}) => ProviderContainer(
  overrides: [
    syncFailureProvider.overrideWith((ref) => failure),
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    syncControllerProvider.overrideWith(
      (ref) => StubSyncController(ref, status),
    ),
    hasFailedSinceLiveProvider.overrideWith((ref) => hasFailedSinceLive),
    mockApiOverride(
      (request) async =>
          http.Response('{}', 404, headers: {'content-type': 'json'}),
    ),
  ],
);

Future<void> _pumpHeader(WidgetTester tester, ProviderContainer container) {
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: Column(children: [RailHeader()])),
      ),
    ),
  );
}

AppStatusShape _shapeIn(WidgetTester tester) {
  final painter = tester
      .widget<CustomPaint>(
        find.descendant(
          of: find.byType(SpaceConnectionDot),
          matching: find.byType(CustomPaint),
        ),
      )
      .painter;
  return (painter! as AppStatusDotPainter).shape;
}

void main() {
  testWidgets(
    'each connection state has its own shape, not just its own colour',
    (tester) async {
      // One container, status mutated in place: a fresh one per status left a timer pending.
      final setup = _setup(SyncStatus.live);
      addTearDown(setup.dispose);
      final controller = setup.read(syncControllerProvider.notifier);
      await _pumpHeader(tester, setup);
      await tester.pumpAndSettle();

      final shapes = <SyncStatus, AppStatusShape>{};
      for (final status in SyncStatus.values) {
        controller.state = status;
        // Settled, not one pump: a flip cross-fades, so both paints coexist.
        await tester.pumpAndSettle();
        shapes[status] = _shapeIn(tester);
      }

      expect(
        shapes.values.toSet(),
        hasLength(SyncStatus.values.length),
        reason:
            'colour alone must never carry connection state, the same '
            'invariant AppStatusDot already holds for presence',
      );
    },
  );

  testWidgets('a connection flip cross-fades rather than repainting', (
    tester,
  ) async {
    final setup = _setup(SyncStatus.live);
    addTearDown(setup.dispose);
    final controller = setup.read(syncControllerProvider.notifier);
    await _pumpHeader(tester, setup);
    await tester.pumpAndSettle();

    controller.state = SyncStatus.offline;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final midFlip = find.descendant(
      of: find.byType(SpaceConnectionDot),
      matching: find.byType(CustomPaint),
    );
    expect(
      midFlip,
      findsNWidgets(2),
      reason: 'mid-flip both states paint, cross-fading on AppMotion.fast',
    );
    await tester.pumpAndSettle();
    expect(midFlip, findsOneWidget);
  });

  testWidgets('names the connection, never a person\'s presence', (
    tester,
  ) async {
    final setup = _setup(SyncStatus.offline);
    addTearDown(setup.dispose);
    await _pumpHeader(tester, setup);
    await tester.pumpAndSettle();

    expect(find.byTooltip('Offline, retrying'), findsOneWidget);
    // AppStatusDot's own baked-in label would instead say "Offline" on the dot itself.
    expect(
      find.descendant(
        of: find.byType(SpaceConnectionDot),
        matching: find.bySemanticsLabel('Offline'),
      ),
      findsNothing,
    );
  });

  testWidgets(
    'once a session has failed since live, a retry attempt reads as offline, not connecting',
    (tester) async {
      // Before this latch, the dot cross-faded to "Connecting" on every retry's brief connecting half.
      final setup = _setup(SyncStatus.connecting, hasFailedSinceLive: true);
      addTearDown(setup.dispose);
      await _pumpHeader(tester, setup);
      await tester.pumpAndSettle();

      expect(find.byTooltip('Offline, retrying'), findsOneWidget);
      expect(find.byTooltip('Connecting to the server'), findsNothing);
    },
  );

  testWidgets('a refused session does not read as an unreachable one', (
    tester,
  ) async {
    // Both were 'Offline, retrying', and only one of the two is worth waiting out.
    final setup = _setup(SyncStatus.offline, failure: SyncFailure.refused);
    addTearDown(setup.dispose);
    await _pumpHeader(tester, setup);
    await tester.pumpAndSettle();

    expect(find.byTooltip('The server refused this session'), findsOneWidget);
    expect(find.byTooltip('Offline, retrying'), findsNothing);
  });
}
