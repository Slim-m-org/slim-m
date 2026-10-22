// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call dock with the "music while alone" button, off and on, at phone and
/// a narrow window in both themes. PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1; otherwise this asserts the dock lays out cleanly.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/screens/voice_call_dock.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import 'ui_snapshot_support.dart';
import 'features/voice/voice_call_controls_harness.dart' show InertSession;

VoiceParticipant _me() => const VoiceParticipant(
  identity: 'me',
  name: 'me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: false,
);

void main() {
  setUpAll(loadRealFonts);

  const sizes = {'phone': Size(390, 230), 'narrow': Size(560, 160)};
  for (final theme in const ['dark', 'light']) {
    for (final entry in sizes.entries) {
      for (final on in const [false, true]) {
        final phone = entry.key == 'phone';
        testWidgets('dock music ${on ? 'on' : 'off'} ${entry.key} ($theme)', (
          tester,
        ) async {
          SharedPreferences.setMockInitialValues({
            'slimm.voice.hold_music_enabled': on,
          });
          tester.view.physicalSize = entry.value;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          final container = ProviderContainer(
            overrides: [
              keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
              voiceControllerProvider.overrideWith(
                (ref) => VoiceController(ref, session: InertSession()),
              ),
              voiceParticipantsProvider.overrideWithValue([_me()]),
            ],
          )..read(preferencesProvider);
          addTearDown(container.dispose);
          final dark = theme == 'dark';
          final tokens = dark ? AppTokens.dark : AppTokens.light;
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: RepaintBoundary(
                key: snapshotBoundary,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: buildTheme(
                    dark ? Brightness.dark : Brightness.light,
                    tokens,
                  ),
                  home: Scaffold(
                    body: Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.s16),
                        child: AppTouchTargets(
                          enabled: phone,
                          child: VoiceCallDock(
                            controller: container.read(
                              voiceControllerProvider.notifier,
                            ),
                            voice: const VoiceFlags(
                              state: VoiceSessionState.connected,
                            ),
                            canvasChannelId: 'c1',
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await writeSnapshot(
            tester,
            'dock-music-${on ? 'on' : 'off'}-${entry.key}-$theme',
          );
        });
      }
    }
  }
}
