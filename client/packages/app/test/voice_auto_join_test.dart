// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the direct-join redesign: a voice channel joins on arrival with
/// no lobby and no explicit Join tap, except the one case that still asks
/// first - already being in a different call somewhere else.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/screens/voice_call_controls.dart';
import 'package:slimm_app/src/features/voice/screens/voice_join_preview.dart'
    show VoiceSwitchPrompt;
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
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
  final harness = VoiceHarness();
  tearDown(harness.dispose);

  testWidgets('arriving at a voice channel joins it automatically', (
    tester,
  ) async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());

    await tester.pumpWidget(
      _harness(const VoiceScreen(channelId: 'channel-1'), harness.container),
    );
    await tester.pumpAndSettle();

    expect(
      session.askedForMicrophoneOnJoin,
      isTrue,
      reason: 'no button was tapped, so the screen itself had to join',
    );
    // The fake never emits its own transitions, so this proves the screen renders once actually connected.
    session.emitState(VoiceSessionState.connected);
    await tester.pumpAndSettle();

    expect(find.byType(CallControls), findsOneWidget);
    await controller.leave();
  });

  testWidgets('arriving at a different call asks before switching, rather than '
      'hanging up silently', (tester) async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-a');
    session.emitState(VoiceSessionState.connected);

    await tester.pumpWidget(
      _harness(const VoiceScreen(channelId: 'channel-b'), harness.container),
    );
    await tester.pumpAndSettle();

    expect(find.byType(VoiceSwitchPrompt), findsOneWidget);
    expect(find.text('Already in a call'), findsOneWidget);
    // channel-b was never asked for on its own: only channel-a's join ran.
    expect(controller.state.channelId, 'channel-a');
    await controller.leave();
  });

  testWidgets(
    'confirming the switch leaves the first call and joins the second',
    (tester) async {
      final session = FakeSession();
      final controller = harness.controllerWith(session, voiceApi());
      await controller.join('channel-a');
      session.emitState(VoiceSessionState.connected);

      await tester.pumpWidget(
        _harness(const VoiceScreen(channelId: 'channel-b'), harness.container),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Switch to this call'));
      await tester.pumpAndSettle();

      expect(controller.state.channelId, 'channel-b');
      expect(find.byType(VoiceSwitchPrompt), findsNothing);
      await controller.leave();
    },
  );
}
