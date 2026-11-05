// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A tap on a voice row navigates, and rejoins when the channel is already the
/// open one - where a bare `go()` to the current location did nothing visible.
/// The row menu no longer repeats that as an entry of its own.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

const _channel = Channel(
  id: 'ch-1',
  name: 'General voice',
  kind: 'voice',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

GoRouter _router(String initialLocation) => GoRouter(
  initialLocation: initialLocation,
  routes: [
    GoRoute(
      path: '/channels/:channelId',
      builder: (context, state) => Scaffold(
        body: ChannelCategorySections(
          channels: const [_channel],
          categories: const [],
          selectedId: state.pathParameters['channelId'],
          canManage: false,
          onReorder: (_) {},
        ),
      ),
    ),
  ],
);

Future<VoiceHarness> _pump(
  WidgetTester tester,
  FakeSession session,
  GoRouter router,
) async {
  final harness = VoiceHarness();
  addTearDown(harness.dispose);
  harness.controllerWith(
    session,
    voiceApi(),
    extraOverrides: [
      voiceRosterProvider(_channel.id).overrideWith(
        (ref) => const Stream<List<api.VoiceRosterParticipant>>.empty(),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: harness.container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return harness;
}

Future<void> _tapRow(WidgetTester tester) async {
  await tester.tap(find.text(_channel.name));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('tapping the already-open voice row rejoins', (tester) async {
    final session = FakeSession();
    final router = _router('/channels/ch-1');
    final harness = await _pump(tester, session, router);
    final controller = harness.container.read(voiceControllerProvider.notifier);
    await controller.join(_channel.id);
    await controller.leave();
    expect(session.state, VoiceSessionState.idle);

    await _tapRow(tester);

    expect(router.routeInformationProvider.value.uri.path, '/channels/ch-1');
    expect(session.state, VoiceSessionState.connected);
  });

  testWidgets(
    'tapping a voice row from elsewhere navigates without a double join',
    (tester) async {
      final session = FakeSession();
      final router = _router('/channels/elsewhere');
      await _pump(tester, session, router);

      await _tapRow(tester);

      expect(router.routeInformationProvider.value.uri.path, '/channels/ch-1');
      expect(session.state, VoiceSessionState.idle);
    },
  );
}
