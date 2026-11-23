// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The voice settings meter and both sliders start their track at one inset,
/// and the meter says what it is.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/screens/voice_settings_screen.dart';
import 'package:slimm_design_system/design_system.dart';

import 'voice_settings_screen_harness.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'the sensitivity ticks and the soundboard track share the text inset',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        wrap(const VoiceSettingsBody(), overrides: ungatedSession()),
      );
      await tester.pumpAndSettle();

      expect(find.text('Input level'), findsOneWidget);
      final textLeft = tester
          .getTopLeft(find.text('Voice activity sensitivity'))
          .dx;
      expect(tester.getTopLeft(find.text('Strict')).dx, closeTo(textLeft, 0.5));

      final sensitivity = find.byWidgetPredicate(
        (w) =>
            w is AppSlider && w.semanticLabel == 'Voice activity sensitivity',
      );
      final volume = find.byKey(soundboardVolumeSliderKey);
      expect(
        tester.getRect(sensitivity).left,
        closeTo(tester.getRect(volume).left, 0.5),
      );
      expect(
        tester.getRect(sensitivity).right,
        closeTo(tester.getRect(volume).right, 0.5),
      );
    },
  );
}
