// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On iPhone the dead "routes automatically" captions give way to the system route button.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/speaker_route_provider.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/audio_device_section.dart';
import 'package:slimm_app/src/features/voice/widgets/audio_route_picker.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/mid_flight_capture.dart';
import 'voice_settings_screen_harness.dart';

const _stand = Key('stand-in-picker');

List<Override> _overrides() => [
  voiceControllerProvider.overrideWith(
    (ref) => VoiceController(
      ref,
      session: FakeSession(
        supportsAudioInputSelection: false,
        supportsAudioOutputSelection: false,
      ),
    ),
  ),
  speakerRouteProvider.overrideWithValue(
    SpeakerRoute(supported: true, apply: (_) async {}),
  ),
];

Future<void> _open(WidgetTester tester, {required bool ios}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    wrap(
      AudioDeviceSection(
        embedded: true,
        ios: ios,
        routePicker: const SizedBox(key: _stand),
      ),
      overrides: _overrides(),
    ),
  );
  await tester.pump();
  await expectSettled(tester, 'audio route picker');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('iPhone shows the route button, not the captions', (
    tester,
  ) async {
    await _open(tester, ios: true);
    expect(find.byKey(audioRoutePickerKey), findsOneWidget);
    expect(find.byKey(_stand), findsOneWidget);
    expect(
      find.text('This platform routes microphones automatically.'),
      findsNothing,
    );
    expect(
      find.text(
        'This platform always plays a call through its default output.',
      ),
      findsNothing,
    );
    expect(find.text('Use loudspeaker'), findsOneWidget);
  });

  testWidgets('another phone keeps the captions and has no route button', (
    tester,
  ) async {
    await _open(tester, ios: false);
    expect(find.byKey(audioRoutePickerKey), findsNothing);
    expect(
      find.text('This platform routes microphones automatically.'),
      findsOneWidget,
    );
  });
}
