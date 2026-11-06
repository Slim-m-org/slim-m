// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The words under Voice settings rows that were bare: the sensitivity slider,
/// the camera and device-audio rows, and what each Watching choice changes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/screens/voice_settings_screen.dart';
import 'package:slimm_app/src/features/voice/widgets/video_quality_labels.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_settings_screen_harness.dart';

Future<void> _pumpSettings(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    wrap(const VoiceSettingsBody(), overrides: ungatedSession()),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _show(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pump();
}

void main() {
  testWidgets('the sensitivity slider says it only moves the rings', (
    tester,
  ) async {
    await _pumpSettings(tester);
    final note = find.text(sensitivityDescription);
    await _show(tester, note);

    expect(note, findsOneWidget);
    expect(sensitivityDescription.split(' ').length, lessThanOrEqualTo(12));
  });

  testWidgets('the camera and device audio rows say what they do', (
    tester,
  ) async {
    await _pumpSettings(tester);

    final camera = find.text('Sharpness of the video you send.');
    await _show(tester, camera);
    expect(camera, findsOneWidget);

    final audio = find.text('Includes sound playing on this device.');
    await _show(tester, audio);
    expect(audio, findsOneWidget);
  });

  testWidgets('Watching says in one sentence what the pick changes', (
    tester,
  ) async {
    await _pumpSettings(tester);

    for (final quality in ReceiveVideoQuality.values) {
      final label = receiveVideoQualityLabel(quality);
      await _show(tester, find.text(label));
      await tester.tap(find.text(label));
      await tester.pump();
      await tester.pump();
      final note = receiveVideoQualityNote(quality);
      expect(find.text(note), findsOneWidget, reason: label);
      expect(note.split(' ').length, lessThanOrEqualTo(12), reason: label);
    }
  });
}
