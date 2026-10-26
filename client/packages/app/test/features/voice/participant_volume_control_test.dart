// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The per-participant volume slider snaps to normal when a drag ends near it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/participant_audio_controls.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart' show participantVolumeCeiling;

import 'voice_controller_harness.dart';

Future<VoiceController> _controller() async {
  final harness = VoiceHarness();
  addTearDown(harness.dispose);
  return harness.controllerWith(FakeSession(), voiceApi());
}

void main() {
  testWidgets('a drag that ends near normal lands on normal', (tester) async {
    final controller = await _controller();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: ParticipantVolumeControl(
            identity: 'user-1',
            controller: controller,
          ),
        ),
      ),
    );
    tester.widget<AppSlider>(find.byType(AppSlider)).onChanged!(97);
    await tester.pump();
    expect(find.text('100%'), findsOneWidget);
    expect(controller.volumeFor('user-1'), 1.0);
    tester.widget<AppSlider>(find.byType(AppSlider)).onChanged!(90);
    await tester.pump();
    expect(
      find.text('90%'),
      findsOneWidget,
      reason: 'far enough away is left alone',
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.volumeFor('user-1'), 0.9, reason: 'the trailing apply');
  });

  testWidgets('the slider announces its percent, whatever the range', (
    tester,
  ) async {
    final controller = await _controller();
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: ParticipantVolumeControl(
            identity: 'user-1',
            controller: controller,
          ),
        ),
      ),
    );
    final slider = tester.widget<AppSlider>(find.byType(AppSlider));
    expect(slider.valueLabel!(100), '100%');
    expect(slider.max, participantVolumeCeiling * 100);
    expect(slider.divisions, participantVolumeCeiling * 100 / 5);
    expect(
      find.semantics.byValue('100%'),
      findsOneWidget,
      reason: 'the default would read 100 of a 200 range as 50%',
    );
    handle.dispose();
  });
}
