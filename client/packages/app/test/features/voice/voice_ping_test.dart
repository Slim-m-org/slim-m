// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The voice ping: tiers, the call header's readout and the connection dot's
/// hover text.
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_health.dart';
import 'package:slimm_app/src/features/voice/providers/voice_ping.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_ping_readout.dart';
import 'package:slimm_app/src/features/voice/widgets/call_header_facts.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/widgets/space_connection_dot.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

Widget _app(Widget child, {ValueNotifier<int?>? ping}) => ProviderScope(
  overrides: [
    if (ping != null)
      voicePingProvider.overrideWith((ref) => ListenableState(ping)),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  test('tiers split at 100 and 200 ms', () {
    expect(voicePingTier(99), VoicePingTier.good);
    expect(voicePingTier(100), VoicePingTier.fair);
    expect(voicePingTier(199), VoicePingTier.fair);
    expect(voicePingTier(200), VoicePingTier.poor);
  });

  testWidgets('the readout shows milliseconds, tinted by tier', (tester) async {
    final ping = ValueNotifier<int?>(null);
    addTearDown(ping.dispose);
    await tester.pumpWidget(
      _app(const VoicePingReadout(style: TextStyle()), ping: ping),
    );
    expect(find.textContaining('ms'), findsNothing);

    ping.value = 42;
    await tester.pump();
    expect(find.text('42 ms'), findsOneWidget);
    final tokens = Theme.of(
      tester.element(find.text('42 ms')),
    ).extension<AppTokens>()!;
    Color colorOf(String t) => tester.widget<Text>(find.text(t)).style!.color!;
    expect(colorOf('42 ms'), tokens.textSecondary);

    ping.value = 150;
    await tester.pump();
    expect(colorOf('150 ms'), tokens.warnText);

    ping.value = 320;
    await tester.pump();
    expect(colorOf('320 ms'), tokens.dangerText);
  });

  testWidgets('hovering the connection dot adds the voice ping in a call', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const SpaceConnectionDot(status: SyncStatus.live, voicePingMs: 42)),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(SpaceConnectionDot)));
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('Voice ping 42 ms'), findsOneWidget);
  });

  testWidgets('out of a call the dot keeps its plain tooltip', (tester) async {
    await tester.pumpWidget(
      _app(const SpaceConnectionDot(status: SyncStatus.live)),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(SpaceConnectionDot)));
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('Voice ping'), findsNothing);
    expect(find.text('Connected to the server'), findsOneWidget);
  });

  testWidgets('the call header carries the ping beside the timer', (
    tester,
  ) async {
    final harness = VoiceHarness();
    final session = FakeSession();
    try {
      final controller = harness.controllerWith(session, voiceApi());
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: harness.container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const Scaffold(body: CallHeaderLine(channelId: 'channel-1')),
          ),
        ),
      );
      await controller.join('channel-1');
      session.emitState(VoiceSessionState.connected);
      await tester.pump();
      expect(find.textContaining('ms'), findsNothing);

      session.health.pingMs.value = 42;
      await tester.pump();
      expect(find.text('42 ms'), findsOneWidget);
    } finally {
      harness.dispose();
    }
  });
}
