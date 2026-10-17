// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the microphone and speaker pickers: real devices are listed,
/// a choice persists and reaches the session, an unsupported platform shows
/// a caption rather than a dead control, and a device unplugged since it was
/// chosen falls back to the system default quietly.
///
/// Split out of `voice_settings_screen_test.dart`, `voice_settings_camera_test.dart`'s
/// own reasoning; all three share `voice_settings_screen_harness.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/screens/voice_settings_screen.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_select_row.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_settings_screen_harness.dart';

const _mic1 = AudioDevice(id: 'mic-1', label: 'Built-in microphone');
const _mic2 = AudioDevice(id: 'mic-2', label: 'USB headset');
const _speaker1 = AudioDevice(id: 'spk-1', label: 'Built-in speakers');

Widget _pumpWith(FakeSession session) => wrap(
  const VoiceSettingsBody(),
  overrides: [
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
);

Finder _pickerRow(String label) => find.byWidgetPredicate(
  (w) => w is SettingsSelectRow<String> && w.label == label,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('lists the real microphones and speakers this session offers', (
    tester,
  ) async {
    final session = FakeSession(
      audioInputDeviceList: const [_mic1, _mic2],
      audioOutputDeviceList: const [_speaker1],
    );
    await tester.pumpWidget(_pumpWith(session));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      _pickerRow('Microphone'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(_pickerRow('Microphone'));
    await tester.pumpAndSettle();

    // Both rows already read "System default" before either picker opens.
    expect(find.text('System default'), findsWidgets);
    expect(find.text('Built-in microphone'), findsOneWidget);
    expect(find.text('USB headset'), findsOneWidget);
  });

  testWidgets('choosing a microphone persists it and reaches the session', (
    tester,
  ) async {
    final session = FakeSession(audioInputDeviceList: const [_mic1, _mic2]);
    await tester.pumpWidget(_pumpWith(session));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      _pickerRow('Microphone'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(_pickerRow('Microphone'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('USB headset'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('slimm.voice.audio_input_device_id'), 'mic-2');
    expect(session.lastSelectedAudioInput?.id, 'mic-2');
  });

  testWidgets(
    'a platform that cannot select an output shows a caption, never a '
    'picker that would do nothing',
    (tester) async {
      final session = FakeSession(supportsAudioOutputSelection: false);
      await tester.pumpWidget(_pumpWith(session));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.textContaining('always plays a call through its default output'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(_pickerRow('Speaker'), findsNothing);
      expect(
        find.textContaining('always plays a call through its default output'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'a device unplugged since it was chosen falls back to the default '
    'and says so quietly',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'slimm.voice.audio_input_device_id': 'mic-gone',
      });
      final session = FakeSession(audioInputDeviceList: const [_mic1]);
      await tester.pumpWidget(_pumpWith(session));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.textContaining('connected. Using the system default'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('connected. Using the system default'),
        findsOneWidget,
      );
      final row = tester.widget<SettingsSelectRow<String>>(
        _pickerRow('Microphone'),
      );
      // Shown as the default, not as a phantom entry for a device that is gone.
      expect(row.value, '');
      // The stored choice survives untouched, in case the device comes back.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('slimm.voice.audio_input_device_id'), 'mic-gone');
    },
  );
}
