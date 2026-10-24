// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "pause video when minimised" preference: on by default, persisted
/// when turned off, and absent where losing focus cannot pause anything.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/settings/providers/settings_index.dart';
import 'package:slimm_app/src/features/voice/providers/video_pause.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/screens/voice_settings_screen.dart';
import 'package:slimm_design_system/design_system.dart';

import 'voice_settings_screen_harness.dart';

const _label = 'Pause video when slim-m is minimised';
const _key = 'slimm.voice.pause_video_when_unfocused';

Finder get _toggle =>
    find.byWidgetPredicate((w) => w is AppToggle && w.semanticLabel == _label);

Future<void> _pump(WidgetTester tester, {bool desktop = true}) async {
  await tester.pumpWidget(
    wrap(
      const VoiceSettingsBody(),
      overrides: [
        voiceControllerProvider.overrideWith(
          (ref) => VoiceController(ref, session: FakeSession()),
        ),
        pauseOnUnfocusedAppliesProvider.overrideWithValue(desktop),
      ],
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('is on by default and turning it off persists', (tester) async {
    await _pump(tester);
    await tester.scrollUntilVisible(
      _toggle,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.widget<AppToggle>(_toggle).value, isTrue);

    await tester.tap(_toggle);
    await tester.pumpAndSettle();

    expect(tester.widget<AppToggle>(_toggle).value, isFalse);
    expect((await SharedPreferences.getInstance()).getBool(_key), isFalse);
  });

  testWidgets('is not offered where focus loss does not pause video', (
    tester,
  ) async {
    await _pump(tester, desktop: false);
    expect(find.text('Pause video when minimised'), findsNothing);
    expect(_toggle, findsNothing);
  });

  test('the settings index finds it by its new label only', () {
    final hit = searchSettings('pause video', personalSettingsIndex);
    expect(hit.map((e) => e.label), contains('Pause video when minimised'));
    expect(searchSettings('pause my preview', personalSettingsIndex), isEmpty);
  });
}
