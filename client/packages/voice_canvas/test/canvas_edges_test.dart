// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The edges a document holds: following their ends, and what a removal, a clear, a restore and a drop do to them.
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput note(String id, double x, {int seq = 1}) => CanvasStrokeInput(
      id: id,
      seq: seq,
      zIndex: seq,
      x: x,
      y: 0,
      w: 100,
      h: 50,
      points: const [],
      width: 0,
      colorKey: 'note',
      kind: CanvasObjectKind.note,
      text: id,
      authorId: 'u1',
    );

CanvasEdgeInput edge(String id, String a, String b,
        {int seq = 10, Rect? hull}) =>
    CanvasEdgeInput(
      id: id,
      seq: seq,
      zIndex: seq,
      authorId: 'u1',
      spec: CanvasEdgeSpec(from: AttachedEnd(a), to: AttachedEnd(b)),
      hull: hull ?? const Rect.fromLTWH(0, 0, 400, 50),
    );

CanvasDocument board() {
  final document = CanvasDocument()..setViewport(const Size(800, 600));
  document
    ..applyPlaced(note('a', 0))
    ..applyPlaced(note('b', 300, seq: 2))
    ..applyPlaced(note('c', 600, seq: 3))
    ..refresh();
  return document;
}

void main() {
  test('an edge is routed from the boxes its ends are drawn at right now', () {
    final document = board();
    document.edges.applyPlaced(edge('e', 'a', 'b'));
    final first = document.edges.routeOf(document.edges.liveEdge('e')!)!;
    expect(first.end, const Offset(300, 25));
    document.moveObject('b', 300, 200, 100, 50);
    final moved = document.edges.routeOf(document.edges.liveEdge('e')!)!;
    expect(moved.end.dy, isNot(first.end.dy));
  });

  test('an edge whose end is not held yet is neither routed nor hit', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document.applyPlaced(note('a', 0));
    document.edges.applyPlaced(edge('e', 'a', 'b'));
    final held = document.edges.liveEdge('e')!;
    expect(document.edges.routeOf(held), isNull);
    expect(document.edges.hitEdge(const Offset(150, 25), zoom: 1), isNull);
    document.applyPlaced(note('b', 300, seq: 2));
    expect(document.edges.routeOf(held), isNotNull);
  });

  test('erasing an end takes its edges and tombstones them at the op seq', () {
    final document = board();
    document.edges.applyPlaced(edge('e', 'a', 'b'));
    document.removeObject('a', seq: 20);
    expect(document.edges.isAlive('e'), isFalse);
    expect(document.edges.wasRemoved('e'), isTrue);
    expect(document.edges.applyPlaced(edge('e', 'a', 'b')), isNull);
  });

  test('a restore forgets the edge tombstone so the edge can come back', () {
    final document = board();
    document.edges.applyPlaced(edge('e', 'a', 'b'));
    document.removeObject('a', seq: 20);
    document.forgetRemoved(['a', 'e']);
    document.applyPlaced(note('a', 0), overwrite: true);
    expect(document.edges.applyPlaced(edge('e', 'a', 'b'), overwrite: true),
        isNotNull);
    expect(document.edges.isAlive('e'), isTrue);
  });

  test('a clear takes only the edges whose held end it cleared', () {
    final document = board();
    document.edges
      ..applyPlaced(edge('ab', 'a', 'b', seq: 10))
      ..applyPlaced(edge('bc', 'b', 'c', seq: 11));
    document.clearBelow(1, kinds: {CanvasObjectKind.note}, opSeq: 30);
    expect(document.edges.isAlive('ab'), isFalse, reason: 'a was cleared');
    expect(document.edges.isAlive('bc'), isTrue, reason: 'b and c survive');
  });

  test(
      'an unscoped clear takes the edges at or below its fence and spares newer ones',
      () {
    final document = board();
    document.edges
      ..applyPlaced(edge('old', 'a', 'b', seq: 5))
      ..applyPlaced(edge('new', 'b', 'c', seq: 50));
    document.clearBelow(10, opSeq: 60);
    expect(document.edges.isAlive('old'), isFalse);
    expect(document.edges.isAlive('new'), isFalse,
        reason: 'b and c were cleared');
  });

  test('dropping an end frees its edges without a tombstone', () {
    final document = board();
    document.edges.applyPlaced(edge('e', 'a', 'b'));
    document.dropObjects(['a']);
    expect(document.edges.isAlive('e'), isFalse);
    expect(document.edges.wasRemoved('e'), isFalse);
  });

  test('an edit merges: an absent key stays and null deletes', () {
    final document = board();
    document.edges.applyPlaced(edge('e', 'a', 'b'));
    document.edges.applyEdited('e', {'label': 'needs', 'color': 'amber'});
    var spec = document.edges.liveEdge('e')!.spec;
    expect((spec.label, spec.colorKey, spec.arrow),
        ('needs', 'amber', EdgeArrow.end));
    document.edges.applyEdited('e', {'label': null, 'arrow': 'both'});
    spec = document.edges.liveEdge('e')!.spec;
    expect((spec.label, spec.colorKey, spec.arrow),
        (null, 'amber', EdgeArrow.both));
    expect(document.edges.attachedTo('b').single.id, 'e');
  });

  test(
      'a region read sees the hull of the held ends, and the wire hull while an end is missing',
      () {
    final document = board();
    document.edges.applyPlaced(
        edge('e', 'a', 'b', hull: const Rect.fromLTWH(0, 0, 1, 1)));
    Rect hullOfLive() =>
        document.liveObjects().firstWhere((o) => o.id == 'e').box;
    expect(hullOfLive(), const Rect.fromLTWH(0, 0, 400, 50));
    document.moveObject('b', 300, 400, 100, 50);
    expect(hullOfLive(), const Rect.fromLTWH(0, 0, 400, 450));
    document.dropObjects(['b']);
    document.edges.applyPlaced(
        edge('e2', 'a', 'z', hull: const Rect.fromLTWH(5, 5, 6, 6)));
    expect(document.liveObjects().firstWhere((o) => o.id == 'e2').box,
        const Rect.fromLTWH(5, 5, 6, 6));
  });

  test('a hit lands on the line and on a label, not beside them', () {
    final document = board();
    document.edges.applyPlaced(edge('e', 'a', 'b'));
    final route = document.edges.routeOf(document.edges.liveEdge('e')!)!;
    expect(document.edges.hitEdge(route.midpoint, zoom: 1), 'e');
    expect(
        document.edges.hitEdge(route.midpoint + const Offset(0, 60), zoom: 1),
        isNull);
    expect(
        document.edges
            .hitEdge(route.midpoint + const Offset(0, 9), zoom: 1, touch: true),
        'e');
  });

  test(
      'selecting an edge is independent of the object selection and reset clears it',
      () {
    final document = board();
    document.edges.applyPlaced(edge('e', 'a', 'b'));
    document.selectedObjectId.value = 'e';
    expect(document.edges.selected?.id, 'e');
    document.reset();
    expect(document.edges.selected, isNull);
    expect(document.edges.liveCount, 0);
  });

  test(
      'a repeated placement reply does not undo a reorder that landed after it',
      () {
    final document = board();
    document.edges.applyPlaced(edge('e', 'a', 'b'));
    document.edges.setZIndex('e', 99);
    document.edges.applyPlaced(edge('e', 'a', 'b'));
    expect(document.edges.liveEdge('e')!.zIndex, 99);
  });
}
