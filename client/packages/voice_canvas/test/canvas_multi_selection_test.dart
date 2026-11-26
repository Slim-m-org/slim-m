// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasMultiSelection] and [objectIdsInRect]: what a drag box picks and how a group pick sits beside the single selection.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _box(
  String id,
  double x,
  double y, {
  CanvasObjectKind kind = CanvasObjectKind.note,
}) =>
    CanvasStrokeInput(
      id: id,
      seq: 1,
      zIndex: 1,
      x: x,
      y: y,
      w: 40,
      h: 40,
      points: const [],
      width: 1,
      colorKey: 'annotation',
      kind: kind,
      text: kind == CanvasObjectKind.note ? 'n' : null,
    );

CanvasDocument _board() {
  final document = CanvasDocument()..setViewport(const Size(800, 600));
  document
    ..applyPlaced(_box('a', 0, 0))
    ..applyPlaced(_box('b', 100, 0))
    ..applyPlaced(_box('far', 500, 500))
    ..applyPlaced(
      const CanvasStrokeInput(
        id: 'ink',
        seq: 1,
        zIndex: 1,
        x: 20,
        y: 20,
        w: 10,
        h: 10,
        points: [0, 0, 10, 10],
        width: 3,
        colorKey: 'annotation',
      ),
    )
    ..refresh();
  return document;
}

void main() {
  test('a box picks the notes it touches and leaves ink and far ones out', () {
    final document = _board();

    final picked =
        objectIdsInRect(document, const Rect.fromLTWH(-5, -5, 160, 60));

    expect(picked, unorderedEquals(['a', 'b']));
  });

  test('a box can be refused an object, as a lock is', () {
    final document = _board();

    final picked = objectIdsInRect(
      document,
      const Rect.fromLTWH(-5, -5, 160, 60),
      accepts: (id) => id != 'b',
    );

    expect(picked, ['a']);
  });

  test('two picked objects leave the single selection empty', () {
    final document = _board()..selectedObjectId.value = 'far';

    document.multiSelection.select(['a', 'b']);

    expect(document.selectedObjectId.value, isNull);
    expect(document.multiSelection.ids.value, {'a', 'b'});
  });

  test('one picked object is the ordinary single selection', () {
    final document = _board();

    document.multiSelection.select(['a']);

    expect(document.selectedObjectId.value, 'a');
    expect(document.multiSelection.ids.value, isEmpty);
  });

  test('selecting one object by itself drops a group pick', () {
    final document = _board();
    document.multiSelection.select(['a', 'b']);

    document.selectedObjectId.value = 'far';

    expect(document.multiSelection.ids.value, isEmpty);
  });

  test('toggle adds and removes, and falls back to a single selection', () {
    final document = _board();
    document.selectedObjectId.value = 'a';

    document.multiSelection.toggle('b');
    expect(document.multiSelection.ids.value, {'a', 'b'});

    document.multiSelection.toggle('a');
    expect(document.selectedObjectId.value, 'b');
    expect(document.multiSelection.ids.value, isEmpty);
  });

  test('an object removed from the board leaves the group', () {
    final document = _board();
    document.multiSelection.select(['a', 'b', 'far']);

    document
      ..removeObject('far')
      ..refresh();

    expect(document.multiSelection.ids.value, {'a', 'b'});
  });
}
