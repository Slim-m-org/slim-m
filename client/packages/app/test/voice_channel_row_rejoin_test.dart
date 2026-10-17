// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tapping the voice channel row already open, after a hang-up, must
/// actually rejoin - reproducing the owner's report of landing on what
/// reads as "the old voice lobby" on a click that should join directly.
///
/// `VoiceScreen`'s own arrival-triggered auto-join never fires for a
/// re-click of the channel already showing, since nothing about that
/// rebuild looks different from an unrelated one to it; see
/// `voice_channel_tap.dart`. This drives the row itself, the surface the
/// owner actually clicks.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_channel_rows.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'features/voice/voice_controller_harness.dart';

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

/// Stubbed so the row's own 15-second roster poll never leaves a pending
/// timer behind; the roster count itself is not what these tests are about.
final _extraOverrides = [
  voiceRosterProvider(_channel.id).overrideWith(
    (ref) => const Stream<List<api.VoiceRosterParticipant>>.empty(),
  ),
];

/// A router with just enough shape for `context.go(Routes.channel(...))` to
/// resolve, so the row's tap handler runs exactly as it does in the app. The
/// row itself is what every route renders, and [initialLocation] decides
/// whether the caller starts already on the row's own channel - the real
/// rail keeps the row on screen across a re-navigation to it, so
/// `context.go` to the same location the caller is already on must still
/// reach this same row.
GoRouter _router({required String initialLocation, required bool selected}) =>
    GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(
          path: '/channels/:channelId',
          builder: (context, state) => Scaffold(
            body: VoiceChannelRow(channel: _channel, selected: selected),
          ),
        ),
      ],
    );

void main() {
  testWidgets(
    'tapping the voice row already open, after hanging up, rejoins rather '
    'than sitting on the rejoin screen',
    (tester) async {
      final harness = VoiceHarness();
      addTearDown(harness.dispose);
      final session = FakeSession();
      final controller = harness.controllerWith(
        session,
        voiceApi(),
        extraOverrides: _extraOverrides,
      );

      await controller.join(_channel.id);
      expect(session.state, VoiceSessionState.connected);

      await controller.leave();
      expect(session.state, VoiceSessionState.idle);
      expect(session.leaveCalls, 1);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: harness.container,
          child: MaterialApp.router(
            theme: buildTheme(Brightness.light, AppTokens.light),
            routerConfig: _router(
              initialLocation: '/channels/ch-1',
              selected: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text(_channel.name));
      await tester.pumpAndSettle();

      expect(
        session.state,
        VoiceSessionState.connected,
        reason:
            'clicking the already-open voice channel again must rejoin, '
            'not leave the caller stuck needing a second, separate button',
      );
    },
  );

  testWidgets(
    'tapping a different, not-yet-selected voice row never double-joins',
    (tester) async {
      final harness = VoiceHarness();
      addTearDown(harness.dispose);
      final session = FakeSession();
      harness.controllerWith(
        session,
        voiceApi(),
        extraOverrides: _extraOverrides,
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: harness.container,
          child: MaterialApp.router(
            theme: buildTheme(Brightness.light, AppTokens.light),
            // Not yet selected: a fresh arrival, VoiceScreen's own job.
            routerConfig: _router(
              initialLocation: '/channels/elsewhere',
              selected: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text(_channel.name));
      await tester.pumpAndSettle();

      expect(
        session.state,
        VoiceSessionState.idle,
        reason: 'the row must not race VoiceScreen for the same fresh join',
      );
    },
  );
}
