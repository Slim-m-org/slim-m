// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call overlay toggle as an OS-level hotkey: registered in a call where
/// the overlay can be hosted, flipping "Show call overlay", and following a
/// remap.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_overlay_controller.dart';
import 'package:slimm_app/src/features/screen_overlay/widgets/call_overlay_shortcut.dart';
import 'package:slimm_app/src/features/voice/providers/call_mark_actions.dart';
import 'package:slimm_app/src/features/voice/providers/global_hotkeys_controller.dart';
import 'package:slimm_app/src/features/voice/providers/push_to_talk_gate.dart';
import 'package:slimm_app/src/features/voice/providers/shortcut_overrides.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/push_to_talk_listener.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/async_wait.dart';
import 'global_hotkeys_harness.dart';
import 'voice_controller_harness.dart';

void main() {
  final harness = VoiceHarness();

  setUp(
    () => SharedPreferences.setMockInitialValues({
      'slimm.voice.push_to_talk_enabled': true,
      'slimm.voice.call_keybinds_enabled': true,
    }),
  );
  tearDown(harness.dispose);

  late Map<ShortcutActivator, VoidCallback> inWindow;

  Future<({VoiceController voice, FakeHotkeySource source})> connect(
    WidgetTester tester, {
    required bool overlayHosted,
    List<Override> extra = const [],
  }) async {
    final hotkeys = FakeHotkeySource();
    final session = FakeSession();
    final controller = harness.controllerWith(
      session,
      voiceApi(),
      extraOverrides: [
        globalHotkeySourceProvider.overrideWithValue(hotkeys),
        screenOverlaySupportedProvider.overrideWithValue(overlayHosted),
        ...extra,
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: harness.container,
        child: MaterialApp(
          home: PushToTalkListener(
            child: Consumer(
              builder: (context, ref, _) {
                ref.watch(shortcutOverridesProvider);
                inWindow = callOverlayShortcutBindings(ref);
                return const Scaffold(body: TextField());
              },
            ),
          ),
        ),
      ),
    );
    await pumpFrames(tester);
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    await pumpFrames(tester);
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

  testWidgets(
    'the overlay toggle is registered in a call where it can be hosted',
    (tester) async {
      final c = await connect(tester, overlayHosted: true);
      expect(c.source.binds.last, [
        GlobalHotkeyId.pushToTalk,
        GlobalHotkeyId.toggleMute,
        GlobalHotkeyId.toggleDeafen,
        GlobalHotkeyId.markCall,
        GlobalHotkeyId.toggleCallOverlay,
      ]);
      final chord = c.source.chords.last.last;
      expect(
        (chord.key, chord.ctrl, chord.shift),
        (LogicalKeyboardKey.keyO, true, true),
      );
      await c.voice.leave();
    },
  );

  testWidgets('the global mark hotkey runs the one mark action per press', (
    tester,
  ) async {
    final marks = <int>[];
    final c = await connect(
      tester,
      overlayHosted: false,
      extra: [
        callMarkActionsProvider.overrideWith(
          (ref) => _CountingMarks(ref, marks),
        ),
      ],
    );
    await global(
      tester,
      c.source,
      GlobalHotkeyId.markCall,
      GlobalHotkeyPhase.pressed,
    );
    await global(
      tester,
      c.source,
      GlobalHotkeyId.markCall,
      GlobalHotkeyPhase.released,
    );
    expect(marks, [1]);
    harness.container
        .read(pushToTalkGateProvider)
        .markCall(
          HoldSource.inWindow,
          () =>
              unawaited(harness.container.read(callMarkActionsProvider).mark()),
        );
    expect(marks, [1], reason: 'the window shortcut saw the same press');
    await c.voice.leave();
  });

  testWidgets('the global overlay shortcut flips the setting once per press', (
    tester,
  ) async {
    final c = await connect(tester, overlayHosted: true);
    bool shown() => harness.container
        .read(voiceSettingsControllerProvider)
        .callOverlayEnabled;
    expect(shown(), isFalse);
    await global(
      tester,
      c.source,
      GlobalHotkeyId.toggleCallOverlay,
      GlobalHotkeyPhase.pressed,
    );
    expect(shown(), isTrue);
    await global(
      tester,
      c.source,
      GlobalHotkeyId.toggleCallOverlay,
      GlobalHotkeyPhase.released,
    );
    expect(shown(), isTrue);
    await global(
      tester,
      c.source,
      GlobalHotkeyId.toggleCallOverlay,
      GlobalHotkeyPhase.pressed,
    );
    expect(shown(), isFalse);
    await c.voice.leave();
  });

  testWidgets('a remapped overlay chord is registered again', (tester) async {
    final c = await connect(tester, overlayHosted: true);
    await harness.container
        .read(shortcutOverridesProvider.notifier)
        .set(
          AppAction.toggleCallOverlay,
          const SingleActivator(LogicalKeyboardKey.keyU, alt: true),
        );
    await tester.pump();
    await tester.pump();
    final overlay = c.source.chords.last.last;
    expect(
      (overlay.key, overlay.alt, overlay.ctrl),
      (LogicalKeyboardKey.keyU, true, false),
    );
    await c.voice.leave();
  });

  testWidgets('one press seen in the window and system-wide flips it once', (
    tester,
  ) async {
    final c = await connect(tester, overlayHosted: true);
    inWindow.values.single();
    await global(
      tester,
      c.source,
      GlobalHotkeyId.toggleCallOverlay,
      GlobalHotkeyPhase.pressed,
    );
    expect(
      harness.container
          .read(voiceSettingsControllerProvider)
          .callOverlayEnabled,
      isTrue,
    );
    await c.voice.leave();
  });

  test('the overlay toggle dedupes across sources on its own clock', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    var now = DateTime(2026);
    final gate = PushToTalkGate(
      container.read(Provider((ref) => ref)),
      now: () => now,
    );
    var overlays = 0;
    var mutes = 0;
    gate.toggleCallOverlay(HoldSource.inWindow, () => overlays++);
    gate.toggleMute(HoldSource.global, () => mutes++);
    gate.toggleCallOverlay(HoldSource.global, () => overlays++);
    expect((overlays, mutes), (1, 1));
    now = now.add(muteDuplicateWindow);
    gate.toggleCallOverlay(HoldSource.global, () => overlays++);
    expect(overlays, 2, reason: 'a later press is a new press');
  });
}

class _CountingMarks extends CallMarkActions {
  _CountingMarks(super.ref, this.calls);

  final List<int> calls;

  @override
  Future<String?> mark({String? note, String? id}) async {
    calls.add(calls.length + 1);
    return null;
  }
}
