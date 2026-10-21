// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What tells a rejoin apart from a first connection, and, since the
/// reconnect-overlay fix, apart from having left the call outright.
///
/// `voice_auto_rejoin_test.dart` asserts the provider reaches `rejoining`,
/// and nothing pumped a `VoiceScreen` to see what that renders. This used to
/// check a single full-screen 'Reconnecting' label; a rejoin now keeps the
/// call stage up and overlays `VoiceReconnectBanner` instead, so the
/// assertions check for that banner rather than a swapped-in word.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_join_preview.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_reconnect_banner.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// Pumps the screen with the controller pinned to [voice] and returns the
/// container so the caller can tear it down.
Future<ProviderContainer> _pump(WidgetTester tester, VoiceState voice) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      voiceRosterProvider.overrideWith(
        (ref, channelId) => const Stream<List<VoiceRosterParticipant>>.empty(),
      ),
      voiceControllerProvider.overrideWith(
        (ref) => FixedVoiceController(ref, voice),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(body: VoiceScreen(channelId: 'c1')),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  testWidgets(
    'a rejoin in this channel shows the reconnect banner over the call stage',
    (tester) async {
      final container = await _pump(
        tester,
        const VoiceState(
          channelId: 'c1',
          state: VoiceSessionState.connecting,
          rejoining: true,
        ),
      );
      addTearDown(container.dispose);

      expect(find.byType(VoiceReconnectBanner), findsOneWidget);
      expect(
        find.byType(VoiceConnecting),
        findsNothing,
        reason:
            'a rejoin must not blank the call stage behind a full-screen spinner',
      );
    },
  );

  testWidgets('a first connection names its negotiating phase', (tester) async {
    final container = await _pump(
      tester,
      const VoiceState(channelId: 'c1', state: VoiceSessionState.connecting),
    );
    addTearDown(container.dispose);

    expect(find.text('Negotiating audio'), findsOneWidget);
    expect(find.byType(VoiceReconnectBanner), findsNothing);
  });

  /// The case `rejoiningHere` is in the stage ternary *for*, and the one the
  /// first two cases above miss.
  ///
  /// While an auto-rejoin waits between attempts the session has already
  /// failed, so `connectingHere` and `joiningHere` are both false. Without
  /// `rejoiningHere` the stage falls through to the rejoin screen and somebody
  /// whose network is coming back is told they left the call.
  // Fails: dropping `|| rejoiningHere` from the stage ternary.
  testWidgets(
    'a rejoin between attempts keeps the call stage, not the left-call screen',
    (tester) async {
      final container = await _pump(
        tester,
        const VoiceState(
          channelId: 'c1',
          state: VoiceSessionState.failed,
          rejoining: true,
        ),
      );
      addTearDown(container.dispose);

      expect(find.byType(VoiceReconnectBanner), findsOneWidget);
      expect(
        find.text('You left this call.'),
        findsNothing,
        reason: 'a pending rejoin is not somebody having left',
      );
    },
  );

  // Proves `rejoiningHere`'s channel gate is real, not incidental.
  testWidgets('a rejoin in another channel does not claim this one', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      const VoiceState(
        channelId: 'other',
        state: VoiceSessionState.connecting,
        rejoining: true,
      ),
    );
    addTearDown(container.dispose);

    expect(find.byType(VoiceReconnectBanner), findsNothing);
  });
}
