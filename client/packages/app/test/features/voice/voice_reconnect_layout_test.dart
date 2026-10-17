// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// While a call reconnects, its one banner sits beside the header rather than
/// on it, nothing stacks a second error under it, and the header does not
/// claim an empty room.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_app/src/features/voice/widgets/call_header_facts.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_reconnect_banner.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

const _me = VoiceParticipant(
  identity: 'user-1',
  name: 'Me',
  isLocal: true,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: false,
);

const _bob = VoiceParticipant(
  identity: 'user-2',
  name: 'Bob',
  isLocal: false,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: false,
);

void main() {
  testWidgets('the reconnect banner does not cover the call header', (
    tester,
  ) async {
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
        UncontrolledProviderScope(
          container: harness.container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const Scaffold(body: VoiceScreen(channelId: 'channel-1')),
          ),
        ),
      );
      await controller.join('channel-1');
      session.emitState(VoiceSessionState.connected);
      session.emitParticipants(const [_me, _bob]);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('2 in call'), findsOneWidget);

      session.emitParticipants(const []);
      session.dropWith(VoiceDisconnect.connectionLost);
      await tester.pump();
      await tester.pump();

      expect(controller.state.rejoining, isTrue);
      final banner = tester.getRect(find.byType(VoiceReconnectBanner));
      final header = tester.getRect(find.byType(CallHeaderLine));
      expect(
        banner.overlaps(header),
        isFalse,
        reason: 'banner $banner must not sit on the header $header',
      );
      expect(
        find.byType(AppErrorState),
        findsNothing,
        reason: 'one banner at a time while the auto-rejoin is under way',
      );
      expect(
        find.textContaining('0 in call'),
        findsNothing,
        reason: 'a reconnecting call has no count to claim',
      );
    } finally {
      harness.dispose();
    }
  });
}
