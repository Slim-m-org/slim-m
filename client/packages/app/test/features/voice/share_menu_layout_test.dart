// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The share menu reads in order, drops no label, and offers only the resolutions a screen can send.
library;

import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_overlay_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/share_resolution_support.dart';
import 'package:slimm_app/src/features/voice/widgets/video_quality_sections.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

const _sharing = VoiceFlags(
  state: VoiceSessionState.connected,
  screenSharing: true,
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Screen share options'));
  await _settle(tester);
}

bool _enabled(WidgetTester tester, String label) =>
    tester
        .getSemantics(find.bySemanticsLabel(label))
        .flagsCollection
        .isEnabled ==
    Tristate.isTrue;

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('stop sharing comes last and is wide enough for its labels', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpControls(
      tester,
      _sharing,
      session: InertSession(needsSource: true),
      extraOverrides: [screenOverlaySupportedProvider.overrideWithValue(true)],
    );
    await _open(tester);

    final order = [
      'Sharing',
      '720p',
      '60 fps',
      'Viewers can draw',
      'Stop sharing',
    ];
    final tops = [
      for (final label in order) tester.getTopLeft(find.text(label).first).dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()), reason: '$order');
    final span =
        tester.getTopRight(find.text('2160p')).dx -
        tester.getTopLeft(find.text('720p')).dx;
    expect(span, greaterThan(200), reason: 'tiles share a wide menu');
    expect(find.text('Stop sharing'), findsOneWidget);
    handle.dispose();
  });

  testWidgets(
    'a resolution above every screen is off and the saved one falls back',
    (tester) async {
      final handle = tester.ensureSemantics();
      SharedPreferences.setMockInitialValues({
        'slimm.voice.screen_share_quality': '2160p30',
      });
      final container = await pumpControls(
        tester,
        _sharing,
        extraOverrides: [
          shareDisplayHeightsProvider.overrideWithValue([1080, 1440]),
        ],
      );
      container.read(voiceSettingsControllerProvider);
      await _settle(tester);
      await _open(tester);

      expect(_enabled(tester, '1440p'), isTrue);
      expect(_enabled(tester, '2160p'), isFalse);
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('1440p'))
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );

      await tester.tap(find.text('2160p'));
      await _settle(tester);
      expect(
        container
            .read(voiceSettingsControllerProvider)
            .screenShareQuality
            .resolution,
        ScreenShareResolution.p2160,
        reason: 'the stored choice is untouched, only the shown one falls back',
      );
      handle.dispose();
    },
  );

  testWidgets('the settings row disables the same tiers and says why', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shareDisplayHeightsProvider.overrideWithValue([1080]),
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          voiceControllerProvider.overrideWith(
            (ref) => VoiceController(ref, session: InertSession()),
          ),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: const Scaffold(
            body: SingleChildScrollView(child: VideoQualitySection()),
          ),
        ),
      ),
    );
    await _settle(tester);

    expect(
      find.textContaining('Your largest display is 1080p'),
      findsOneWidget,
    );
    await tester.tap(find.text('2160p'));
    await _settle(tester);
    expect(
      tester.widget<Tooltip>(
        find
            .ancestor(
              of: find.text('2160p'),
              matching: find.byWidgetPredicate(
                (w) =>
                    w is Tooltip && w.message == shareResolutionTooHighReason,
              ),
            )
            .first,
      ),
      isNotNull,
    );
  });
}
