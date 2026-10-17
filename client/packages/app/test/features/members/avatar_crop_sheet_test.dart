// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The crop sheet has to fit the window it opens in.
///
/// Its square viewport was sized from the window's width alone, so on any
/// window wider than it is tall - which is every desktop - the circle was
/// taller than the screen and pushed Cancel and Use picture off the bottom.
/// There was then no way to finish or abandon a crop, and so no way to set an
/// avatar at all. Found by an end-to-end run that could pick a file and then
/// never reach the button.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/widgets/avatar_crop_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

/// A 1x1 PNG, which is all the sheet needs to lay itself out.
final _png = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x02,
  0x00,
  0x00,
  0x00,
  0x90,
  0x77,
  0x53,
  0xDE,
  0x00,
  0x00,
  0x00,
  0x0C,
  0x49,
  0x44,
  0x41,
  0x54,
  0x08,
  0xD7,
  0x63,
  0xF8,
  0xCF,
  0xC0,
  0x00,
  0x00,
  0x03,
  0x01,
  0x01,
  0x00,
  0x18,
  0xDD,
  0x8D,
  0xB0,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

Future<void> _openSheet(WidgetTester tester, Size window) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showAvatarCropSheet(context, _png),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  for (final window in const [
    Size(1280, 900), // the desktop window an e2e run uses
    Size(1920, 1080), // a wide monitor
    Size(390, 844), // a phone, where width was never the problem
  ]) {
    testWidgets('both actions are on screen at ${window.width.toInt()}x'
        '${window.height.toInt()}', (tester) async {
      await _openSheet(tester, window);

      for (final label in const ['Cancel', 'Use picture']) {
        final finder = find.text(label);
        expect(finder, findsOneWidget, reason: '$label is not in the tree');
        final box = tester.getRect(finder);
        expect(
          box.bottom,
          lessThanOrEqualTo(window.height),
          reason:
              '$label sits ${box.bottom - window.height}pt below the '
              'bottom of a ${window.width.toInt()}x${window.height.toInt()} '
              'window, so it cannot be reached',
        );
        expect(
          box.top,
          greaterThanOrEqualTo(0.0),
          reason:
              '$label is above '
              'the top of the window',
        );
      }
    });
  }

  testWidgets(
    "'Use picture' is the sheet's one filled action, not an outline",
    (tester) async {
      await _openSheet(tester, const Size(1280, 900));

      final button = tester.widget<AppButton>(
        find.widgetWithText(AppButton, 'Use picture'),
      );
      expect(button.variant, AppButtonVariant.primary);
    },
  );
}
