// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call dock's camera options menu with three webcams, the picked one
/// marked, desktop and phone, in both themes. PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/screens/voice_call_dock.dart';
import 'package:slimm_app/src/features/voice/widgets/camera_menu_preview.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import '../features/voice/voice_call_controls_harness.dart';
import '../ui_snapshot_support.dart';

const _cameraOn = VoiceFlags(
  state: VoiceSessionState.connected,
  cameraEnabled: true,
);

InertSession _session() => InertSession()
  ..cameraNeedsSelection = true
  ..cameraDeviceList = const [
    CameraDevice(id: 'a', label: 'EMEET SmartCam C960 4K'),
    CameraDevice(id: 'b', label: 'Integrated Camera'),
    CameraDevice(id: 'c', label: 'OBS Virtual Camera'),
  ];

void main() {
  setUpAll(loadRealFonts);

  const sizes = {'phone': Size(390, 844), 'desktop': Size(1280, 800)};
  for (final entry in sizes.entries) {
    testWidgets('camera menu at ${entry.key} (dark+light)', (tester) async {
      SharedPreferences.setMockInitialValues({
        'slimm.voice.camera_device_id': 'b',
      });
      tester.view.physicalSize = entry.value;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          voiceControllerProvider.overrideWith(
            (ref) => VoiceController(ref, session: _session()),
          ),
        ],
      );
      addTearDown(container.dispose);
      Widget build(String theme) => UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: snapshotBoundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: snapshotThemeData(theme),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: VoiceCallDock(
                  controller: container.read(voiceControllerProvider.notifier),
                  voice: _cameraOn,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(build('dark'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      if (entry.key == 'phone') {
        await tester.longPress(
          find.bySemanticsLabel(RegExp('^Turn off camera')),
        );
      } else {
        await tester.tap(find.byTooltip('Camera options'));
      }
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await checkDarkThenLight(tester, build, (theme) async {
        final slot = tester.getRect(find.byKey(cameraMenuPreviewKey));
        final label = tester.getCenter(find.text('No preview'));
        expect((label - slot.center).distance, lessThan(1));
        await writeSnapshot(tester, 'camera-menu-${entry.key}-$theme');
        expect(tester.takeException(), isNull);
      });
    });
  }
}
