// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call overlay toggle as an OS-level hotkey: registered in a call where
/// the overlay can be hosted, flipping "Show call overlay", and following a
/// remap.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_overlay_controller.dart';
import 'package:slimm_app/src/features/voice/providers/global_hotkeys_controller.dart';
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
    }),
  );
  tearDown(harness.dispose);

  Future<({VoiceController voice, FakeHotkeySource source})> connect(
    WidgetTester tester, {
    required bool overlayHosted,
  }) async {
    final hotkeys = FakeHotkeySource();
    final session = FakeSession();
    final controller = harness.controllerWith(
      session,
      voiceApi(),
      extraOverrides: [
        globalHotkeySourceProvider.overrideWithValue(hotkeys),
        screenOverlaySupportedProvider.overrideWithValue(overlayHosted),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: harness.container,
        child: const MaterialApp(
          home: PushToTalkListener(child: Scaffold(body: TextField())),
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
}
