// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Removal, clear, restore and a hard reset: the tombstone set that makes
/// each of them safe to replay, and the two ways a restored id has to be
/// un-blocked before it can be placed again.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput stroke(
  String id, {
  double x = 0,
  double y = 0,
  int zIndex = 0,
  int? seq,
}) =>
    CanvasStrokeInput(
      id: id,
      seq: seq ?? zIndex,
      zIndex: zIndex,
      x: x,
      y: y,
      w: 10,
      h: 10,
      points: const [0, 0, 10, 10],
      width: 3,
      colorKey: 'annotation',
    );

void main() {
  test('removeObject is idempotent and paint order stays correct', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(stroke('a'))
      ..applyPlaced(stroke('b', x: 20))
      ..refresh();
    expect(document.paintOrder, hasLength(2));

    document
      ..removeObject('a')
      ..refresh();
    expect(document.paintOrder, hasLength(1));
    expect(document.objectCount.value, 1);

    document
      ..removeObject('a')
      ..refresh();
    expect(document.paintOrder, hasLength(1));
    expect(
      document.objectCount.value,
      1,
      reason: 'removing the same id twice must not double-decrement',
    );
  });

  test(
    'removing the selected or elevated object clears both, so neither '
    'offers a resize, reorder or shadow for something already gone',
    () {
      final document = CanvasDocument()..setViewport(const Size(800, 600));
      document.applyPlaced(stroke('a'));
      document.selectedObjectId.value = 'a';
      document.elevatedObjectId.value = 'a';

      document.removeObject('a');

      expect(document.selectedObjectId.value, isNull);
      expect(document.elevatedObjectId.value, isNull);
    },
  );

  test('an id removed before ever being placed refuses a later resurrection',
      () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));

    // The removal frame lands first, for an id this document never held.
    document.removeObject('ghost');
    expect(document.objectCount.value, 0);

    final result = document.applyPlaced(stroke('ghost'));
    expect(result, isNull);
    expect(
      document.objectCount.value,
      0,
      reason: 'a tombstoned id must never be materialized',
    );
    expect(document.paintOrder, isEmpty);
  });

  test(
      'a placed-then-removed id refuses resurrection once its tombstone '
      'is evicted', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(stroke('a'))
      ..refresh();
    expect(document.objectCount.value, 1);

    document
      ..removeObject('a')
      ..refresh();
    expect(document.objectCount.value, 0);

    // Push 'a' out of the tombstone, isolating the known-id dead-slot guard.
    for (var i = 0; i < maxRemovedIdsTracked; i++) {
      document.removeObject('evict$i');
    }

    final result = document.applyPlaced(stroke('a'));
    expect(result, isNull);
    expect(document.objectCount.value, 0);
  });

  test('clearBelow spares a locally drawn stroke still carrying seq 0', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(stroke('confirmed', seq: 5, zIndex: 5))
      ..applyPlaced(
          stroke('local', x: 20, seq: 0, zIndex: provisionalLocalZIndex))
      ..refresh();
    expect(document.paintOrder, hasLength(2));

    document
      ..clearBelow(10)
      ..refresh();

    final ids =
        document.paintOrder.map((slot) => document.strokeAt(slot).id).toList();
    expect(
      ids,
      ['local'],
      reason: 'seq 0 must survive a clear, or ink vanishes as it is drawn',
    );
    expect(document.objectCount.value, 1);
  });

  test('a confirmed placement updates seq so a later clear can reach it', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(stroke('a', seq: 0, zIndex: provisionalLocalZIndex))
      ..refresh();

    // The server confirms the same id with its real seq.
    document
      ..applyPlaced(stroke('a', seq: 7, zIndex: 7))
      ..refresh();

    document
      ..clearBelow(10)
      ..refresh();
    expect(document.paintOrder, isEmpty);
    expect(document.objectCount.value, 0);
  });

  test('forgetRemoved lets an id removed before ever being placed be placed',
      () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..removeObject('a')
      ..refresh();
    expect(document.applyPlaced(stroke('a')), isNull);

    document.forgetRemoved(['a']);
    final result = document.applyPlaced(stroke('a'));
    expect(result, isNotNull);
    expect(document.objectCount.value, 1);
  });

  test(
      'forgetRemoved lets a previously placed, then removed, id be placed '
      'again', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(stroke('a'))
      ..removeObject('a')
      ..refresh();
    expect(
      document.applyPlaced(stroke('a')),
      isNull,
      reason: 'the dead-slot guard refuses this on its own, tombstoned or not',
    );

    document.forgetRemoved(['a']);
    final result = document.applyPlaced(stroke('a'));
    expect(
      result,
      isNotNull,
      reason: 'forgetRemoved must drop the stale slot mapping too, or a '
          'restored id can never be re-placed even once its tombstone is '
          'gone',
    );
    expect(document.objectCount.value, 1);
  });

  test('reset empties strokes, tombstones and the index together', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(stroke('a'))
      ..applyPlaced(stroke('b', x: 20))
      ..removeObject('b')
      ..refresh();
    expect(document.objectCount.value, 1);

    document.reset();
    expect(document.objectCount.value, 0);
    expect(document.knows('a'), isFalse);
    expect(document.paintOrder, isEmpty);

    // The tombstone for 'b' is gone too: a fresh fetch after a reset can re-materialize anything still live server-side.
    final result = document.applyPlaced(stroke('b', x: 20));
    expect(result, isNotNull);
  });

  test('isAlive tells a committed placement from a killed one', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(stroke('committed'))
      ..applyPlaced(stroke('failed'))
      ..refresh();
    expect(document.isAlive('committed'), isTrue);
    expect(document.isAlive('unknown'), isFalse);

    document.kill('failed');
    expect(document.isAlive('failed'), isFalse);

    document
      ..removeObject('committed')
      ..refresh();
    expect(document.isAlive('committed'), isFalse);
  });

  test('_removedIds evicts FIFO past the tracked ceiling', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    for (var i = 0; i < maxRemovedIdsTracked; i++) {
      document.removeObject('r$i');
    }
    // The oldest entry has not yet been evicted: one more removal push it out.
    expect(document.applyPlaced(stroke('r0')), isNull);

    document.removeObject('r$maxRemovedIdsTracked');
    // Now the oldest ('r0') has been evicted and no longer refuses a place.
    final result = document.applyPlaced(stroke('r0'));
    expect(result, isNotNull);
  });

  group('scoped clearBelow', () {
    CanvasStrokeInput input(String id, CanvasObjectKind kind, String author) =>
        CanvasStrokeInput(
          id: id,
          seq: 1,
          zIndex: 1,
          x: id.codeUnitAt(0).toDouble(),
          y: 0,
          w: 10,
          h: 10,
          points: const [0, 0, 10, 10],
          width: 3,
          colorKey: 'annotation',
          kind: kind,
          authorId: author,
        );

    CanvasDocument seeded() => CanvasDocument()
      ..setViewport(const Size(800, 600))
      ..applyPlaced(input('a', CanvasObjectKind.stroke, 'ann'))
      ..applyPlaced(input('b', CanvasObjectKind.stroke, 'bob'))
      ..applyPlaced(input('c', CanvasObjectKind.note, 'ann'))
      ..refresh();

    test('by kind leaves the other kinds', () {
      final document = seeded()
        ..clearBelow(5, kinds: {CanvasObjectKind.stroke});

      expect(document.isAlive('a'), isFalse);
      expect(document.isAlive('b'), isFalse);
      expect(document.isAlive('c'), isTrue);
    });

    test('by author leaves everyone else', () {
      final document = seeded()..clearBelow(5, authorId: 'ann');

      expect(document.isAlive('a'), isFalse);
      expect(document.isAlive('b'), isTrue);
      expect(document.isAlive('c'), isFalse);
    });

    test('authorIds lists only who still has something on the board', () {
      final document = seeded();
      expect(document.authorIds(), {'ann', 'bob'});

      document.clearBelow(5, authorId: 'bob');
      expect(document.authorIds(), {'ann'});
    });
  });
}
