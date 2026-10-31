// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `RailConnectionBar` lived only inside `ChannelRail`, which a compact
/// layout with a channel open never mounts, so the one route a phone user
/// spends all their time on never reported the socket dropping.
///
/// The wide layout no longer shows the bar at all (owner request,
/// 2026-08-03): its offline state now surfaces through the header's
/// `SpaceConnectionDot`, beside the Space name, rather than a banner pushed
/// above the profile footer - see `channel_rail_frame.dart`'s own doc.
/// Owner decision 2026-10-26: the dot stays and an "Offline" word joins it
/// while disconnected, because an 8px dot alone was the only cue at desktop
/// width and went unnoticed in the UI audit.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_frame.dart';
import 'package:slimm_app/src/sync/providers/sync_failure.dart';
import 'package:slimm_app/src/widgets/space_connection_dot.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../ui_snapshot_support.dart';
import '../../support/fake_sync.dart';

Future<({ProviderContainer container, SlimmDatabase db})> _pumpOffline(
  WidgetTester tester,
  Size size, {
  SyncStatus status = SyncStatus.offline,
  bool hasFailedSinceLive = false,
  SyncFailure? failure,
}) async {
  final fixture = await fixtureContainer(
    extraOverrides: [
      syncControllerProvider.overrideWith(
        (ref) => StubSyncController(ref, status),
      ),
      hasFailedSinceLiveProvider.overrideWith((ref) => hasFailedSinceLive),
      syncFailureProvider.overrideWith((ref) => failure),
    ],
  );
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: fixtureRouter('/channels/c-general'),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));

  return (container: fixture.container, db: fixture.db);
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('the connection bar appears on a compact layout when offline', (
    tester,
  ) async {
    final fixture = await _pumpOffline(tester, const Size(390, 844));

    expect(find.byType(RailConnectionBar), findsOneWidget);
    expect(find.text('Offline, retrying'), findsOneWidget);

    await teardownFixture(tester, fixture.container, fixture.db);
  });

  testWidgets(
    'a wide layout shows no connection bar at all when offline; the header '
    'dot carries it instead',
    (tester) async {
      final fixture = await _pumpOffline(tester, const Size(1400, 880));

      expect(find.byType(RailConnectionBar), findsNothing);
      expect(find.byType(SpaceConnectionDot), findsOneWidget);
      expect(find.byTooltip('Offline, retrying'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
      expect(find.text('Offline, retrying'), findsNothing);

      await teardownFixture(tester, fixture.container, fixture.db);
    },
  );

  testWidgets('a wide header says the session was refused, not Offline', (
    tester,
  ) async {
    final fixture = await _pumpOffline(
      tester,
      const Size(1400, 880),
      failure: SyncFailure.refused,
    );

    expect(find.text('Refused'), findsOneWidget);
    expect(find.text('Offline'), findsNothing);

    await teardownFixture(tester, fixture.container, fixture.db);
  });

  testWidgets(
    'a retry attempt after a real failure still reads Offline, not Connecting',
    (tester) async {
      final fixture = await _pumpOffline(
        tester,
        const Size(390, 844),
        status: SyncStatus.connecting,
        hasFailedSinceLive: true,
      );

      expect(find.text('Offline, retrying'), findsOneWidget);
      expect(find.text('Connecting'), findsNothing);

      await teardownFixture(tester, fixture.container, fixture.db);
    },
  );

  testWidgets('a wide layout shows no Offline label while live', (
    tester,
  ) async {
    final fixture = await _pumpOffline(
      tester,
      const Size(1400, 880),
      status: SyncStatus.live,
    );

    expect(find.text('Offline'), findsNothing);

    await teardownFixture(tester, fixture.container, fixture.db);
  });
}
