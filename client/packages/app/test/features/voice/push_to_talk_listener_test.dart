// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for [PushToTalkListener]: the raw key event actually reaching
/// [VoiceController] while enabled, and the guard that keeps the composer's
/// own keystrokes - including the configured key itself - from ever
/// toggling the mic. What holding and releasing does to the microphone once
/// the controller is asked is `push_to_talk_test.dart`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';
import 'package:slimm_app/src/providers/app_lock_controller.dart';
import 'package:slimm_app/src/features/composer/providers/composer_focus.dart';
import 'package:slimm_app/src/features/voice/providers/push_to_talk_gate.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/push_to_talk_listener.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/window_lifecycle.dart';
import 'voice_controller_harness.dart';

class _AlwaysLocked extends AppLockController {
  _AlwaysLocked(super.ref) {
    state = true;
  }
}

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

  testWidgets('holding the configured key unmutes, releasing re-mutes', (
    tester,
  ) async {
    final controller = await connect(tester, const SizedBox.shrink());
    expect(controller.state.microphoneEnabled, isTrue);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.pump();
    // Already true, so this alone would pass with nothing wired at all.
    expect(controller.state.microphoneEnabled, isTrue);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.pump();
    expect(
      controller.state.microphoneEnabled,
      isFalse,
      reason: 'release must actually reach the controller, or this stays true',
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.pump();
    expect(controller.state.microphoneEnabled, isTrue);
    // Clears the heartbeat timer a connected call now keeps running.
    await controller.leave();
  });

  testWidgets('an unconfigured key does nothing at all', (tester) async {
    final controller = await connect(tester, const SizedBox.shrink());

    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyB);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyB);
    await tester.pump();

    expect(controller.state.microphoneEnabled, isTrue);
    await controller.leave();
  });

  testWidgets(
    'typing a sentence containing the push-to-talk key while the composer '
    'has focus never toggles the mic',
    (tester) async {
      final composerNode = FocusNode();
      addTearDown(composerNode.dispose);
      final controller = await connect(
        tester,
        TextField(focusNode: composerNode, autofocus: true),
      );
      harness.container.read(composerFocusNodeProvider.notifier).state =
          composerNode;
      await tester.pumpAndSettle();
      expect(composerNode.hasFocus, isTrue);
      // Muted first, so a wrongly-triggered hold (which would unmute) is visible rather than hidden behind the default.
      await controller.toggleMicrophone();
      await tester.pumpAndSettle();
      expect(controller.state.microphoneEnabled, isFalse);

      /// "very" (v, e, r, y), as real hardware key events, checked right
      /// after V's own key-down rather than only once the whole word has
      /// been typed: a down that wrongly opened the mic and a later up that
      /// closed it again would cancel out and read as never having happened
      /// if only the word's final state were asserted.
      var checkedVDown = false;
      for (final key in [
        LogicalKeyboardKey.keyV,
        LogicalKeyboardKey.keyE,
        LogicalKeyboardKey.keyR,
        LogicalKeyboardKey.keyY,
      ]) {
        await tester.sendKeyDownEvent(key);
        await tester.pump();
        if (key == LogicalKeyboardKey.keyV) {
          expect(
            controller.state.microphoneEnabled,
            isFalse,
            reason: 'the V key-down alone must not open the mic',
          );
          checkedVDown = true;
        }
        await tester.sendKeyUpEvent(key);
        await tester.pump();
      }
      expect(checkedVDown, isTrue);

      expect(
        controller.state.microphoneEnabled,
        isFalse,
        reason: 'typing the letter V into the composer must not open the mic',
      );
      await controller.leave();
    },
  );

  testWidgets('a global key opens the mic once the window has lost focus', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final composerNode = FocusNode();
    addTearDown(composerNode.dispose);
    // Blurred as the window reports it, with the embedder still saying resumed.
    final controller = await connect(
      tester,
      TextField(focusNode: composerNode, autofocus: true),
      extraOverrides: [windowLifecycle(windowIn(AppLifecycleState.inactive))],
    );
    harness.container.read(composerFocusNodeProvider.notifier).state =
        composerNode;
    await tester.pump();
    await controller.toggleMicrophone();
    await tester.pump();
    expect(controller.state.microphoneEnabled, isFalse);

    harness.container.read(pushToTalkGateProvider).press(HoldSource.global);
    await tester.pump();

    expect(controller.state.microphoneEnabled, isTrue);
    harness.container.read(pushToTalkGateProvider).release(HoldSource.global);
    await tester.pump();
    await controller.leave();
  });

  testWidgets('a blur only the window reports ends an in-window hold', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final events = StreamController<DesktopWindowEventKind>.broadcast(
      sync: true,
    );
    addTearDown(events.close);
    final controller = await connect(
      tester,
      const SizedBox.shrink(),
      extraOverrides: [
        appLifecycleProvider.overrideWith(
          (ref) =>
              AppLifecycleNotifier(mobile: false, windowEvents: events.stream),
        ),
      ],
    );
    await controller.toggleMicrophone();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.pump();
    expect(controller.state.microphoneEnabled, isTrue);

    // A pop-out taking focus: the embedder never leaves resumed, and the key-up goes elsewhere.
    events.add(DesktopWindowEventKind.blur);
    await tester.pump();

    expect(WidgetsBinding.instance.lifecycleState, AppLifecycleState.resumed);
    expect(
      controller.state.microphoneEnabled,
      isFalse,
      reason: 'a hold left down in an unfocused window is an open microphone',
    );
    await controller.leave();
  });

  testWidgets('losing composer focus mid-hold still releases cleanly', (
    tester,
  ) async {
    final composerNode = FocusNode();
    addTearDown(composerNode.dispose);
    final other = FocusNode();
    addTearDown(other.dispose);
    final controller = await connect(
      tester,
      Column(
        children: [
          TextField(focusNode: composerNode),
          Focus(focusNode: other, autofocus: true, child: const SizedBox()),
        ],
      ),
    );
    harness.container.read(composerFocusNodeProvider.notifier).state =
        composerNode;
    await tester.pumpAndSettle();
    expect(composerNode.hasFocus, isFalse);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.pump();
    expect(controller.state.microphoneEnabled, isTrue);

    composerNode.requestFocus();
    await tester.pumpAndSettle();

    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.pump();
    expect(
      controller.state.microphoneEnabled,
      isFalse,
      reason:
          'a hold this listener started must always be releasable, even if '
          'focus moved to the composer in between',
    );
    await controller.leave();
  });

  testWidgets('the key does not open the mic while the app lock is up', (
    tester,
  ) async {
    final controller = await connect(
      tester,
      const SizedBox.shrink(),
      extraOverrides: [
        appLockControllerProvider.overrideWith(_AlwaysLocked.new),
      ],
    );
    await controller.toggleMicrophone();
    await tester.pumpAndSettle();
    expect(controller.state.microphoneEnabled, isFalse);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.pump();

    expect(
      controller.state.microphoneEnabled,
      isFalse,
      reason: 'a locked app must not let a key open the microphone',
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await controller.leave();
  });
}
