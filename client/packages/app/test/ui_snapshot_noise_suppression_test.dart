// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The noise suppression picker with Strongest chosen and not running, at
/// phone and desktop width in both themes. The PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1; otherwise this asserts the row lays out.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/screens/voice_settings_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import 'features/voice/voice_settings_screen_harness.dart';
import 'support/fake_mic_preview.dart' show quietMicPreview;
import 'ui_snapshot_support.dart';

void main() {
  setUpAll(loadRealFonts);
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'slimm.voice.noise_suppression': 'strongest',
    }),
  );

  const sizes = {'phone': Size(390, 900), 'desktop': Size(1280, 800)};
  for (final theme in const ['dark', 'light']) {
    for (final entry in sizes.entries) {
      testWidgets('noise suppression Strongest at ${entry.key} ($theme)', (
        tester,
      ) async {
        tester.view.physicalSize = entry.value;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final session = FakeSession(supportsInputGate: true);
        final container = ProviderContainer(
          overrides: [
            keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
            quietMicPreview,
            sessionProvider.overrideWithValue(SessionStore(tokens: tokens)),
            apiProvider.overrideWith((ref) {
              final api = SlimmApi(
                baseUrl: Uri.parse('http://localhost:8080'),
                session: ref.watch(sessionProvider),
                httpClient: voiceTokenClient(),
              );
              ref.onDispose(api.close);
              return api;
            }),
            voiceControllerProvider.overrideWith(
              (ref) => VoiceController(ref, session: session),
            ),
          ],
        )..read(preferencesProvider);
        addTearDown(container.dispose);
        final dark = theme == 'dark';
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: RepaintBoundary(
              key: snapshotBoundary,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: dark
                    ? buildTheme(Brightness.dark, AppTokens.dark)
                    : buildTheme(Brightness.light, AppTokens.light),
                home: const Scaffold(
                  body: SingleChildScrollView(child: VoiceSettingsBody()),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final controller = container.read(voiceControllerProvider.notifier);
        await controller.join('channel-1');
        await tester.pumpAndSettle();
        for (var i = 0; i < kStrongInactivePolls; i++) {
          session.inputGateController.add(
            const InputGateReading(
              levelDb: -40,
              voice: false,
              strongActive: true,
            ),
          );
        }
        await tester.pumpAndSettle();
        expect(find.text('Strongest'), findsOneWidget);
        expect(
          find.text("Strongest isn't running on this mic."),
          findsOneWidget,
        );
        await writeSnapshot(tester, 'noise-strongest-${entry.key}-$theme');
        expect(tester.takeException(), isNull);
        await controller.leave();
      });
    }
  }
}
