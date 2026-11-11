// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call whose camera would not turn on (permission denied, none detected,
/// failed to start) and the Voice settings video card, desktop and phone, in
/// both themes. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/voice_camera_failure.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/video_quality_sections.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import '../features/voice/voice_settings_screen_harness.dart';
import '../features/voice/voice_snapshot_fixtures.dart';
import '../ui_snapshot_support.dart';

const _failures = {
  'denied': CameraFailureReason.permissionDenied,
  'none': CameraFailureReason.noCameraDetected,
  'failed': CameraFailureReason.cameraUnavailable,
};

void main() {
  setUpAll(loadRealFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final entry in _failures.entries) {
    for (final size in const {
      'desktop': 'desktop',
      'phone': 'phone-portrait',
    }.entries) {
      testWidgets('camera ${entry.key} on ${size.key}', (tester) async {
        final state = gridCallState.copyWith(
          error: cameraFailureMessage(
            true,
            CameraFailure(StateError('x'), entry.value),
          ),
        );
        await renderSurface(
          tester,
          '/channels/c-main',
          size.value,
          darkAndLight,
          'camera-${entry.key}-${size.key}-$darkAndLight',
          overrides: [
            voiceControllerProvider.overrideWith(
              (ref) => SnapshotVoiceController(ref, state),
            ),
          ],
          allowNoText: true,
        );
      });
    }
  }

  for (final theme in const ['dark', 'light']) {
    for (final size in const {
      'phone': Size(390, 844),
      'desktop': Size(1280, 800),
    }.entries) {
      testWidgets('video card at ${size.key} ($theme)', (tester) async {
        tester.view.physicalSize = size.value;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final container = ProviderContainer(
          overrides: [
            keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
            voiceControllerProvider.overrideWith(
              (ref) => VoiceController(ref, session: FakeSettingsSession()),
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
                  body: SingleChildScrollView(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: VideoQualitySection(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await writeSnapshot(tester, 'camera-video-card-${size.key}-$theme');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
