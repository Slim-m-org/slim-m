// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A scope this client cannot read removes nothing locally, rather than
/// reading as every kind.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/widgets/canvas_clear_scope.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  CanvasDocument seeded() => CanvasDocument()
    ..setViewport(const Size(800, 600))
    ..applyPlaced(
      CanvasStrokeInput(
        id: 'ink',
        seq: 1,
        zIndex: 1,
        x: 0,
        y: 0,
        w: 10,
        h: 10,
        points: const [0, 0, 10, 10],
        width: 3,
        colorKey: 'ink',
      ),
    );

  test('a scope naming only unknown kinds leaves the canvas alone', () {
    final document = seeded();

    clearDocumentScope(
      document,
      5,
      const api.CanvasClearScope(kinds: ['hologram']),
    );

    expect(document.isAlive('ink'), isTrue);
  });

  test('a known kind and the whole canvas still clear', () {
    final byKind = seeded();
    clearDocumentScope(
      byKind,
      5,
      const api.CanvasClearScope(kinds: ['stroke']),
    );
    expect(byKind.isAlive('ink'), isFalse);

    final all = seeded();
    clearDocumentScope(all, 5, api.CanvasClearScope.everything);
    expect(all.isAlive('ink'), isFalse);
  });
}
