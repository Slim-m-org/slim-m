// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A departing pane must not tear down the engine a second pane for the same
/// channel is still using (the A to B to A switch inside the page fade).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_design_system/design_system.dart';

import 'features/canvas/canvas_pane_harness.dart';

void main() {
  testWidgets('a departing pane leaves the shared engine alive', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);

    Widget app(List<Widget> panes) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(body: Stack(children: panes)),
      ),
    );

    await tester.pumpWidget(
      app(const [
        CanvasPane(key: ValueKey('old'), channelId: 'c1'),
        CanvasPane(key: ValueKey('new'), channelId: 'c1'),
      ]),
    );
    await tester.pump();
    await tester.pump();
    final engine = container.read(canvasEngineProvider('c1').notifier);
    expect(engine.mounted, isTrue);

    await tester.pumpWidget(
      app(const [CanvasPane(key: ValueKey('new'), channelId: 'c1')]),
    );
    await tester.pump();

    expect(
      container.read(canvasEngineProvider('c1').notifier).mounted,
      isTrue,
      reason: 'the surviving pane still watches this engine',
    );
  });
}
