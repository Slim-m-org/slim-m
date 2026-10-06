// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A stored stroke whose props carry the wrong types must cost the canvas
/// that one stroke, not the whole load: before this, the cast threw inside
/// the viewport loop, `loading` stayed true and the catch-up never ran.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/screens/canvas/canvas_engine.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';

void main() {
  testWidgets('a page with a wrong-typed stroke still finishes loading and '
      'paints the good objects', (tester) async {
    final poisoned = canvasObjectJson('bad', x: 30, seq: 2)
      ..['props'] = {
        'points': [0.0, 0.0, 20.0, 20.0],
        'color': 5,
        'width': 'x',
      };
    final fixture = CanvasPaneFixture()
      ..objects = [canvasObjectJson('good'), poisoned];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);

    await pumpCanvasPane(tester, container);

    expect(container.read(canvasEngineProvider('c1')).loading, isFalse);
    expect(fixture.opsGets, greaterThan(0), reason: 'catch-up never ran');
    final document = surfaceDocument(tester);
    expect(document.isAlive('good'), isTrue);
    expect(document.isAlive('bad'), isTrue);
  });
}
