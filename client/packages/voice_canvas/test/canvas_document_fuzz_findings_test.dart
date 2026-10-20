// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Minimal deterministic reproductions of what `canvas_document_fuzz_test.dart`
/// found, one test per violation. Each states the contract the document's own
/// doc comments promise and fails today.
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _stroke(
  String id, {
  double x = 10,
  double y = 10,
  int seq = 5,
  int? z,
}) =>
    CanvasStrokeInput(
      id: id,
      seq: seq,
      zIndex: z ?? seq,
      x: x,
      y: y,
      w: 40,
      h: 40,
      points: const [0, 0, 40, 40],
      width: 4,
      colorKey: 'annotation',
    );

CanvasDocument _document() =>
    CanvasDocument()..setViewport(const Size(900, 600));

void main() {
  test(
    'kill clears the selection and the elevation of the stroke it gives up on',
    () {
      final document = _document();
      document.applyPlaced(_stroke('a', seq: 0, z: provisionalLocalZIndex));
      document.selectedObjectId.value = 'a';
      document.elevatedObjectId.value = 'a';

      document.kill('a');

      expect(
        document.selectedObjectId.value,
        isNull,
        reason: 'a dead stroke stays selected, so Delete or a resize handle '
            'still targets an object nobody can see',
      );
      expect(document.elevatedObjectId.value, isNull);
    },
  );

  test('reset clears the selection, the elevation and the snap guides', () {
    final document = _document();
    document.applyPlaced(_stroke('a'));
    document.selectedObjectId.value = 'a';
    document.elevatedObjectId.value = 'a';

    document.reset();

    expect(
      document.selectedObjectId.value,
      isNull,
      reason: 'a hard reset empties the board but leaves the selection set',
    );
    expect(document.elevatedObjectId.value, isNull);
  });

  test('objectCount does not drift when a killed stroke is later removed', () {
    final document = _document();
    document.applyPlaced(_stroke('a'));
    document.applyPlaced(_stroke('b', x: 200));
    expect(document.objectCount.value, 2);

    // The commit "failed" for good, then the server's own removal arrives.
    document.kill('a');
    expect(document.objectCount.value, 1);
    document.removeObject('a');

    expect(
      document.objectCount.value,
      1,
      reason:
          'kill already counted a down; removing it must not count it twice',
    );
  });

  test('objectCount does not drift when a clear sweeps a killed stroke', () {
    final document = _document();
    document.applyPlaced(_stroke('a', seq: 3));
    document.applyPlaced(_stroke('b', x: 200, seq: 4));

    document.kill('a');
    document.clearBelow(10);

    expect(
      document.objectCount.value,
      0,
      reason: 'two strokes, one killed, one cleared: nothing is left',
    );
  });

  test('a restore naming a live stroke leaves it live and addressable', () {
    final document = _document();
    document.applyPlaced(_stroke('a'));

    document.forgetRemoved(['a']);

    expect(
      document.isAlive('a'),
      isTrue,
      reason: 'a restore frame for an id that is already on the board (a '
          'replayed or duplicate restore) must be harmless, like every other '
          'replayed op',
    );
    document.applyPlaced(_stroke('a'));
    expect(
      document.liveCountsByKind.strokes,
      1,
      reason: 'placing the same id again must not paint it twice',
    );
    document.removeObject('a');
    document.refresh();
    expect(
      document.paintOrder,
      isEmpty,
      reason: 'removing the id must remove every copy of it',
    );
  });

  test('reviving a killed stroke that sits off the board tracks it again', () {
    final document = _document()..setBoard(canvasBoard);
    // Placed wholly off the shared board: a legacy object its clip hides.
    document.applyPlaced(_stroke('a', x: 5000, y: 5000));
    expect(document.idsOutsideBoard, ['a']);

    document.kill('a');
    expect(document.idsOutsideBoard, isEmpty);
    // The "failed" commit had landed after all and its echo revives it.
    document.applyPlaced(_stroke('a', x: 5000, y: 5000));

    expect(document.isAlive('a'), isTrue);
    expect(
      document.idsOutsideBoard,
      ['a'],
      reason: 'a revived stroke off the board must be offered "bring in"',
    );
    expect(document.outsideBoardCount.value, 1);
  });

  test('a wide stroke can be hit anywhere on its ink', () {
    // Other clients choose the stored width; only this client's own pen is capped.
    final document = _document();
    document.applyPlaced(
      const CanvasStrokeInput(
        id: 'wide',
        seq: 5,
        zIndex: 5,
        x: 500,
        y: 500,
        w: 10,
        h: 0,
        points: [0, 0, 10, 0],
        width: 300,
        colorKey: 'annotation',
      ),
    );

    final edge = hitTestStroke(document, const Offset(500 + 5, 500 + 140));

    expect(
      edge,
      'wide',
      reason: 'the point is 140 from the line and the ink reaches 150, but the '
          'hit test only looks 64 world units past the stroke\'s own box',
    );
  });
}
