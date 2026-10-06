// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A pane that remounts while its channel is still fullscreen must come back
/// with the pen disarmed, not drawing under a folded tool strip.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/screens/canvas/canvas_fullscreen.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';

void main() {
  testWidgets('remounting a fullscreen pane keeps the pen disarmed', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    expect(
      tester.widget<CanvasSurface>(find.byType(CanvasSurface)).tool,
      CanvasTool.pen,
    );

    await tester.tap(find.byTooltip('More canvas actions'));
    await tester.pump();
    await tester.tap(find.text('Enter fullscreen'));
    await tester.pumpAndSettle();
    expect(container.read(canvasFullscreenProvider), 'c1');

    // leave the channel (pane unmounts; the provider is app-global)
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SizedBox())),
      ),
    );
    await tester.pump();
    expect(container.read(canvasFullscreenProvider), 'c1');

    // come back
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();
    expect(container.read(canvasFullscreenProvider), 'c1');
    expect(find.bySemanticsLabel('Pen'), findsNothing, reason: 'strip folded');
    expect(
      tester.widget<CanvasSurface>(find.byType(CanvasSurface)).tool,
      CanvasTool.pan,
      reason: 'fullscreen with the tool strip folded arms no drawing tool',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(container.read(canvasFullscreenProvider), isNull);
    expect(
      tester.widget<CanvasSurface>(find.byType(CanvasSurface)).tool,
      CanvasTool.pen,
      reason: 'leaving fullscreen restores the default tool',
    );
  });
}
