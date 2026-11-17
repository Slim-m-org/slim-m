// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call that connects while a voice screen's pre-join check is still out
/// wins over that check: no "Connecting" screen whose Cancel hangs it up, and
/// no second join once the check answers.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_elsewhere.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

class _CountingSession extends FakeSession {
  int joins = 0;

  @override
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
    bool canPublish = true,
  }) {
    joins++;
    return super.join(
      url: url,
      token: token,
      microphoneEnabled: microphoneEnabled,
      cameraEnabled: cameraEnabled,
      canPublish: canPublish,
    );
  }
}

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

  late Completer<String?> check;

  VoiceController setUp(FakeSession session) {
    check = Completer<String?>();
    return harness.controllerWith(
      session,
      voiceApi(),
      extraOverrides: [
        voiceElsewhereCheckProvider.overrideWithValue((_) => check.future),
      ],
    );
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  // Unmounting and disposing cancels the roster polls and the call's heartbeat.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    harness.container.dispose();
  }

  testWidgets('a call connecting elsewhere during the check shows the switch '
      'prompt, and the check never hangs it up or switches', (tester) async {
    final session = _CountingSession();
    final controller = setUp(session);
    await tester.pumpWidget(
      _harness(const VoiceScreen(channelId: 'channel-b'), harness.container),
    );
    await settle(tester);
    expect(find.text('Connecting'), findsOneWidget);

    await controller.join('channel-a');
    session.emitState(VoiceSessionState.connected);
    await settle(tester);
    expect(controller.state.state, VoiceSessionState.connected);

    expect(find.text('Cancel'), findsNothing);
    expect(find.text('Switch to this call'), findsOneWidget);

    check.complete(null);
    await settle(tester);
    expect(controller.state.channelId, 'channel-a');
    expect(controller.state.state, VoiceSessionState.connected);
    expect(session.leaveCalls, 0);
    expect(session.joins, 1);
    await unmount(tester);
  });

  testWidgets('a call connecting on this channel during the check is shown, '
      'and the check does not join it a second time', (tester) async {
    final session = _CountingSession();
    final controller = setUp(session);
    await tester.pumpWidget(
      _harness(const VoiceScreen(channelId: 'channel-a'), harness.container),
    );
    await settle(tester);

    await controller.join('channel-a');
    session.emitState(VoiceSessionState.connected);
    await settle(tester);
    expect(find.text('Connecting'), findsNothing);

    check.complete(null);
    await settle(tester);
    expect(controller.state.state, VoiceSessionState.connected);
    expect(session.leaveCalls, 0);
    expect(session.joins, 1);
    await unmount(tester);
  });

  testWidgets('cancel during the check abandons the join without touching a '
      'call', (tester) async {
    final session = _CountingSession();
    final controller = setUp(session);
    await tester.pumpWidget(
      _harness(const VoiceScreen(channelId: 'channel-b'), harness.container),
    );
    await settle(tester);

    await tester.tap(find.text('Cancel'));
    await settle(tester);
    check.complete(null);
    await settle(tester);

    expect(controller.state.channelId, isNull);
    expect(session.joins, 0);
    expect(find.text('Connecting'), findsNothing);
    await unmount(tester);
  });

  testWidgets('switching channels during the check drops the first join', (
    tester,
  ) async {
    final session = _CountingSession();
    final controller = setUp(session);
    await tester.pumpWidget(
      _harness(const VoiceScreen(channelId: 'channel-a'), harness.container),
    );
    await settle(tester);
    final first = check;
    check = Completer<String?>();

    await tester.pumpWidget(
      _harness(const VoiceScreen(channelId: 'channel-b'), harness.container),
    );
    await settle(tester);
    first.complete(null);
    check.complete(null);
    await settle(tester);

    expect(controller.state.channelId, 'channel-b');
    expect(session.joins, 1);
    await unmount(tester);
  });
}
