// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// C-073: the press that dismisses the canvas context menu must not also act
/// with the armed tool on the surface underneath.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import 'features/canvas/canvas_pane_harness.dart';

void main() {
  testWidgets('a click that dismisses the empty-space menu draws no dot', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    await tester.tapAt(
      screenFor(tester, const Offset(300, 200)),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Add note'), findsOneWidget);

    final tap = await tester.startGesture(
      screenFor(tester, const Offset(200, 120)),
    );
    await tap.up();
    await tester.pumpAndSettle();

    expect(find.text('Add note'), findsNothing);
    expect(fixture.posted, isEmpty);
  });
}
