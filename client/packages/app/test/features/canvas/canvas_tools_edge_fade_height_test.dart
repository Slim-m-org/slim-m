// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The tool strip's edge fade is as tall as the strip, not as tall as the room around it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_tools_row.dart';

import '../../support/canvas_tools_row_fixtures.dart';

void main() {
  testWidgets('the fade matches the strip height in a tall room', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      wrapCanvasToolsRow(buildCanvasToolsRow(), width: 270, touch: true),
    );
    await tester.pump(const Duration(milliseconds: 400));
    final fade = tester.getRect(find.byKey(canvasToolsTrailingFadeKey));
    expect(fade.height, lessThan(80), reason: '$fade in a 780dp room');
  });
}
