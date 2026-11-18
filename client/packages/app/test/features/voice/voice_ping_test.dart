// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The voice ping: tiers, the call header's readout and the connection dot's
/// hover text.
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/connection/connection_route.dart';
import 'package:slimm_app/src/features/connection/providers/connection_report.dart';
import 'package:slimm_app/src/features/voice/providers/voice_health.dart';
import 'package:slimm_app/src/features/voice/providers/voice_ping.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_ping_readout.dart';
import 'package:slimm_app/src/features/voice/widgets/call_header_facts.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/widgets/space_connection_dot.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

class _FixedStatus extends ConnectionStatusNotifier {
  int refreshes = 0;

  @override
  ConnectionStatus build() => (
    report: connectionReportOf(
      direct: false,
      responded: true,
      apiColo: 'GRU',
      apiRoundTrip: const Duration(milliseconds: 182),
      apiMeasuredAt: DateTime.now(),
      serverTrace: null,
      signalTrace: null,
      call: const CallLink(mediaRttMs: 4, media: MediaRoute.direct),
      now: DateTime.now(),
    ),
    concern: const RouteConcern(farCity: 'São Paulo'),
  );

  @override
  Future<void> refresh() async => refreshes++;
}

Widget _app(
  Widget child, {
  ValueNotifier<int?>? ping,
  _FixedStatus Function()? status,
}) => ProviderScope(
  overrides: [
    if (ping != null)
      voicePingProvider.overrideWith((ref) => ListenableState(ping)),
    if (status != null) connectionStatusProvider.overrideWith(status),
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

  testWidgets('a screen reader hears the tier, steady across samples', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final ping = ValueNotifier<int?>(42);
    addTearDown(ping.dispose);
    await tester.pumpWidget(
      _app(const VoicePingReadout(style: TextStyle()), ping: ping),
    );
    expect(
      find.bySemanticsLabel('Connection details, voice ping good'),
      findsOneWidget,
    );
    ping.value = 61;
    await tester.pump();
    expect(
      find.bySemanticsLabel('Connection details, voice ping good'),
      findsOneWidget,
    );
    ping.value = 250;
    await tester.pump();
    expect(
      find.bySemanticsLabel('Connection details, voice ping poor'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('tapping the readout opens the connection details and measures', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ping = ValueNotifier<int?>(4);
    addTearDown(ping.dispose);
    final status = _FixedStatus();
    await tester.pumpWidget(
      _app(
        const VoicePingReadout(style: TextStyle()),
        ping: ping,
        status: () => status,
      ),
    );
    await tester.tap(find.text('4 ms'));
    await tester.pump();
    await tester.pump(AppMotion.base);
    expect(find.text('Cloudflare São Paulo, 182\u00a0ms'), findsOneWidget);
    expect(find.text('Direct, 4\u00a0ms'), findsOneWidget);
    expect(
      find.textContaining('routing you through São Paulo'),
      findsOneWidget,
    );
    expect(status.refreshes, 1);
  });

  testWidgets('a far route tints a good ping amber', (tester) async {
    final ping = ValueNotifier<int?>(4);
    addTearDown(ping.dispose);
    await tester.pumpWidget(
      _app(
        const VoicePingReadout(style: TextStyle(), routeConcern: true),
        ping: ping,
      ),
    );
    final tokens = Theme.of(
      tester.element(find.text('4 ms')),
    ).extension<AppTokens>()!;
    expect(
      tester.widget<Text>(find.text('4 ms')).style!.color,
      tokens.warnText,
    );
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
