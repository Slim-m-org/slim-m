// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Regression: push-to-talk must not open the mic for a paste chord
/// or for typing into a text field other than the composer (a canvas note).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/push_to_talk_listener.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

void main() {
  final harness = VoiceHarness();

  setUp(
    () => SharedPreferences.setMockInitialValues({
      'slimm.voice.push_to_talk_enabled': true,
    }),
  );
  tearDown(harness.dispose);

  Future<VoiceController> connect(
    WidgetTester tester,
    Widget child, {
    List<Override> extraOverrides = const [],
  }) async {
    final session = FakeSession();
    final controller = harness.controllerWith(
      session,
      voiceApi(),
      extraOverrides: extraOverrides,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: harness.container,
        child: MaterialApp(
          home: PushToTalkListener(child: Scaffold(body: child)),
        ),
      ),
    );
    // The listener's own initState warm-up needs a turn of the event loop to resolve before a key event can see it.
    await tester.pumpAndSettle();
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    await tester.pumpAndSettle();
    return controller;
  }

  Future<VoiceController> mutedCall(WidgetTester tester, Widget child) async {
    final controller = await connect(tester, child);
    await controller.toggleMicrophone();
    await tester.pumpAndSettle();
    expect(controller.state.microphoneEnabled, isFalse);
    return controller;
  }

  testWidgets('typing V in a non-composer text field does not open the mic', (
    tester,
  ) async {
    final controller = await mutedCall(
      tester,
      const TextField(autofocus: true),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.pump();

    expect(
      controller.state.microphoneEnabled,
      isFalse,
      reason: 'a canvas note editor is an EditableText; V is just a letter',
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await controller.leave();
  });

  testWidgets('Ctrl+V paste does not open the mic', (tester) async {
    final controller = await mutedCall(tester, const SizedBox.shrink());

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.pump();

    expect(
      controller.state.microphoneEnabled,
      isFalse,
      reason: 'a modified chord is a shortcut, not the push-to-talk key',
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await controller.leave();
  });
}
