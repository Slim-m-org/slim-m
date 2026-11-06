// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The microphone and speaker rows read cleanly: the Windows note is whole,
/// Test speaker is there only when it can play where you chose, and a long
/// device name leaves its label in place.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/audio/sound_output_router.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/audio_device_section.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../ui_snapshot_support.dart' show loadRealFonts;
import 'voice_settings_screen_harness.dart';

const _longSpeaker = AudioDevice(
  id: 'spk-long',
  label: 'SteelSeries Sonar - Stream (SteelSeries Sonar Virtual Audio Device)',
);

const _pane = 560.0;

Future<void> _open(
  WidgetTester tester, {
  AudioDevicePart part = AudioDevicePart.all,
  bool testable = true,
}) async {
  // A wide window around a narrow pane, as settings sits on a desktop.
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    wrap(
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: _pane,
          child: AudioDeviceSection(embedded: true, part: part, windows: true),
        ),
      ),
      overrides: [
        voiceControllerProvider.overrideWith(
          (ref) => VoiceController(
            ref,
            session: FakeSession(audioOutputDeviceList: const [_longSpeaker]),
          ),
        ),
        soundOutputRouterProvider.overrideWithValue(
          SoundOutputRouter(
            () => testable ? null : 'spk-long',
            supported: false,
          ),
        ),
      ],
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUpAll(loadRealFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the Windows note is shown whole, not cut off', (tester) async {
    await _open(tester, part: AudioDevicePart.microphoneOptions);
    final note = find.textContaining('Windows can process your voice');
    expect(note, findsOneWidget);
    expect(
      tester.renderObject<RenderParagraph>(note).didExceedMaxLines,
      isFalse,
    );
  });

  testWidgets('Test speaker has a Play button when it can play there', (
    tester,
  ) async {
    await _open(tester, part: AudioDevicePart.speaker);
    expect(find.byKey(speakerTestRowKey), findsOneWidget);
    expect(find.text('Play'), findsOneWidget);
  });

  testWidgets('Test speaker is left out when it cannot reach the pick', (
    tester,
  ) async {
    await _open(tester, part: AudioDevicePart.speaker, testable: false);
    expect(find.byKey(speakerTestRowKey), findsNothing);
  });

  testWidgets('a long speaker name leaves the label its room', (tester) async {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.audio_output_device_id': 'spk-long',
    });
    await _open(tester, part: AudioDevicePart.speaker);
    final label = find.text('Output device');
    final value = tester.getRect(find.textContaining('SteelSeries Sonar'));
    expect(value.left, greaterThan(_pane * 0.4), reason: 'value capped');
    expect(
      tester.renderObject<RenderParagraph>(label).didExceedMaxLines,
      isFalse,
    );
  });
}
