// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// OS-level hotkeys driving the same push-to-talk and mute paths as the
/// in-window handlers, and never leaving the microphone stuck open.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/global_hotkeys_controller.dart';
import 'package:slimm_app/src/features/voice/providers/push_to_talk_gate.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/global_hotkey_rows.dart';
import 'package:slimm_app/src/features/voice/widgets/push_to_talk_listener.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

class FakeHotkeySource implements GlobalHotkeySource {
  FakeHotkeySource({
    this.probeResult = const GlobalHotkeyAvailability.available(
      'Works when slim-m is in the background.',
    ),
  });

  final GlobalHotkeyAvailability probeResult;
  final binds = <List<GlobalHotkeyId>>[];
  final _events = StreamController<GlobalHotkeyEvent>.broadcast();

  @override
  Stream<GlobalHotkeyEvent> get events => _events.stream;

  @override
  Future<GlobalHotkeyAvailability> probe() async => probeResult;

  @override
  Future<GlobalHotkeyAvailability> bind(
    List<GlobalHotkeyBinding> bindings,
  ) async {
    binds.add([for (final b in bindings) b.id]);
    return probeResult;
  }

  void send(GlobalHotkeyId id, GlobalHotkeyPhase phase) =>
      _events.add(GlobalHotkeyEvent(id, phase));

  void lose() => _events.add(const GlobalHotkeyEvent.lost());

  @override
  Future<void> dispose() async {}
}

