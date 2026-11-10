// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On a phone, opening Voice settings must not open the microphone preview:
/// the loopback behind the meter put the mic through the loudspeaker.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/mic_preview.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/screens/voice_settings_screen.dart';
import 'package:slimm_app/src/features/voice/widgets/mic_preview_hold.dart';

import '../../support/fake_mic_preview.dart';
import 'voice_settings_screen_harness.dart';

List<Override> _phone(FakeMicSource source) => [
  voiceControllerProvider.overrideWith(
    (ref) => VoiceController(ref, session: FakeSettingsSession()),
  ),
  fakeMicPreview(source),
  micPreviewNeedsTapProvider.overrideWithValue(true),
];

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('opening the pane on a phone captures nothing', (tester) async {
    final source = FakeMicSource();
    await tester.pumpWidget(
      wrap(const VoiceSettingsBody(), overrides: _phone(source)),
    );
    await _settle(tester);

    expect(source.opened, isEmpty);
    expect(find.byKey(micTestButtonKey), findsOneWidget);
  });

  testWidgets('the capture starts on tap and stops when the pane closes', (
    tester,
  ) async {
    final source = FakeMicSource();
    await tester.pumpWidget(
      wrap(const VoiceSettingsBody(), overrides: _phone(source)),
    );
    await _settle(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byKey(micTestButtonKey)),
    );
    await tester.tap(find.byKey(micTestButtonKey));
    await _settle(tester);
    expect(source.opened, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    await _settle(tester);
    expect(container.read(micPreviewArmedProvider), isFalse);
    expect(source.closes, greaterThan(0));
    container.dispose();
  });

  testWidgets('Stop test closes the microphone and leaves the pane open', (
    tester,
  ) async {
    final source = FakeMicSource();
    await tester.pumpWidget(
      wrap(const VoiceSettingsBody(), overrides: _phone(source)),
    );
    await _settle(tester);
    await tester.tap(find.byKey(micTestButtonKey));
    await _settle(tester);
    expect(source.opened, hasLength(1));

    await tester.tap(find.byKey(micTestStopKey));
    await _settle(tester);
    expect(source.closes, greaterThan(0));
    expect(find.byKey(micTestButtonKey), findsOneWidget);
  });

  testWidgets('the permission prompt does not cancel the test', (tester) async {
    final source = FakeMicSource();
    await tester.pumpWidget(
      wrap(const VoiceSettingsBody(), overrides: _phone(source)),
    );
    await _settle(tester);
    await tester.tap(find.byKey(micTestButtonKey));
    await _settle(tester);

    // Android's permission dialog leaves the app inactive, never paused.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await _settle(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester);

    expect(find.byKey(micTestStopKey), findsOneWidget);
    expect(source.opened, hasLength(2));
  });

  testWidgets('going to the background cancels the test', (tester) async {
    final source = FakeMicSource();
    await tester.pumpWidget(
      wrap(const VoiceSettingsBody(), overrides: _phone(source)),
    );
    await _settle(tester);
    await tester.tap(find.byKey(micTestButtonKey));
    await _settle(tester);

    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await _settle(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester);

    expect(find.byKey(micTestButtonKey), findsOneWidget);
    expect(source.opened, hasLength(1));
  });
}
