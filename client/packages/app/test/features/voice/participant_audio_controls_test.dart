// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [ParticipantVolumeControl]'s reset-to-normal affordance, and
/// [ParticipantMuteForMeMenuItem]'s toggle - the two halves
/// `MemberLocalAudioSection` composes and a quick-actions menu now reuses
/// directly.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/participant_audio_controls.dart';
import 'package:slimm_design_system/design_system.dart';

import 'voice_controller_harness.dart' show VoiceHarness, FakeSession, voiceApi;

Future<VoiceController> _controller(WidgetTester tester) async {
  final harness = VoiceHarness();
  addTearDown(harness.dispose);
  return harness.controllerWith(FakeSession(), voiceApi());
}

Widget _wrap(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.light, AppTokens.light),
  home: Scaffold(body: child),
);

void main() {
  _registerFailureTests();

  testWidgets(
    'the reset button is absent at the default volume, appears once moved '
    'and resets back to 100% on tap',
    (tester) async {
      final controller = await _controller(tester);
      await tester.pumpWidget(
        _wrap(
          ParticipantVolumeControl(identity: 'user-1', controller: controller),
        ),
      );

      expect(
        find.byTooltip('Reset to normal'),
        findsNothing,
        reason:
            'absent, never disabled, at the default - see the widget\'s own doc',
      );
      expect(find.text('100%'), findsOneWidget);

      tester.widget<AppSlider>(find.byType(AppSlider)).onChanged!(40);
      await tester.pump();

      expect(find.text('40%'), findsOneWidget);
      expect(controller.volumeFor('user-1'), 0.4);
      expect(find.byTooltip('Reset to normal'), findsOneWidget);

      await tester.tap(find.byTooltip('Reset to normal'));
      await tester.pump();

      expect(find.text('100%'), findsOneWidget);
      expect(controller.volumeFor('user-1'), 1.0);
      expect(find.byTooltip('Reset to normal'), findsNothing);
    },
  );

  testWidgets(
    'moving the slider reaches the controller immediately, not only on '
    'release',
    (tester) async {
      final controller = await _controller(tester);
      await tester.pumpWidget(
        _wrap(
          ParticipantVolumeControl(identity: 'user-1', controller: controller),
        ),
      );

      tester.widget<AppSlider>(find.byType(AppSlider)).onChanged!(150);
      await tester.pump();

      expect(controller.volumeFor('user-1'), 1.5);
    },
  );

  testWidgets(
    'mute for me toggles the label, the icon and the controller together',
    (tester) async {
      final controller = await _controller(tester);
      await tester.pumpWidget(
        _wrap(
          ParticipantMuteForMeMenuItem(
            identity: 'user-1',
            controller: controller,
          ),
        ),
      );

      expect(find.text('Mute for me'), findsOneWidget);
      expect(controller.isLocallyMuted('user-1'), isFalse);

      await tester.tap(find.text('Mute for me'));
      await tester.pump();

      expect(find.text('Unmute for me'), findsOneWidget);
      expect(controller.isLocallyMuted('user-1'), isTrue);
    },
  );

  testWidgets('mute for me calls onDone once the toggle lands', (tester) async {
    final controller = await _controller(tester);
    var done = 0;
    await tester.pumpWidget(
      _wrap(
        ParticipantMuteForMeMenuItem(
          identity: 'user-1',
          controller: controller,
          onDone: () => done++,
        ),
      ),
    );

    await tester.tap(find.text('Mute for me'));
    await tester.pump();

    expect(done, 1);
  });
}

class _RefusingSession extends FakeSession {
  @override
  Object? volumeFailureFor(String identity, {bool screen = false}) =>
      StateError('refused');

  @override
  bool hasScreenAudio(String identity) => true;
}

void _registerFailureTests() {
  testWidgets('a refused volume change shows inline', (tester) async {
    final harness = VoiceHarness();
    addTearDown(harness.dispose);
    final controller = harness.controllerWith(_RefusingSession(), voiceApi());
    await tester.pumpWidget(
      _wrap(
        ParticipantVolumeControl(identity: 'user-1', controller: controller),
      ),
    );
    expect(find.text("Volume can't be changed on this device"), findsNothing);

    tester.widget<AppSlider>(find.byType(AppSlider)).onChanged!(150);
    await tester.pump();
    await tester.pump();

    expect(find.text("Volume can't be changed on this device"), findsOneWidget);
  });

  testWidgets('the screen audio section keeps its own volume and mute', (
    tester,
  ) async {
    final harness = VoiceHarness();
    addTearDown(harness.dispose);
    final controller = harness.controllerWith(_RefusingSession(), voiceApi());
    await tester.pumpWidget(
      _wrap(
        ParticipantScreenAudioSection(
          identity: 'user-1',
          controller: controller,
        ),
      ),
    );

    expect(find.text('Screen audio'), findsOneWidget);
    expect(find.text('Mute screen audio'), findsOneWidget);
  });
}
