// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every arrival order of the events that decide whether an object is on a board, not a random sample of them.
/// The fuzz test reaches a bad order by luck; here each legal order of a small history is applied and checked against what the server holds.
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _note(int seq, {String text = 'a'}) => CanvasStrokeInput(
      id: 'a',
      seq: seq,
      zIndex: seq,
      x: 0,
      y: 0,
      w: 10,
      h: 10,
      points: const [],
      width: 3,
      colorKey: 'annotation',
      kind: CanvasObjectKind.note,
      text: text,
    );

class _Event {
  _Event(this.name, this.apply);

  final String name;
  final void Function(CanvasDocument document) apply;
}

/// Every order of [events] that keeps each `(first, second)` pair of [mustPrecede] in sequence.
Iterable<List<_Event>> _legalOrders(
  List<_Event> events,
  List<(String, String)> mustPrecede,
) sync* {
  Iterable<List<_Event>> build(List<_Event> placed, List<_Event> left) sync* {
    if (left.isEmpty) {
      yield placed;
      return;
    }
    for (final next in left) {
      final blocked = mustPrecede.any(
        (rule) => rule.$2 == next.name && left.any((e) => e.name == rule.$1),
      );
      if (blocked) continue;
      yield* build(
        [...placed, next],
        [
          for (final e in left)
            if (e != next) e
        ],
      );
    }
  }

  yield* build(const [], events);
}

String _trace(List<_Event> order) => order.map((e) => e.name).join(' > ');

void _eachOrder({
  required List<_Event> events,
  required List<(String, String)> mustPrecede,
  required bool aliveAtTheEnd,
  required int orders,
}) {
  var count = 0;
  for (final order in _legalOrders(events, mustPrecede)) {
    count++;
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    for (final event in order) {
      event.apply(document);
    }
    expect(
      document.isAlive('a'),
      aliveAtTheEnd,
      reason: 'order: ${_trace(order)}',
    );
    expect(
      document.objectCount.value,
      aliveAtTheEnd ? 1 : 0,
      reason: 'count after: ${_trace(order)}',
    );
    document.dispose();
  }
  expect(count, orders, reason: 'the enumeration changed size');
}

_Event _op(int seq, void Function(CanvasDocument) change, String name) =>
    _Event(name, (d) {
      change(d);
      d.reflectedSeq = seq;
    });

void main() {
  final placed = _op(3, (d) => d.applyPlaced(_note(3)), 'placed@3');
  final removed = _op(5, (d) => d.removeObject('a', seq: 5), 'removed@5');
  final staleSnapshot = _Event(
    'read@4',
    (d) => d.applyPlaced(_note(3), overwrite: true, snapshotSeq: 4),
  );
  final lateReply = _Event('reply@3', (d) => d.applyPlaced(_note(3)));
  final ops = [('placed@3', 'removed@5'), ('placed@3', 'read@4')];

  test('a removal wins over every late read and reply, in any order', () {
    _eachOrder(
      events: [
        placed,
        removed,
        staleSnapshot,
        lateReply,
        _Event(
          'read@4 again',
          (d) => d.applyPlaced(_note(3), overwrite: true, snapshotSeq: 5),
        ),
        _Event('reply@3 again', (d) => d.applyPlaced(_note(3))),
      ],
      mustPrecede: [
        ...ops,
        ('placed@3', 'reply@3'),
        ('placed@3', 'reply@3 again'),
        ('placed@3', 'read@4 again'),
      ],
      aliveAtTheEnd: false,
      orders: 120,
    );
  });

  test('a restore wins over every stale read and reply, in any order', () {
    final restored = _op(7, (d) => d.forgetRemoved(['a']), 'restored@7');
    final restoreRead = _Event(
      'read@8',
      (d) => d.applyPlaced(_note(3), overwrite: true, snapshotSeq: 8),
    );
    _eachOrder(
      events: [
        placed,
        removed,
        restored,
        restoreRead,
        staleSnapshot,
        lateReply
      ],
      mustPrecede: [
        ...ops,
        ('removed@5', 'restored@7'),
        ('restored@7', 'read@8'),
        ('placed@3', 'reply@3'),
      ],
      aliveAtTheEnd: true,
      orders: 20,
    );
  });

  test('a removal made here and confirmed later holds against late reads', () {
    final localRemoval = _Event('removed here', (d) => d.removeObject('a'));
    final confirmed = _op(5, (d) => d.confirmRemoved(['a'], 5), 'confirmed@5');
    _eachOrder(
      events: [
        placed,
        localRemoval,
        confirmed,
        staleSnapshot,
        lateReply,
        _Event(
          'read@5',
          (d) => d.applyPlaced(_note(3), overwrite: true, snapshotSeq: 5),
        ),
      ],
      mustPrecede: [
        ('placed@3', 'removed here'),
        ('removed here', 'confirmed@5'),
        ('placed@3', 'read@4'),
        ('placed@3', 'reply@3'),
      ],
      aliveAtTheEnd: false,
      orders: 72,
    );
  });
}
