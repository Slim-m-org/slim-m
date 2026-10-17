// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bounded auto-rejoin used to blank the whole call stage for a
/// full-screen "Reconnecting" spinner; this drives the real widget tree to
/// confirm the stage now stays up with a banner over it instead.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_join_preview.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_reconnect_banner.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

Widget _harness(Widget child, ProviderContainer container) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: child),
      ),
    );

void main() {
  testWidgets(
    'a bounded auto-rejoin keeps the call stage up with a banner, not a full-screen spinner',
    (tester) async {
      final harness = VoiceHarness();
      final session = FakeSession();
      // finally, not addTearDown: the pending auto-rejoin timer must be cancelled before the binding's own end-of-test check runs.
      try {
        final controller = harness.controllerWith(
          session,
          voiceApi(),
          extraOverrides: [
            voiceRosterProvider.overrideWith(
              (ref, channelId) =>
                  const Stream<List<api.VoiceRosterParticipant>>.empty(),
            ),
          ],
        );

        await tester.pumpWidget(
          _harness(
            const VoiceScreen(channelId: 'channel-1'),
            harness.container,
          ),
        );
        await controller.join('channel-1');
        session.emitState(VoiceSessionState.connected);
        await tester.pump();
        await tester.pump();

        expect(find.byTooltip(RegExp(r'^Leave call')), findsOneWidget);
        expect(find.byType(VoiceReconnectBanner), findsNothing);

        session.dropWith(VoiceDisconnect.connectionLost);
        await tester.pump();
        await tester.pump();

        expect(
          controller.state.rejoining,
          isTrue,
          reason:
              'the auto-rejoin this test is exercising must actually be queued',
        );
        expect(
          find.byType(VoiceConnecting),
          findsNothing,
          reason: 'the bounded retry must not blank the call stage',
        );
        expect(
          find.byType(VoiceReconnectBanner),
          findsOneWidget,
          reason: 'reconnecting must read as in-progress feedback, not silence',
        );
        expect(
          find.byTooltip(RegExp(r'^Leave call')),
          findsOneWidget,
          reason: 'the call controls stay usable through the retry window',
        );
      } finally {
        harness.dispose();
      }
    },
  );
}
