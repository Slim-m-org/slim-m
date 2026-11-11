// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The profile, notifications and voice steps share one layout: the heading,
/// the section titles and the cards sit on the same left edge at every width.
library;

import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';

import 'first_run_harness.dart';

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await settle(tester);
}

void main() {
  for (final (name, size) in [
    ('desktop', const Size(1280, 800)),
    ('phone', const Size(390, 800)),
  ]) {
    testWidgets('the three steps share their left edge on $name', (
      tester,
    ) async {
      await pumpFirstRun(tester, size: size);
      await _tap(tester, 'Continue');
      final profile = (
        heading: tester.getRect(find.text('Set up your profile')).left,
        section: tester.getRect(find.text('Identity')).left,
        pronouns: tester.getRect(find.text('Pronouns (optional)')).left,
      );
      await _tap(tester, 'Continue');
      final notify = (
        heading: tester.getRect(find.text('Choose your notifications')).left,
        section: tester.getRect(find.text('Notify me for')).left,
      );
      await _tap(tester, 'Continue');
      final voice = (
        heading: tester.getRect(find.text('Check your voice')).left,
        section: tester.getRect(find.text('Devices')).left,
        level: tester.getRect(find.text('Your level')).left,
      );

      expect(notify.heading, profile.heading);
      expect(voice.heading, profile.heading);
      expect(notify.section, profile.section);
      expect(voice.section, profile.section);
      expect(voice.level, profile.section);
      expect(profile.pronouns, profile.section);
    });
  }
}
