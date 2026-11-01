// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The what's-new dialog's proportions on a desktop-sized window.
///
/// From the backlog: "whats new page is not a desktop focused UI". The width
/// is not the problem - `desktop-vs-mobile.md` rule 4 prescribes a centered
/// dialog of at most 460 and this uses it. The height was: a fraction of the
/// window with no ceiling, so the taller the monitor the taller the dialog,
/// and on a large screen a 460-wide box grew past 800 tall. That is a phone
/// screen stretched, not a desktop dialog.
///
/// Measured through `whatsNewBodyBoxKey`, which exists for exactly this - the
/// file's own comment says so rather than inferring the shape from a
/// screenshot.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/whats_new/whats_new_content.dart';
import 'package:slimm_app/src/widgets/whats_new_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

Future<Size> _bodySizeAt(WidgetTester tester, Size window) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showWhatsNewSheet(context, whatsNewEntries),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return tester.getSize(find.byKey(whatsNewBodyBoxKey));
}

void main() {
  testWidgets('a tall monitor does not make it a tall strip', (tester) async {
    final size = await _bodySizeAt(tester, const Size(2560, 1440));

    expect(
      size.height,
      lessThanOrEqualTo(560),
      reason:
          'unbounded, 0.6 of a 1440-tall window is 864 - a 460-wide box '
          'that tall reads as a phone screen stretched',
    );
    expect(
      size.height / size.width,
      lessThan(1.6),
      reason: 'a desktop dialog should not be twice as tall as it is wide',
    );
  });

  testWidgets('a phone is unchanged: the fraction still governs there', (
    tester,
  ) async {
    final size = await _bodySizeAt(tester, const Size(390, 844));
    expect(
      size.height,
      lessThanOrEqualTo(844 * 0.6 + 1),
      reason: 'the ceiling must not start dictating the phone sheet',
    );
  });
}
