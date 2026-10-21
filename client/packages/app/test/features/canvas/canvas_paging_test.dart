// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The first read of a canvas: the visible area first, then the rest of the
/// board in the background, with a quiet count while it arrives.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_board_pager.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_paging_indicator.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import 'canvas_pane_harness.dart';

Widget _indicator(CanvasPaging paging) => MaterialApp(
  theme: ThemeData(extensions: const [AppTokens.light]),
  home: Scaffold(body: CanvasPagingIndicator(paging: paging)),
);

void main() {
  testWidgets('the indicator says how much has arrived and of how many', (
    tester,
  ) async {
    await tester.pumpWidget(
      _indicator(const CanvasPaging(loaded: 120, total: 480)),
    );
    expect(find.text('120 / 480 objects'), findsOneWidget);

    await tester.pumpWidget(_indicator(const CanvasPaging(loaded: 120)));
    expect(find.text('120 objects loaded'), findsOneWidget);
  });

  testWidgets('the visible area loads first and the rest follows', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture()..objects = [canvasObjectJson('a')];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await tester.runAsync(() async {
      await pumpCanvasPane(tester, container);
    });
    await waitUntil(
      tester,
      () => surfaceDocument(tester).objectCount.value == 1,
      reason: 'the visible read applied',
    );

    await waitUntil(
      tester,
      () => container.read(canvasEngineProvider('c1')).paging == null,
      reason: 'the rest was read and the count went away',
    );

    expect(
      fixture.viewportGets,
      greaterThan(1),
      reason: 'the board and its surroundings are read after the view',
    );
    expect(container.read(canvasEngineProvider('c1')).truncated, isFalse);
  });
}
