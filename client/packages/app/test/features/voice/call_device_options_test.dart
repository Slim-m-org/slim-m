// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The camera button's options and the speaker list in the mic menu: each pick
/// is written through the notifier Voice settings uses, a phone reaches them by
/// long press, and iOS and the web (no output switching) never see a speaker
/// section.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' show SlimmApi;
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/providers.dart' show apiProvider;
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/call_device_options.dart';
import 'package:slimm_app/src/widgets/control_options_menu.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

const _cameraOn = VoiceFlags(
  state: VoiceSessionState.connected,
  cameraEnabled: true,
);
const _cameraOff = VoiceFlags(state: VoiceSessionState.connected);
const _desk = AudioDevice(id: 'spk-1', label: 'Desk speakers');
const _builtIn = CameraDevice(id: 'cam-1', label: 'Built-in webcam');
const _usbCam = CameraDevice(id: 'cam-2', label: 'USB camera');

Future<ProviderContainer> _pump(
  WidgetTester tester,
  InertSession session, {
  VoiceFlags voice = _cameraOn,
  double width = 900,
  bool touch = false,
  List<Override> overrides = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = Size(width, 700);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = await pumpVoiceCallDock(
    tester,
    voice,
    width: width,
    touch: touch,
    session: session,
    extraOverrides: overrides,
  );
  container.read(voiceSettingsControllerProvider);
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
  return container;
}

Future<void> _open(WidgetTester tester, Finder control) async {
  await tester.tap(control);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _longPress(WidgetTester tester, Finder control) async {
  await tester.longPress(control);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

SlimmApi _strongSpaceApi() => SlimmApi(
  baseUrl: Uri.parse('http://localhost:8080'),
  httpClient: MockClient(
    (_) async => http.Response(
      jsonEncode({
        'name': 'slim-m',
        'version': '0.0.0',
        'protocol': 1,
        'strong_noise_suppression': true,
      }),
      200,
      headers: {'content-type': 'application/json'},
    ),
  ),
);

void main() {
  group('the camera menu', () {
    testWidgets('lists the resolutions and the mirror toggle', (tester) async {
      await _pump(tester, InertSession());
      await _open(tester, find.byTooltip('Camera options'));

      for (final label in ['360p', '720p', '1080p', 'Mirror my view']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('a resolution pick is the Voice settings pick', (tester) async {
      final container = await _pump(tester, InertSession());
      await _open(tester, find.byTooltip('Camera options'));

      await tester.tap(find.text('1080p'));
      await tester.pump();
      final settings = container.read(voiceSettingsControllerProvider);
      expect(settings.cameraQuality, CameraQuality.high);
    });

    testWidgets('the mirror toggle is the Voice settings toggle', (
      tester,
    ) async {
      final container = await _pump(tester, InertSession());
      await _open(tester, find.byTooltip('Camera options'));

      await tester.tap(find.text('Mirror my view'));
      await tester.pump();
      final settings = container.read(voiceSettingsControllerProvider);
      expect(settings.mirrorSelfView, isFalse);
    });

    testWidgets('lists the cameras of a picker platform and switches', (
      tester,
    ) async {
      final session = InertSession()
        ..cameraNeedsSelection = true
        ..cameraDeviceList = const [_builtIn, _usbCam];
      await _pump(tester, session);
      await _open(tester, find.byTooltip('Camera options'));

      expect(find.text('SWITCH CAMERA'), findsOneWidget);
      await tester.tap(find.text('USB camera'));
      await tester.pump();
      expect(session.cameraSwitchCalls, ['select:cam-2']);
    });

    testWidgets('offers a flip where the platform flips', (tester) async {
      final session = InertSession()..canFlipCamera = true;
      await _pump(tester, session);
      await _open(tester, find.byTooltip('Camera options'));

      await tester.tap(find.text('Flip camera'));
      await tester.pump();
      expect(session.cameraSwitchCalls, ['flip']);
    });

    testWidgets('has no camera to switch while the camera is off', (
      tester,
    ) async {
      final session = InertSession()
        ..canFlipCamera = true
        ..cameraNeedsSelection = true
        ..cameraDeviceList = const [_builtIn, _usbCam];
      await _pump(tester, session, voice: _cameraOff);
      await _open(tester, find.byTooltip('Camera options'));

      expect(find.text('720p'), findsOneWidget);
      expect(find.text('Flip camera'), findsNothing);
      expect(find.text('SWITCH CAMERA'), findsNothing);
    });

    testWidgets('opens by long press on a phone, with no caret', (
      tester,
    ) async {
      await _pump(tester, InertSession(), width: 390, touch: true);
      expect(find.byTooltip('Camera options'), findsNothing);

      await _longPress(tester, find.byTooltip(RegExp('^Turn off camera')));
      expect(find.text('720p'), findsOneWidget);
    });
  });

  group('the speaker section of the mic menu', () {
    testWidgets('lists outputs and applies the pick', (tester) async {
      final session = InertSession(
        supportsAudioOutputSelection: true,
        audioOutputDeviceList: const [_desk],
      );
      final container = await _pump(tester, session);
      await _open(tester, find.byTooltip('Microphone options'));

      expect(find.text('SPEAKER'), findsOneWidget);
      await tester.tap(find.text('Desk speakers'));
      await tester.pump();
      expect(session.lastSelectedAudioOutput?.id, 'spk-1');
      expect(
        container.read(voiceSettingsControllerProvider).audioOutputDeviceId,
        'spk-1',
      );
    });

    testWidgets('is absent where the platform cannot switch output', (
      tester,
    ) async {
      await _pump(tester, InertSession());
      await _open(tester, find.byTooltip('Microphone options'));

      expect(find.text('SPEAKER'), findsNothing);
      expect(find.text('Voice settings'), findsOneWidget);
    });
  });

  testWidgets('the mic menu names what Space default currently means', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      InertSession(supportsInputGate: true),
      overrides: [apiProvider.overrideWith((ref) => _strongSpaceApi())],
    );
    await container
        .read(voiceControllerProvider.notifier)
        .input
        .refreshSpaceNoiseSuppression();
    await tester.pump();
    await _open(tester, find.byTooltip('Microphone options'));

    expect(find.text('Space default (Strong)'), findsOneWidget);
  });

  test(
    'a camera menu with nothing to switch is the resolutions and mirror',
    () {
      final entries = cameraMenuEntries(
        quality: CameraQuality.balanced,
        mirror: true,
        devices: const [],
        canFlip: false,
        actions: CameraMenuActions(
          onQuality: (_) {},
          onMirror: (_) {},
          onDevice: (_) {},
          onFlip: () {},
        ),
      );
      final labels = [
        for (final entry in entries)
          if (entry is ControlOption) entry.label,
      ];
      expect(labels, ['360p', '720p', '1080p', 'Mirror my view']);
    },
  );

  test('the camera menu marks the camera picked this call', () {
    final entries = cameraMenuEntries(
      quality: CameraQuality.balanced,
      mirror: false,
      devices: const [
        CameraDevice(id: 'a', label: 'Front'),
        CameraDevice(id: 'b', label: 'Desk'),
      ],
      canFlip: false,
      chosenDeviceId: 'b',
      actions: CameraMenuActions(
        onQuality: (_) {},
        onMirror: (_) {},
        onDevice: (_) {},
        onFlip: () {},
      ),
    );
    final picked = [
      for (final entry in entries)
        if (entry is ControlOption && entry.selected) entry.label,
    ];
    expect(picked, ['Desk', '720p']);
  });
}
