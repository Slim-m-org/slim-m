// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Switching cameras already had a quick in-call control; the speaker did
/// not, even though `AudioDeviceSwitching.supportsOutputSelection` was
/// already true on desktop and Android. This drives the new in-call speaker
/// button through the same settings notifier Voice Settings itself uses.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

const _headset = AudioDevice(id: 'headset-1', label: 'Headset');
const _speakers = AudioDevice(id: 'speakers-1', label: 'Built-in speakers');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'the speaker button is hidden on a platform that cannot switch output',
    (tester) async {
      await pumpControls(
        tester,
        const VoiceFlags(state: VoiceSessionState.connected),
        session: InertSession(supportsAudioOutputSelection: false),
      );

      expect(find.byTooltip('Switch speaker'), findsNothing);
    },
  );

  testWidgets('the speaker button opens a picker and applies the choice live', (
    tester,
  ) async {
    final session = InertSession(
      supportsAudioOutputSelection: true,
      audioOutputDeviceList: const [_headset, _speakers],
    );
    final container = await pumpControls(
      tester,
      const VoiceFlags(state: VoiceSessionState.connected),
      session: session,
    );

    expect(find.byTooltip('Switch speaker'), findsOneWidget);

    await tester.tap(find.byTooltip('Switch speaker'));
    // pump, not pumpAndSettle: the switch button's pending spinner never settles while the sheet awaits a choice.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Choose a speaker'), findsOneWidget);
    expect(find.text('System default'), findsOneWidget);
    expect(find.text('Headset'), findsOneWidget);
    expect(find.text('Built-in speakers'), findsOneWidget);

    await tester.tap(find.text('Headset'));
    await tester.pumpAndSettle();

    expect(session.lastSelectedAudioOutput?.id, 'headset-1');
    expect(
      container.read(voiceSettingsControllerProvider).audioOutputDeviceId,
      'headset-1',
      reason:
          'the in-call picker must write through the same state Voice '
          'Settings reads, not a copy of its own',
    );
  });

  testWidgets('choosing system default clears the persisted device', (
    tester,
  ) async {
    final session = InertSession(
      supportsAudioOutputSelection: true,
      audioOutputDeviceList: const [_headset],
    );
    final container = await pumpControls(
      tester,
      const VoiceFlags(state: VoiceSessionState.connected),
      session: session,
    );

    await tester.tap(find.byTooltip('Switch speaker'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Headset'));
    await tester.pumpAndSettle();
    expect(
      container.read(voiceSettingsControllerProvider).audioOutputDeviceId,
      'headset-1',
    );

    await tester.tap(find.byTooltip('Switch speaker'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('System default'));
    await tester.pumpAndSettle();

    expect(session.lastSelectedAudioOutput, isNull);
    expect(
      container.read(voiceSettingsControllerProvider).audioOutputDeviceId,
      isNull,
    );
  });
}
