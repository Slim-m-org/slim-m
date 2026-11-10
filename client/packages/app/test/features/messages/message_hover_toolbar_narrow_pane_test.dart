// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The hover toolbar beside an author line in a narrow docked pane.
///
/// `desktop-vs-mobile.md` law 1: the reserve follows the window width, so a
/// pane under 500dp inside a 1280 window still gets all of it. The line gives
/// the reserve up only once its name could not stay readable.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'message_hover_toolbar_support.dart';
import 'message_row_harness.dart';

Future<void> _hoverInPane(WidgetTester tester, double pane) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    harness(
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: pane,
          child: hoverRow(
            message(
              authorDisplayName: 'Alexandria Montgomery',
              content: 'the disk is nearly full',
            ),
          ),
        ),
      ),
    ),
  );
  final mouse = await hoverMouse(tester);
  await hoverHover(tester, mouse, find.byKey(const ValueKey('m1')));
}

void main() {
  for (final pane in const [420.0, 470.0, 500.0]) {
    testWidgets(
      'the toolbar never covers the author line in a ${pane.toInt()}dp pane',
      (tester) async {
        await _hoverInPane(tester, pane);

        final plate = tester.getRect(hoverPlate);
        expect(hoverHeaderTextRects(tester), isNotEmpty);
        for (final text in hoverHeaderTextRects(tester)) {
          expect(plate.overlaps(text), isFalse, reason: '$text under $plate');
        }
      },
    );
  }
}
