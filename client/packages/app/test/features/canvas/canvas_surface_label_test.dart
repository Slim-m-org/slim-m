// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas surface is announced as "Canvas, ..." and nothing else: the view
/// pill's tooltip once merged into it, so a screen reader read the whole board
/// as "Move and zoom for yourself only, Canvas, no objects".
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'canvas_pane_harness.dart';

void main() {
  testWidgets('the surface label is only the canvas summary', (tester) async {
    final handle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container, board: true, tool: null);

    final surface = find.bySemanticsLabel(RegExp(r'Canvas, '));
    expect(surface, findsOneWidget);
    final node = tester.getSemantics(surface);
    expect(node.label, startsWith('Canvas, '));
    // The web engine reads a node's tooltip into its aria-label, ahead of the label.
    expect(node.tooltip, isEmpty);
    expect(
      find.bySemanticsLabel(RegExp(r'^Shared view, switch to personal$')),
      findsOneWidget,
    );
    handle.dispose();
  });
}
