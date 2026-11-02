// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call dock's mic and screen share menus on a short desktop window and
/// a phone, in both themes. PNGs are written only under SLIMM_UI_SNAPSHOTS=1;
/// otherwise this asserts the menus open without overflow.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_overlay_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/screens/voice_call_dock.dart';
import 'package:slimm_app/src/features/voice/widgets/share_resolution_support.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import '../features/voice/voice_call_controls_harness.dart';
import '../ui_snapshot_support.dart';

const _sharing = VoiceFlags(
  state: VoiceSessionState.connected,
  screenSharing: true,
);

InertSession _session() => InertSession(
  needsSource: true,
  supportsInputGate: true,
  supportsAudioInputSelection: true,
  supportsAudioOutputSelection: true,
  audioInputDeviceList: const [
    AudioDevice(id: 'a', label: 'Arctis Nova Pro Wireless Mono'),
    AudioDevice(id: 'b', label: 'EMEET SmartCam C960 4K Analog Stereo'),
    AudioDevice(id: 'c', label: 'Clean Mic'),
  ],
  audioOutputDeviceList: const [
    AudioDevice(id: 'o', label: 'Arctis Nova Pro Wireless Analog Stereo'),
    AudioDevice(id: 'p', label: 'Main'),
  ],
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  setUpAll(loadRealFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const sizes = {'phone': Size(390, 700), 'desktop': Size(1100, 640)};
  for (final theme in const ['dark', 'light']) {
    for (final entry in sizes.entries) {
      for (final menu in const ['mic', 'share']) {
        testWidgets('$menu menu at ${entry.key} ($theme)', (tester) async {
          tester.view.physicalSize = entry.value;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          final container = ProviderContainer(
            overrides: [
              keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
              screenOverlaySupportedProvider.overrideWithValue(true),
              shareDisplayHeightsProvider.overrideWithValue([1080, 1440]),
              voiceControllerProvider.overrideWith(
                (ref) => VoiceController(ref, session: _session()),
              ),
            ],
          );
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
                  home: Scaffold(
                    body: Align(
                      alignment: Alignment.bottomCenter,
                      child: VoiceCallDock(
                        controller: container.read(
                          voiceControllerProvider.notifier,
                        ),
                        voice: _sharing,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump();
          final phone = entry.key == 'phone';
          final label = menu == 'mic'
              ? 'Microphone options'
              : 'Screen share options';
          if (phone) {
            await tester.longPress(
              find.bySemanticsLabel(
                RegExp(
                  menu == 'mic'
                      ? '^(Mute|Unmute)'
                      : '^(Stop sharing|You are sharing)',
                ),
              ),
            );
          } else {
            await tester.tap(find.byTooltip(label));
          }
          await _settle(tester);
          await writeSnapshot(tester, 'call-$menu-menu-${entry.key}-$theme');
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