void main() {
  final harness = VoiceHarness();

  setUp(
    () => SharedPreferences.setMockInitialValues({
      'slimm.voice.push_to_talk_enabled': true,
    }),
  );
  tearDown(harness.dispose);

  Future<({VoiceController voice, FakeHotkeySource source})> connect(
    WidgetTester tester, {
    FakeHotkeySource? source,
  }) async {
    final hotkeys = source ?? FakeHotkeySource();
    final session = FakeSession();
    final controller = harness.controllerWith(
      session,
      voiceApi(),
      extraOverrides: [globalHotkeySourceProvider.overrideWithValue(hotkeys)],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: harness.container,
        child: const MaterialApp(
          home: PushToTalkListener(child: Scaffold(body: SizedBox())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    await tester.pumpAndSettle();
    await controller.toggleMicrophone();
    await tester.pumpAndSettle();
    expect(controller.state.microphoneEnabled, isFalse);
    return (voice: controller, source: hotkeys);
  }

  Future<void> global(
    WidgetTester tester,
    FakeHotkeySource source,
    GlobalHotkeyId id,
    GlobalHotkeyPhase phase,
  ) async {
    source.send(id, phase);
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a global press opens the mic and the release closes it', (
    tester,
  ) async {
    final c = await connect(tester);
    await global(
      tester,
      c.source,
      GlobalHotkeyId.pushToTalk,
      GlobalHotkeyPhase.pressed,
    );
    expect(c.voice.state.microphoneEnabled, isTrue);

    await global(
      tester,
      c.source,
      GlobalHotkeyId.pushToTalk,
      GlobalHotkeyPhase.released,
    );
    expect(c.voice.state.microphoneEnabled, isFalse);
    await c.voice.leave();
  });

  testWidgets('both sources firing for one press open once and close once', (
    tester,
  ) async {
    final c = await connect(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await global(
      tester,
      c.source,
      GlobalHotkeyId.pushToTalk,
      GlobalHotkeyPhase.pressed,
    );
    expect(c.voice.state.microphoneEnabled, isTrue);

    await global(
      tester,
      c.source,
      GlobalHotkeyId.pushToTalk,
      GlobalHotkeyPhase.released,
    );
    expect(
      c.voice.state.microphoneEnabled,
      isTrue,
      reason: 'the key is still down in the window',
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.pump();
    expect(c.voice.state.microphoneEnabled, isFalse);
    await c.voice.leave();
  });

  testWidgets('a repeated global press does not stack holds', (tester) async {
    final c = await connect(tester);
    for (var i = 0; i < 3; i++) {
      await global(
        tester,
        c.source,
        GlobalHotkeyId.pushToTalk,
        GlobalHotkeyPhase.pressed,
      );
    }
    await global(
      tester,
      c.source,
      GlobalHotkeyId.pushToTalk,
      GlobalHotkeyPhase.released,
    );
    expect(c.voice.state.microphoneEnabled, isFalse);
    await c.voice.leave();
  });

  testWidgets('losing capture mid-hold closes the mic', (tester) async {
    final c = await connect(tester);
    await global(
      tester,
      c.source,
      GlobalHotkeyId.pushToTalk,
      GlobalHotkeyPhase.pressed,
    );
    expect(c.voice.state.microphoneEnabled, isTrue);

    c.source.lose();
    await tester.pump();
    await tester.pump();
    expect(c.voice.state.microphoneEnabled, isFalse);
    expect(harness.container.read(globalHotkeysProvider)!.available, isFalse);
    await c.voice.leave();
  });

  testWidgets(
    'losing window focus ends an in-window hold but not a global one',
    (tester) async {
      final c = await connect(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
      await tester.pump();
      expect(c.voice.state.microphoneEnabled, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(
        c.voice.state.microphoneEnabled,
        isFalse,
        reason: 'the window will never see this key-up',
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);

      await global(
        tester,
        c.source,
        GlobalHotkeyId.pushToTalk,
        GlobalHotkeyPhase.pressed,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(c.voice.state.microphoneEnabled, isTrue);
      await global(
        tester,
        c.source,
        GlobalHotkeyId.pushToTalk,
        GlobalHotkeyPhase.released,
      );
      expect(c.voice.state.microphoneEnabled, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await c.voice.leave();
    },
  );

  testWidgets(
    'a key-up seen by the window ends a global hold that lost its own',
    (tester) async {
      final c = await connect(tester);
      await global(
        tester,
        c.source,
        GlobalHotkeyId.pushToTalk,
        GlobalHotkeyPhase.pressed,
      );
      expect(c.voice.state.microphoneEnabled, isTrue);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
      await tester.pump();

      expect(c.voice.state.microphoneEnabled, isFalse);
      await c.voice.leave();
    },
  );

  testWidgets('the global mute shortcut toggles the mic once per press', (
    tester,
  ) async {
    final c = await connect(tester);
    await global(
      tester,
      c.source,
      GlobalHotkeyId.toggleMute,
      GlobalHotkeyPhase.pressed,
    );
    expect(c.voice.state.microphoneEnabled, isTrue);
    await global(
      tester,
      c.source,
      GlobalHotkeyId.toggleMute,
      GlobalHotkeyPhase.released,
    );
    expect(c.voice.state.microphoneEnabled, isTrue);
    await c.voice.leave();
  });

  testWidgets('push-to-talk and the call decide what gets registered', (
    tester,
  ) async {
    final c = await connect(tester);
    expect(c.source.binds.last, [
      GlobalHotkeyId.pushToTalk,
      GlobalHotkeyId.toggleMute,
    ]);
    await c.voice.leave();
  });

  group('mute duplicate suppression', () {
    test('the other source within the window is ignored', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      var now = DateTime(2026);
      final gate = PushToTalkGate(
        container.read(Provider((ref) => ref)),
        now: () => now,
      );
      var toggles = 0;
      gate.toggleMute(HoldSource.inWindow, () => toggles++);
      now = now.add(const Duration(milliseconds: 20));
      gate.toggleMute(HoldSource.global, () => toggles++);
      expect(toggles, 1);

      now = now.add(muteDuplicateWindow);
      gate.toggleMute(HoldSource.global, () => toggles++);
      expect(toggles, 2, reason: 'a later press is a new press');
    });

    test('the same source pressing twice quickly is two toggles', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final now = DateTime(2026);
      final gate = PushToTalkGate(
        container.read(Provider((ref) => ref)),
        now: () => now,
      );
      var toggles = 0;
      gate.toggleMute(HoldSource.global, () => toggles++);
      gate.toggleMute(HoldSource.global, () => toggles++);
      expect(toggles, 2);
    });
  });

  group('settings status line', () {
    Future<void> pumpLine(
      WidgetTester tester,
      GlobalHotkeySource? source,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [globalHotkeySourceProvider.overrideWithValue(source)],
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: const Scaffold(body: MuteShortcutRows()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows the source message when capture works', (tester) async {
      await pumpLine(tester, FakeHotkeySource());
      expect(
        find.text('Works when slim-m is in the background.'),
        findsOneWidget,
      );
      expect(find.text('Mute shortcut'), findsOneWidget);
    });

    testWidgets('shows why it falls back when the source refuses', (
      tester,
    ) async {
      await pumpLine(
        tester,
        FakeHotkeySource(
          probeResult: const GlobalHotkeyAvailability.unavailable(
            'This desktop has no background shortcuts.',
          ),
        ),
      );
      expect(
        find.text('This desktop has no background shortcuts.'),
        findsOneWidget,
      );
    });

    testWidgets('says so when the platform has no source at all', (
      tester,
    ) async {
      await pumpLine(tester, null);
      expect(find.text(noGlobalCaptureMessage), findsOneWidget);
    });
  });
}
