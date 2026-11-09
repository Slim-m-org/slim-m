// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The paint order is spliced for a few edits and must always equal a full sort.
library;

import 'dart:math';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_paint_order.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _stroke(String id, int zIndex, int seq) => CanvasStrokeInput(
      id: id,
      seq: seq,
      zIndex: zIndex,
      x: 0,
      y: 0,
      w: 10,
      h: 10,
      points: const [],
      width: 2,
      colorKey: 'ink',
    );

List<String> _ids(CanvasDocument document) => [
      for (final slot in document.paintOrder) document.strokeAt(slot).id,
    ];

/// What a full sort of every live object gives, the reference the cache must match.
List<String> _sorted(CanvasDocument document) {
  final slots = [
    for (var slot = 0; slot < document.scene.slotCount; slot++)
      if (document.strokeIfAlive(slot) != null) slot,
  ]..sort(document.comparePaintOrder);
  return [for (final slot in slots) document.strokeAt(slot).id];
}

void main() {
  test('a long run of random edits keeps the order equal to a full sort', () {
    final random = Random(1108);
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    addTearDown(document.dispose);
    final known = <String>[];
    var next = 0;
    var seq = 1;

    for (var step = 0; step < 1500; step++) {
      final pick = random.nextInt(8);
      if (pick < 3 || known.isEmpty) {
        final id = 'o${next++}';
        known.add(id);
        document.applyPlaced(_stroke(id, random.nextInt(6), seq++));
      } else if (pick == 3) {
        document.removeObject(known.removeAt(random.nextInt(known.length)));
      } else if (pick == 4) {
        document.kill(known[random.nextInt(known.length)]);
      } else if (pick == 5) {
        document.setZIndex(
            known[random.nextInt(known.length)], random.nextInt(6));
      } else if (pick == 6) {
        final id = known[random.nextInt(known.length)];
        document.applyPlaced(_stroke(id, random.nextInt(6), seq++),
            overwrite: true);
      } else {
        final id = known[random.nextInt(known.length)];
        document.applyPlaced(_stroke(id, 0, 0));
      }
      document.refresh();
      if (random.nextInt(3) == 0) {
        expect(_ids(document), _sorted(document), reason: 'step $step');
      }
    }
    expect(_ids(document), _sorted(document));
  });

  test('a burst of edits past the splice limit still ends fully sorted', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    addTearDown(document.dispose);
    for (var i = 0; i < 50; i++) {
      document.applyPlaced(_stroke('a$i', i % 5, i + 1));
    }
    document.refresh();
    _ids(document);

    for (var i = 0; i < 300; i++) {
      document.applyPlaced(_stroke('b$i', (i * 7) % 5, 100 + i));
    }
    document.refresh();

    expect(_ids(document), _sorted(document));
  });

  test('one new object costs a search, not a sort of every slot', () {
    final cache = PaintOrderCache();
    var compares = 0;
    final keys = <int, int>{for (var slot = 0; slot < 5000; slot++) slot: slot};
    int compare(int a, int b) {
      compares++;
      return keys[a]!.compareTo(keys[b]!);
    }

    List<int> order() => cache.order(
          slotCount: keys.length,
          isAlive: (_) => true,
          compare: compare,
          visible: keys.keys,
        );
    order();

    keys[5000] = 5000;
    cache.added(5000);
    compares = 0;
    order();
    expect(compares, lessThan(5),
        reason: 'appending above the top is one check');

    keys[5001] = -1;
    cache.added(5001);
    compares = 0;
    final result = order();
    expect(compares, lessThan(40),
        reason: 'a binary search is about 13 checks');
    expect(result.first, 5001);
    expect(result.length, 5002);
  });
}
