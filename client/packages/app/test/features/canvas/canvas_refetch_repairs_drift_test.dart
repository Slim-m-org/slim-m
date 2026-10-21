// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A re-read of the board must repair a viewer whose copy drifted.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';

import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';

void main() {
  test(
    'a second read corrects a known note whose text and box changed',
    () async {
      final fixture = CanvasPaneFixture()
        ..objects = [canvasNoteJson('n', text: 'old', x: 10)];
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      final sub = container.listen(canvasEngineProvider('c1'), (_, _) {});
      addTearDown(sub.close);
      final engine = container.read(canvasEngineProvider('c1').notifier);
      await container.pump();
      await engine.fetch();
      expect(engine.document.noteTextOf('n'), 'old');

      fixture.objects = [canvasNoteJson('n', text: 'new', x: 300)];
      await engine.fetch();

      expect(
        engine.document.noteTextOf('n'),
        'new',
        reason: 'applyPlaced only refreshes z and seq for a known id',
      );
    },
  );
}
