// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Voice & screen share pane, with the hold music row, at phone and
/// desktop width in both themes. The PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1; otherwise this asserts the pane lays out without
/// overflow.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/screens/voice_settings_screen.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_toggle_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import 'support/fake_mic_preview.dart' show quietMicPreview;
import 'ui_snapshot_support.dart';
import 'features/voice/voice_settings_screen_harness.dart' show FakeSession;

void main() {
  setUpAll(loadRealFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const sizes = {'phone': Size(390, 2200), 'desktop': Size(900, 1500)};
  for (final theme in const ['dark', 'light']) {
    for (final entry in sizes.entries) {
      testWidgets('hold music row at ${entry.key} ($theme)', (tester) async {
        tester.view.physicalSize = entry.value;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final container = ProviderContainer(
          overrides: [
            keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
            quietMicPreview,
            voiceControllerProvider.overrideWith(
              (ref) => VoiceController(ref, session: FakeSession()),
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
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is SettingsToggleRow &&
                w.semanticLabel == 'Play hold music while alone in a call',
          ),
          findsOneWidget,
        );
        await writeSnapshot(tester, 'hold-music-${entry.key}-$theme');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
