// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The percentage the slider shows is the value the session is given, for
/// both a person's voice and their shared screen's sound, on a drag and on a
/// release.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/participant_audio_controls.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

void main() {
  for (final channel in LocalAudioChannel.values) {
    final screen = channel == LocalAudioChannel.screen;

    group('${channel.name} slider', () {
      Future<FakeSession> pumpSlider(WidgetTester tester) async {
        final session = FakeSession();
        final harness = VoiceHarness();
        addTearDown(harness.dispose);
        final controller = harness.controllerWith(session, voiceApi());
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(
              body: ParticipantVolumeControl(
                identity: 'user-1',
                controller: controller,
                channel: channel,
              ),
            ),
          ),
        );
        return session;
      }

      testWidgets('the label and the pushed value agree on a drag', (
        tester,
      ) async {
        final session = await pumpSlider(tester);

        tester.widget<AppSlider>(find.byType(AppSlider)).onChanged!(63.4);
        await tester.pump(const Duration(milliseconds: 200));

        expect(find.text('63%'), findsOneWidget);
        expect(session.volumePushes.last, ('user-1', screen, 0.63));
      });

      testWidgets('a release pushes once more, even at the dragged value', (
        tester,
      ) async {
        final session = await pumpSlider(tester);
        final slider = tester.widget<AppSlider>(find.byType(AppSlider));

        slider.onChanged!(80);
        await tester.pump(const Duration(milliseconds: 200));
        final dragged = session.volumePushes.length;
        slider.onChangeEnd!(80);
        await tester.pump(const Duration(milliseconds: 200));

        expect(find.text('80%'), findsOneWidget);
        expect(session.volumePushes.length, dragged + 1);
        expect(session.volumePushes.last, ('user-1', screen, 0.8));
      });

      testWidgets('ending a drag near normal pushes exactly normal', (
        tester,
      ) async {
        final session = await pumpSlider(tester);

        tester.widget<AppSlider>(find.byType(AppSlider)).onChangeEnd!(98.2);
        await tester.pump(const Duration(milliseconds: 200));

        expect(find.text('100%'), findsOneWidget);
        expect(session.volumePushes.last, ('user-1', screen, 1.0));
      });
    });
  }
}
