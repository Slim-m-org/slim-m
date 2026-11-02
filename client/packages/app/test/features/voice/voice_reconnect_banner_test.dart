// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The SDK's own reconnect, on screen: a banner after a short debounce, never
/// for a blip that mends itself, and gone the moment the call is back.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/providers/voice_reconnect_display.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
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

const _copy = 'Reconnecting to the call.';

Future<ReconnectTracker> _connected(
  WidgetTester tester,
  VoiceHarness harness,
) async {
  final session = FakeSession();
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
  return session.health.reconnect;
}

void main() {
  testWidgets('a blip that outlasts the debounce shows the banner, and the '
      'end of it removes it', (tester) async {
    final harness = VoiceHarness();
    try {
      final transport = await _connected(tester, harness);
      expect(find.text(_copy), findsNothing);

      transport.started(ReconnectKind.resume);
      await tester.pump(const Duration(milliseconds: 1900));
      expect(
        find.text(_copy),
        findsNothing,
        reason: 'still inside the debounce',
      );

      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(_copy), findsOneWidget);
      expect(
        harness.container.read(voiceFlagsProvider).state,
        VoiceSessionState.connected,
        reason: 'a blip is not a new session state',
      );
      expect(
        find.textContaining('2 in call'),
        findsOneWidget,
        reason: 'the call still has its people while the transport mends',
      );

      transport.ended('reconnected');
      await tester.pump();
      expect(find.text(_copy), findsNothing);
    } finally {
      harness.dispose();
    }
  });

  testWidgets('a resume that mends itself inside the debounce never flashes '
      'the banner', (tester) async {
    final harness = VoiceHarness();
    try {
      final transport = await _connected(tester, harness);

      transport.started(ReconnectKind.resume);
      await tester.pump(const Duration(milliseconds: 400));
      transport.ended('reconnected');
      await tester.pump(const Duration(seconds: 5));

      expect(find.text(_copy), findsNothing);
      expect(harness.container.read(voiceFlagsProvider).reconnecting, isFalse);
    } finally {
      harness.dispose();
    }
  });

  testWidgets('a second blip waits out its own debounce', (tester) async {
    final harness = VoiceHarness();
    try {
      final transport = await _connected(tester, harness);
      transport.started(ReconnectKind.resume);
      await tester.pump(kReconnectBannerDelay + const Duration(seconds: 1));
      transport.ended('reconnected');
      await tester.pump();

      transport.started(ReconnectKind.restart);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(_copy), findsNothing);

      await tester.pump(const Duration(seconds: 2));
      expect(find.text(_copy), findsOneWidget);
      transport.ended('reconnected');
      await tester.pump();
    } finally {
      harness.dispose();
    }
  });

  test('the reconnecting flag takes part in the flags equality', () {
    expect(const VoiceFlags(reconnecting: true), isNot(const VoiceFlags()));
    expect(
      const VoiceFlags(reconnecting: true).hashCode,
      isNot(const VoiceFlags().hashCode),
    );
    expect(
      const VoiceFlags(reconnecting: true),
      const VoiceFlags(reconnecting: true),
    );
  });
}
