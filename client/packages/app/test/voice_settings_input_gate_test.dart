// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The microphone card on a host with the native input gate: the threshold
/// is the meter's draggable line, it persists and reaches the session, and
/// push-to-talk turns the silencing off.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/screens/voice_settings_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_settings_screen_harness.dart';

Finder _meter() => find.byWidgetPredicate(
  (w) => w is AppSlider && w.semanticLabel == 'Input sensitivity',
);

Future<FakeSession> _pump(WidgetTester tester) async {
  final session = FakeSession(supportsInputGate: true);
  addTearDown(session.dispose);
  await tester.pumpWidget(
    wrap(
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
    ),
  );
  await tester.pumpAndSettle();
  return session;
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(VoiceSettingsBody)));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the gate replaces the indicator-only sensitivity slider', (
    tester,
  ) async {
    await _pump(tester);
    expect(_meter(), findsOneWidget);
    expect(find.text('-50 dB'), findsOneWidget);
    expect(find.text('Sound below the line is not sent.'), findsOneWidget);
    expect(find.text('Voice activity sensitivity'), findsNothing);
  });

  testWidgets('moving the line persists it and reaches the session', (
    tester,
  ) async {
    final session = await _pump(tester);
    final slider = tester.widget<AppSlider>(_meter());
    slider.onChanged!(-35);
    await tester.pumpAndSettle();

    expect(find.text('-35 dB'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('slimm.voice.input_threshold_db'), -35);
    expect(session.inputGateCalls.last, (enabled: true, thresholdDb: -35.0));
  });

  testWidgets('push-to-talk stops the gate silencing, but keeps the line', (
    tester,
  ) async {
    final session = await _pump(tester);
    await _container(
      tester,
    ).read(voiceSettingsControllerProvider.notifier).setPushToTalkEnabled(true);
    await tester.pumpAndSettle();
    expect(session.inputGateCalls.last.enabled, isFalse);
    expect(session.inputGateCalls.last.thresholdDb, kDefaultInputThresholdDb);
  });

  testWidgets('in a call the meter follows the live level', (tester) async {
    final session = await _pump(tester);
    final controller = _container(
      tester,
    ).read(voiceControllerProvider.notifier);
    await controller.join('channel-1');
    await tester.pumpAndSettle();
    expect(tester.widget<AppSlider>(_meter()).meter, 0);

    session.inputGateController.add(
      const InputGateReading(levelDb: -40, voice: true),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<AppSlider>(_meter()).meter, 50);
    expect(
      find.textContaining('Join a voice call to see your live input level'),
      findsNothing,
    );
    // Clears the heartbeat timer a connected call keeps running.
    await controller.leave();
  });
}
