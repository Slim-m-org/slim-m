// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the document's own algorithms cost as a board grows: building it,
/// re-sorting paint order after one placement, listing the visible ids a drag
/// snaps against, and hit testing in a crowd.
///
/// Run with `flutter test benchmark/document_cost_benchmark.dart`. This is a
/// debug JIT build, so read the growth between sizes more than the absolute
/// figure; `profile/` holds the profile-mode window run.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'board_fixture.dart';
import 'perf_support.dart';

Dist _repeat(int n, void Function() body) {
  final out = <double>[];
  for (var i = 0; i < n + 3; i++) {
    final sw = Stopwatch()..start();
    body();
    if (i >= 3) out.add(sw.elapsedMicroseconds.toDouble());
  }
  return Dist(out);
}

void main() {
  final log = PerfLog('document_cost');
  tearDownAll(log.flush);

  for (final count in [1000, 5000, 10000, 20000]) {
    test('document algorithms at $count strokes', () {
      final inputs = boardInputs(BoardSpec(strokes: count, notes: 200));
      final built = Stopwatch()..start();
      final doc = CanvasDocument()..setBoard(canvasBoard);
      inputs.forEach(doc.applyPlaced);
      doc
        ..setViewport(const Size(1600, 900))
        ..refresh();
      log.value('build the document from $count strokes+200 notes (ms)',
          built.elapsedMicroseconds / 1000);

      log.add(
          'paintOrder after one placement, $count strokes',
          _repeat(30, () {
            doc.applyPlaced(
              CanvasStrokeInput(
                id: 'extra-${DateTime.now().microsecondsSinceEpoch}',
                seq: 0,
                zIndex: provisionalLocalZIndex,
                x: 100,
                y: 100,
                w: 10,
                h: 10,
                points: const [0, 0, 10, 10],
                width: 3,
                colorKey: 'ink',
              ),
            );
            doc.paintOrder.length;
          }));
      log.add('paintOrder, nothing changed, $count strokes',
          _repeat(60, () => doc.paintOrder.length));
      log.add('visibleIds at fit zoom (a drag snaps against this), $count',
          _repeat(30, () => doc.visibleIds.length));
      log.add('liveCountsByKind (the activity summary), $count',
          _repeat(30, () => doc.liveCountsByKind));

      const crowd = Offset(960, 540);
      log.add(
          'hitTestStroke in the middle of the crowd, $count',
          _repeat(60, () {
            hitTestStroke(doc, crowd, allowed: (_) => true);
          }));
      log.add(
          'hitTestStroke that misses everything, $count',
          _repeat(60, () {
            hitTestStroke(doc, const Offset(5, 5), allowed: (_) => true);
          }));
      doc.dispose();
    });
  }
}
