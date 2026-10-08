// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas surface's own semantics node stays a plain labelled region.
///
/// The zoom chip's "Fit view" button once lost `container: true` and merged
/// into this node, turning the whole surface into one tappable button. On web
/// that node then took every pointer event, so no stroke, drag or note could
/// reach the canvas underneath it.
library;

import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'canvas_pane_harness.dart';

void main() {
  testWidgets('the surface is not a button, and Fit view is its own node', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);

    final surface = tester
        .getSemantics(find.bySemanticsLabel(RegExp(r'^Canvas, ')))
        .getSemanticsData();
    expect(surface.label, isNot(contains('Fit view')));
    expect(surface.flagsCollection.isButton, isFalse);
    expect(surface.hasAction(SemanticsAction.tap), isFalse);

    final fit = tester
        .getSemantics(find.bySemanticsLabel(RegExp(r'^Fit view, zoom ')))
        .getSemanticsData();
    expect(fit.flagsCollection.isButton, isTrue);
    expect(fit.hasAction(SemanticsAction.tap), isTrue);
    semantics.dispose();
  });
}
