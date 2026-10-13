// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Video quality choices reach the session, persist, and are reachable from
/// the in-call share menu as well as Voice settings.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/voice_flags.dart';
import 'package:slimm_app/src/providers/voice_settings_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

const _connected = VoiceFlags(state: VoiceSessionState.connected);

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('Screen share options'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the share menu sets resolution and frame rate, not camera', (
    tester,
  ) async {
    final container = await pumpControls(tester, _connected);
    await _openMenu(tester);

    expect(find.text('CAMERA QUALITY'), findsNothing);
    await tester.tap(find.text('1440p'));
    await tester.pumpAndSettle();
    await _openMenu(tester);
    await tester.tap(find.text('60 fps'));
    await tester.pumpAndSettle();

    expect(
      container.read(voiceSettingsControllerProvider).screenShareQuality.id,
      '1440p60',
    );
  });

  test('stored pre-split tier names migrate to the pair they meant', () {
    expect(screenShareQualityFromStored('smooth').id, '720p60');
    expect(screenShareQualityFromStored('balanced').id, '1080p30');
    expect(screenShareQualityFromStored('crisp').id, '1440p15');
    expect(screenShareQualityFromStored('1080p60').id, '1080p60');
    expect(screenShareQualityFromStored(null).id, '1080p30');
    expect(screenShareQualityFromStored('junk').id, '1080p30');
  });

  testWidgets('on a phone width the menu is a sheet with both groups', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpControls(tester, _connected);
    expect(find.byTooltip('Screen share options'), findsNothing);
    await tester.longPress(find.bySemanticsLabel(RegExp('^Share a screen')));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    for (final heading in ['Resolution', 'Frame rate']) {
      final box = tester.getRect(find.text(heading.toUpperCase()));
      expect(box.left, greaterThanOrEqualTo(0), reason: heading);
      expect(box.right, lessThanOrEqualTo(390), reason: heading);
    }
  });

  testWidgets('the menu marks the saved resolution and frame rate', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.screen_share_quality': 'crisp',
    });
    final container = await pumpControls(tester, _connected);
    await container.read(preferencesProvider.future);
    container.read(voiceSettingsControllerProvider);
    await tester.pumpAndSettle();
    await _openMenu(tester);

    final state = container.read(voiceSettingsControllerProvider);
    expect(
      state.screenShareQuality,
      ScreenShareQuality(ScreenShareResolution.p1440, ScreenShareFps.fps15),
    );
    // One check per group, on the saved row.
    expect(find.byIcon(AppIcons.check), findsNWidgets(2));
    for (final label in ['1440p', '15 fps']) {
      final row = find.ancestor(
        of: find.text(label).first,
        matching: find.byType(AppMenuItem),
      );
      expect(
        find.descendant(of: row.first, matching: find.byIcon(AppIcons.check)),
        findsOneWidget,
        reason: label,
      );
    }
  });

  testWidgets('saved choices are seeded into the session at launch', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.receive_video_quality': 'dataSaver',
      'slimm.voice.camera_quality': 'dataSaver',
    });
    final session = InertSession();
    final container = await pumpControls(tester, _connected, session: session);

    await container
        .read(voiceControllerProvider.notifier)
        .restoreVideoQuality();

    expect(session.lastReceiveVideoQuality, ReceiveVideoQuality.dataSaver);
    expect(session.lastCameraQuality, CameraQuality.dataSaver);
  });

  testWidgets('an unknown saved value falls back to the defaults', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.receive_video_quality': 'nonsense',
    });
    final container = await pumpControls(tester, _connected);
    final (receive, camera) = await container.read(
      Provider((ref) => loadVideoQualityPreferences(ref)),
    );
    expect(receive, ReceiveVideoQuality.auto);
    expect(camera, CameraQuality.balanced);
  });
}
