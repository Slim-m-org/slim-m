// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call switch or a Cancel whose SFU round trip stalls: the new channel shows
/// its own connecting state at once, never the old room, and Cancel lets go at once.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/async_wait.dart';
import 'voice_controller_harness.dart';

Widget _harness(Widget child, ProviderContainer container) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: child),
      ),
    );

VoiceParticipant _p(String id, {bool local = false}) => VoiceParticipant(
  identity: id,
  name: id,
  isSpeaking: false,
  isMuted: false,
  isLocal: local,
  isScreenSharing: false,
);

/// [voiceApi], except channel-b's token waits on [gate], the way a stalled SFU holds a switch.
http.Client _gatedToken(Completer<void> gate) {
  final inner = voiceApi();
  return MockClient((request) async {
    if (request.url.path.contains('channel-b') &&
        request.url.path.endsWith('/voice/token')) {
      await gate.future;
    }
    return http.Response.fromStream(await inner.send(request));
  });
}

/// Lets the loader's and the fades' timers run out with the tree gone, and stops the roster poll.
Future<void> _unmount(WidgetTester tester, VoiceHarness harness) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 10));
  harness.container.dispose();
}

void main() {
  final harness = VoiceHarness();
  tearDown(harness.dispose);

  testWidgets('a stalled switch shows the new channel connecting, never the '
      'old room under it', (tester) async {
    final gate = Completer<void>();
    final session = FakeSession();
    final controller = harness.controllerWith(session, _gatedToken(gate));
    await controller.join('channel-a');
    session.emitState(VoiceSessionState.connected);
    session.emitParticipants([_p('me', local: true), _p('bob-in-a')]);

    await tester.pumpWidget(
      _harness(const VoiceScreen(channelId: 'channel-b'), harness.container),
    );
    await pumpFrames(tester);
    await tester.tap(find.text('Switch to this call'));
    await pumpFrames(tester);
    // The old room's roster keeps arriving until its teardown starts.
    session.emitParticipants([_p('me', local: true), _p('bob-in-a')]);
    await pumpFrames(tester);

    expect(controller.state.channelId, 'channel-b');
    expect(find.text('bob-in-a'), findsNothing);
    expect(controller.state.participants, isEmpty);
    expect(controller.state.connectedAt, isNull);
    expect(find.text('Connecting'), findsOneWidget);

    gate.complete();
    await pumpFrames(tester);
    session.emitState(VoiceSessionState.idle);
    session.emitState(VoiceSessionState.connecting);
    session.emitParticipants([_p('me', local: true), _p('carol-in-b')]);
    session.emitState(VoiceSessionState.connected);
    await pumpFrames(tester);

    expect(controller.state.participants.map((p) => p.identity), [
      'me',
      'carol-in-b',
    ]);
    await controller.leave();
    await _unmount(tester, harness);
  });

  testWidgets('Cancel while negotiating lets go at once, even when the SFU '
      'stalls the hang-up', (tester) async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());

    await tester.pumpWidget(
      _harness(const VoiceScreen(channelId: 'channel-b'), harness.container),
    );
    await pumpFrames(tester);
    session.emitState(VoiceSessionState.connecting);
    await pumpFrames(tester);
    expect(find.text('Negotiating audio'), findsOneWidget);

    final teardown = Completer<void>();
    session.leaveGate = teardown;
    await tester.tap(find.text('Cancel'));
    await pumpFrames(tester);

    expect(controller.state.channelId, isNull);
    expect(find.text('Negotiating audio'), findsNothing);
    expect(find.text('Cancel'), findsNothing);

    teardown.complete();
    await pumpFrames(tester);
    expect(controller.state.channelId, isNull);
    await _unmount(tester, harness);
  });
}
