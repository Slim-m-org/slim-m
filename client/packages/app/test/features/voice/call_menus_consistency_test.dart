// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The microphone, camera and share menus are one pattern: the same width, a
/// device row that opens its list, segmented choices, switches (never
/// checkmarks) and no "Show N more" fold.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

const _sharing = VoiceFlags(
  state: VoiceSessionState.connected,
  screenSharing: true,
);
const _cameraOn = VoiceFlags(
  state: VoiceSessionState.connected,
  cameraEnabled: true,
);

InertSession _session() =>
    InertSession(
        needsSource: true,
        sources: Future.value(const [
          ScreenShareSource(id: '1', name: 'Screen 1'),
          ScreenShareSource(id: '2', name: 'Screen 2'),
        ]),
        supportsInputGate: true,
        supportsAudioInputSelection: true,
        supportsAudioOutputSelection: true,
        audioInputDeviceList: const [
          AudioDevice(id: 'a', label: 'Headset'),
          AudioDevice(id: 'b', label: 'Desk mic'),
        ],
        audioOutputDeviceList: const [AudioDevice(id: 'o', label: 'Speakers')],
      )
      ..cameraNeedsSelection = true
      ..cameraDeviceList = const [
        CameraDevice(id: 'x', label: 'Cam one'),
        CameraDevice(id: 'y', label: 'Cam two'),
      ];

Future<ProviderContainer> _pump(WidgetTester tester, VoiceFlags voice) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = await pumpVoiceCallDock(
    tester,
    voice,
    width: 900,
    session: _session(),
  );
  container.read(voiceSettingsControllerProvider);
  await tester.pump();
  return container;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<double> _menuWidth(
  WidgetTester tester,
  VoiceFlags voice,
  String tooltip,
) async {
  await _pump(tester, voice);
  await tester.tap(find.byTooltip(tooltip));
  await _settle(tester);
  expect(
    find.byWidgetPredicate(
      (w) =>
          w is Text && RegExp(r'^Show (\d+ more|fewer)').hasMatch(w.data ?? ''),
    ),
    findsNothing,
  );
  expect(find.byIcon(AppIcons.check), findsNothing);
  final width = tester.getSize(find.bySubtype<AppMenu>()).width;
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 2));
  return width;
}

void main() {
  testWidgets('the three menus render at the same width', (tester) async {
    final widths = [
      await _menuWidth(tester, _sharing, 'Microphone options'),
      await _menuWidth(tester, _cameraOn, 'Camera options'),
      await _menuWidth(tester, _sharing, 'Screen share options'),
    ];
    expect(widths.toSet(), hasLength(1), reason: '$widths');
  });

  testWidgets('every menu leads with its device row and the same row height', (
    tester,
  ) async {
    final heights = <String>{};
    for (final (voice, tooltip, row) in [
      (_sharing, 'Microphone options', 'Microphone'),
      (_cameraOn, 'Camera options', 'Camera'),
      (_sharing, 'Screen share options', 'Sharing'),
    ]) {
      await _pump(tester, voice);
      await tester.tap(find.byTooltip(tooltip));
      await _settle(tester);
      final item = find.widgetWithText(AppMenuItem, row);
      heights.add(tester.getSize(item.first).height.toString());
    }
    expect(heights, hasLength(1));
  });

  testWidgets('the share switches write the settings Voice settings edits', (
    tester,
  ) async {
    final container = await _pump(tester, _sharing);
    await tester.tap(find.byTooltip('Screen share options'));
    await _settle(tester);

    final before = container.read(voiceSettingsControllerProvider);
    await tester.tap(find.text('Viewers can draw'));
    await tester.tap(find.text('Show my cursor'));
    await _settle(tester);
    final after = container.read(voiceSettingsControllerProvider);
    expect(
      after.screenShareAllowAnnotations,
      !before.screenShareAllowAnnotations,
    );
    expect(after.screenShareShowCursor, !before.screenShareShowCursor);
  });

  testWidgets('the Sharing row opens the source list', (tester) async {
    await _pump(tester, _sharing);
    await tester.tap(find.byTooltip('Screen share options'));
    await _settle(tester);
    await tester.tap(find.text('Sharing'));
    await _settle(tester);

    expect(find.text('Screen 1'), findsOneWidget);
    expect(find.text('Screen 2'), findsOneWidget);
  });
}
