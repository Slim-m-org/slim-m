// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shared side-pane reveal: content fades and drifts in from the edge
/// its pane lives on, and reduce motion lands it settled on frame one.
///
/// The mid-flight reads are the load-bearing assertions: a target-property
/// read (opacity 1, offset zero) passes even with the animation deleted,
/// which is exactly the vacuous shape this suite's own audits keep finding.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/app_panel_reveal.dart';

Future<void> _pump(
  WidgetTester tester, {
  required bool fromLeft,
  bool reduceMotion = false,
}) => tester.pumpWidget(
  MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: AppPanelReveal(fromLeft: fromLeft, child: const Text('pane')),
    ),
  ),
);

double _opacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find.descendant(
        of: find.byType(AppPanelReveal),
        matching: find.byType(Opacity),
      ),
    )
    .opacity;

double _dx(WidgetTester tester) => tester
    .widget<Transform>(
      find.descendant(
        of: find.byType(AppPanelReveal),
        matching: find.byType(Transform),
      ),
    )
    .transform
    .getTranslation()
    .x;

void main() {
  testWidgets('the content is mid-fade while the reveal plays', (tester) async {
    await _pump(tester, fromLeft: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final opacity = _opacity(tester);
    expect(opacity, greaterThan(0));
    expect(opacity, lessThan(1));
    await tester.pumpAndSettle();
    expect(_opacity(tester), 1);
    expect(_dx(tester), 0);
  });

  testWidgets('the drift comes from the edge the pane lives on', (
    tester,
  ) async {
    await _pump(tester, fromLeft: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(_dx(tester), lessThan(0));
    await tester.pumpAndSettle();

    // A fresh mount, or the first reveal's finished state would carry over.
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, fromLeft: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(_dx(tester), greaterThan(0));
    await tester.pumpAndSettle();
  });

  testWidgets('reduce motion lands settled on the first frame', (tester) async {
    await _pump(tester, fromLeft: true, reduceMotion: true);
    await tester.pump();
    expect(_opacity(tester), 1);
    expect(_dx(tester), 0);
  });
}
