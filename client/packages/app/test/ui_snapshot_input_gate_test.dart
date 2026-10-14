// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The microphone card on a host with the native input gate, in a call with
/// a live level above the line, at phone and desktop width in both themes.
/// The PNGs are written only under SLIMM_UI_SNAPSHOTS=1; otherwise this
/// asserts the card lays out without overflow.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/screens/voice_settings_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'ui_snapshot_support.dart';
import 'voice_settings_screen_harness.dart';

void main() {
  setUpAll(loadRealFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const sizes = {'phone': Size(390, 900), 'desktop': Size(900, 700)};
  for (final theme in const ['dark', 'light']) {
    for (final entry in sizes.entries) {
      testWidgets('input gate meter at ${entry.key} ($theme)', (tester) async {
        tester.view.physicalSize = entry.value;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final session = FakeSession(supportsInputGate: true);
        final container = ProviderContainer(
          overrides: [
            keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
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
        session.inputGateController.add(
          const InputGateReading(levelDb: -28, voice: true),
        );
        await tester.pumpAndSettle();
        expect(find.text('Input sensitivity'), findsOneWidget);
        await writeSnapshot(tester, 'input-gate-${entry.key}-$theme');
        expect(tester.takeException(), isNull);
        await controller.leave();
      });
    }
  }
}
