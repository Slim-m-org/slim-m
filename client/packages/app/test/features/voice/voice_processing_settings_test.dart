// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The folded Advanced section in Voice settings: echo, gain and suppression
/// are on until turned off, each persists, and a change reaches the session.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/screens/voice_settings_screen.dart';
import 'package:slimm_design_system/design_system.dart';

import 'voice_settings_screen_harness.dart';

Finder _toggle(String label) =>
    find.byWidgetPredicate((w) => w is AppToggle && w.semanticLabel == label);

Future<FakeSession> _pump(WidgetTester tester, {bool gate = true}) async {
  final session = FakeSession(supportsInputGate: gate);
  addTearDown(session.dispose);
  await tester.pumpWidget(
    wrap(
      const VoiceSettingsBody(),
      overrides: [
        voiceControllerProvider.overrideWith(
          (ref) => VoiceController(ref, session: session),
        ),
      ],
    ),
  );
  await tester.pumpAndSettle();
  return session;
}

Future<void> _open(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('Advanced'),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(find.text('Advanced'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('it is folded, says all on, and lists the three filters', (
    tester,
  ) async {
    await _pump(tester);
    await tester.scrollUntilVisible(
      find.text('Advanced'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('All on'), findsOneWidget);
    expect(_toggle('Echo cancellation'), findsNothing);

    await _open(tester);

    for (final label in [
      'Echo cancellation',
      'Automatic gain',
      'Built-in noise suppression',
    ]) {
      expect(tester.widget<AppToggle>(_toggle(label)).value, isTrue);
    }
  });

  testWidgets('turning one off persists it and reaches the session', (
    tester,
  ) async {
    final session = await _pump(tester);
    await _open(tester);

    await tester.tap(_toggle('Automatic gain'));
    await tester.pumpAndSettle();

    expect(tester.widget<AppToggle>(_toggle('Automatic gain')).value, isFalse);
    expect(find.text('1 off'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('slimm.voice.auto_gain'), isFalse);
    expect(prefs.getBool('slimm.voice.echo_cancellation'), isTrue);
    expect(session.lastVoiceProcessing?.autoGainControl, isFalse);
    expect(session.lastVoiceProcessing?.echoCancellation, isTrue);
  });

  testWidgets('a stored choice is restored before a call', (tester) async {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.echo_cancellation': false,
    });
    final session = await _pump(tester);

    await ProviderScope.containerOf(
      tester.element(find.byType(VoiceSettingsBody)),
    ).read(voiceControllerProvider.notifier).input.restoreVoiceProcessing();

    expect(session.lastVoiceProcessing?.echoCancellation, isFalse);
  });

  testWidgets('a host without the capture chain does not offer it', (
    tester,
  ) async {
    await _pump(tester, gate: false);

    expect(find.text('Advanced'), findsNothing);
  });
}
