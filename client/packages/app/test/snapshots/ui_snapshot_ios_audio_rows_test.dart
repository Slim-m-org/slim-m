// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The iPhone audio output row and the badges-off row, at phone and desktop width.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/personal_status_sections.dart';
import 'package:slimm_app/src/features/voice/providers/speaker_route_provider.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/audio_device_section.dart';
import 'package:slimm_app/src/providers/app_badge_sync.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import '../features/voice/voice_settings_screen_harness.dart';
import '../support/mid_flight_capture.dart';
import '../ui_snapshot_support.dart';

const _badgeChannel = MethodChannel('top.npcserver.slimm/app_badge');

Widget _nativeButton() => const Center(child: Icon(AppIcons.speaker, size: 22));

Future<void> _render(
  WidgetTester tester,
  Size size,
  String name,
  Widget body,
  List<Override> overrides,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        ...overrides,
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: RepaintBoundary(
            key: snapshotBoundary,
            child: ColoredBox(
              color: AppTokens.dark.surfaceBase,
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: body,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await expectSettled(tester, name);
  await writeSnapshot(tester, name);
}

void main() {
  setUpAll(loadRealFonts);

  for (final entry in const {
    'phone': Size(390, 844),
    'desktop': Size(1280, 800),
  }.entries) {
    testWidgets('iOS audio output row at ${entry.key}', (tester) async {
      await _render(
        tester,
        entry.value,
        'ios-audio-output-${entry.key}',
        AudioDeviceSection(ios: true, routePicker: _nativeButton()),
        [
          voiceControllerProvider.overrideWith(
            (ref) => VoiceController(
              ref,
              session: FakeSettingsSession(
                supportsAudioInputSelection: false,
                supportsAudioOutputSelection: false,
              ),
            ),
          ),
          speakerRouteProvider.overrideWithValue(
            SpeakerRoute(supported: true, apply: (_) async {}),
          ),
        ],
      );
    });

    testWidgets('badges-off row at ${entry.key}', (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_badgeChannel, (_) async => false);
      addTearDown(
        () => messenger.setMockMethodCallHandler(_badgeChannel, null),
      );
      await _render(
        tester,
        entry.value,
        'ios-badges-off-${entry.key}',
        const NotificationsSection(hasPushChannel: false),
        [
          appBadgeChannelProvider.overrideWithValue(
            AppBadgeChannel(isIOS: true),
          ),
        ],
      );
    });
  }
}
