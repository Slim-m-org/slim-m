// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Outside a call the microphone meters show the preview capture's level, in
/// the setup step and in Voice settings, and give way to a live call.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/first_run/widgets/first_run_device_steps.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/features/voice/screens/voice_settings_screen.dart';
import 'package:slimm_app/src/features/voice/widgets/audio_device_section.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_mic_preview.dart';
import 'voice_settings_screen_harness.dart';

List<Override> _overrides(FakeMicSource source, {bool gate = false}) => [
  voiceControllerProvider.overrideWith(
    (ref) =>
        VoiceController(ref, session: FakeSession(supportsInputGate: gate)),
  ),
  fakeMicPreview(source),
];

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _leave(WidgetTester tester) async {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(Scaffold)),
  );
  await tester.pumpWidget(const SizedBox());
  container.dispose();
}

double _meterTarget(WidgetTester tester) => tester
    .widget<TweenAnimationBuilder<double>>(
      find.byType(TweenAnimationBuilder<double>),
    )
    .tween
    .end!;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Voice settings meters the preview level out of a call', (
    tester,
  ) async {
    final source = FakeMicSource(level: -30);
    await tester.pumpWidget(
      wrap(const VoiceSettingsBody(), overrides: _overrides(source)),
    );
    await _settle(tester);

    expect(_meterTarget(tester), closeTo(inputLevelFraction(-30) * 100, 0.01));
    expect(find.textContaining('Join a voice call'), findsNothing);
    await _leave(tester);
  });

  testWidgets('the gated sensitivity bar shows the preview level and voice', (
    tester,
  ) async {
    final source = FakeMicSource(level: -42, voice: true);
    await tester.pumpWidget(
      wrap(
        const VoiceSettingsBody(),
        overrides: _overrides(source, gate: true),
      ),
    );
    await _settle(tester);

    final bar = tester.widget<AppSlider>(
      find.byWidgetPredicate(
        (w) => w is AppSlider && w.semanticLabel == 'Input sensitivity',
      ),
    );
    expect(bar.meter, closeTo(inputLevelFraction(-42) * 100, 0.01));
    expect(bar.meterActive, isTrue);
    expect(find.textContaining('Join a call'), findsNothing);
    await _leave(tester);
  });

  testWidgets('a microphone that cannot open says so inline', (tester) async {
    final source = FakeMicSource(fails: true);
    await tester.pumpWidget(
      wrap(const VoiceSettingsBody(), overrides: _overrides(source)),
    );
    await _settle(tester);

    expect(find.textContaining('sending no sound'), findsOneWidget);
    await _leave(tester);
  });

  testWidgets('the setup step shows the preview level, not a call prompt', (
    tester,
  ) async {
    final source = FakeMicSource(level: -20);
    await tester.pumpWidget(
      wrap(const FirstRunVoiceStep(), overrides: _overrides(source)),
    );
    await _settle(tester);

    expect(find.text('Your level'), findsOneWidget);
    expect(find.text('Say something to see it move.'), findsOneWidget);
    expect(find.textContaining('Join a voice channel'), findsNothing);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(inputLevelFraction(-20), 0.05));
    await _leave(tester);
  });

  testWidgets('picking another microphone moves the preview to it', (
    tester,
  ) async {
    final source = FakeMicSource();
    await tester.pumpWidget(
      wrap(const FirstRunVoiceStep(), overrides: _overrides(source)),
    );
    await _settle(tester);
    expect(source.opened, [null]);

    await ProviderScope.containerOf(
          tester.element(find.byType(FirstRunVoiceStep)),
        )
        .read(voiceSettingsControllerProvider.notifier)
        .setAudioInputDevice(const AudioDevice(id: 'usb', label: 'USB mic'));
    await _settle(tester);

    expect(source.opened, [null, 'usb']);
    await _leave(tester);
  });

  testWidgets('leaving the screen stops the capture', (tester) async {
    final source = FakeMicSource();
    final shown = ValueNotifier(true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(source),
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: shown,
              builder: (_, on, _) =>
                  on ? const FirstRunVoiceStep() : const SizedBox(),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    final closesWhileOpen = source.closes;

    shown.value = false;
    await _settle(tester);

    expect(source.closes, greaterThan(closesWhileOpen));
  });

  testWidgets('a live call keeps its own meter and opens no second capture', (
    tester,
  ) async {
    final source = FakeMicSource();
    await tester.pumpWidget(
      wrap(const FirstRunVoiceStep(), overrides: _overrides(source)),
    );
    await _settle(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(FirstRunVoiceStep)),
    );

    await container.read(voiceControllerProvider.notifier).join('channel-1');
    await _settle(tester);
    final opensInCall = source.opened.length;
    await _settle(tester);

    expect(source.opened.length, opensInCall);
    expect(source.closes, greaterThan(0));
    await container.read(voiceControllerProvider.notifier).leave();
    await _leave(tester);
  });

  testWidgets('the device list has no Reset microphone row', (tester) async {
    await tester.pumpWidget(
      wrap(const AudioDeviceSection(), overrides: _overrides(FakeMicSource())),
    );
    await _settle(tester);

    expect(find.text('Reset microphone'), findsNothing);
    await _leave(tester);
  });
}
