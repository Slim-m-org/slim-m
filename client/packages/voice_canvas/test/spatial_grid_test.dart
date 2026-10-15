// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  test('grid and linear scan agree on random worlds', () {
    final rng = Random(7);
    for (var trial = 0; trial < 40; trial++) {
      final cellSize = <double>[64, 256, 2048][trial % 3];
      final grid = UniformGrid(cellSize: cellSize, capacity: 8);
      for (var i = 0; i < 300; i++) {
        final x = -8000 + rng.nextDouble() * 16000;
        final y = -8000 + rng.nextDouble() * 16000;
        final w = 1 + rng.nextDouble() * cellSize * 4;
        final h = 1 + rng.nextDouble() * cellSize * 4;
        grid.insert(x, y, x + w, y + h);
      }

      final cx = -8000 + rng.nextDouble() * 16000;
      final cy = -8000 + rng.nextDouble() * 16000;
      final vw = 10 + rng.nextDouble() * 6000;
      final vh = 10 + rng.nextDouble() * 6000;

      final viaGrid = CullResult();
      final viaLinear = CullResult();
      grid.queryGrid(cx, cy, cx + vw, cy + vh, viaGrid);
      grid.queryLinear(cx, cy, cx + vw, cy + vh, viaLinear);

      expect(viaGrid.slots.toSet(), viaLinear.slots.toSet(),
          reason: 'trial $trial');
      expect(
        viaGrid.slots.length,
        viaGrid.slots.toSet().length,
        reason: 'an object spanning several cells was reported twice',
      );
    }
  });

  test('an object wider than a cell is found from any cell it spans', () {
    final grid = UniformGrid(cellSize: 100);
    grid.insert(0, 0, 1000, 1000);
    final out = CullResult();

    for (final probe in const <double>[5, 450, 950]) {
      grid.queryGrid(probe, probe, probe + 1, probe + 1, out);
      expect(out.slots, <int>[0], reason: 'probe at $probe');
    }
  });

  test('touching edges count as visible, a gap of one pixel does not', () {
    final grid = UniformGrid(cellSize: 100);
    grid.insert(100, 100, 200, 200);
    final out = CullResult();

    grid.queryGrid(0, 0, 100, 100, out);
    expect(out.slots, <int>[0]);

    grid.queryGrid(0, 0, 99, 99, out);
    expect(out.slots, isEmpty);
  });

  test('negative world coordinates do not collide with positive ones', () {
    final grid = UniformGrid(cellSize: 1000);
    grid.insert(-5000, -5000, -4900, -4900);
    grid.insert(5000, 5000, 5100, 5100);
    final out = CullResult();

    grid.queryGrid(-5000, -5000, -4900, -4900, out);
    expect(out.slots, <int>[0]);
    grid.queryGrid(5000, 5000, 5100, 5100, out);
    expect(out.slots, <int>[1]);
  });

  test('growing past the initial capacity keeps every object findable', () {
    final grid = UniformGrid(cellSize: 500, capacity: 2);
    for (var i = 0; i < 50; i++) {
      grid.insert(i * 10.0, 0, i * 10.0 + 5, 5);
    }
    final out = CullResult();
    grid.queryGrid(-1, -1, 1000, 1000, out);
    expect(out.slots.length, 50);
    expect(grid.length, 50);
  });

  test('the adaptive query falls back to linear when zoomed far out', () {
    final grid = UniformGrid(cellSize: 2048, capacity: 64);
    for (var i = 0; i < 64; i++) {
      grid.insert(i * 3000.0, 0, i * 3000.0 + 100, 100);
    }
    final out = CullResult();

    expect(grid.query(0, 0, 2560, 1440, out), CullStrategy.grid);
    expect(
      grid.query(-5000000, -5000000, 5000000, 5000000, out),
      CullStrategy.linear,
      reason: 'probing 23.8M cells to find 64 objects is never the right plan',
    );
    expect(out.slots.length, 64);
  });

  test('a repeated query reuses its result buffer rather than reallocating',
      () {
    final grid = UniformGrid(cellSize: 256);
    grid.insert(0, 0, 10, 10);
    final out = CullResult();

    grid.queryGrid(-1, -1, 100, 100, out);
    final first = out.slots;
    grid.queryGrid(-1, -1, 100, 100, out);
    expect(identical(first, out.slots), isTrue);
    expect(out.slots, <int>[0]);
  });

  /// The property this pins is the one the review caught: a NaN-parked box
  /// makes the rejection test below all-false, which reads as "kept", so a
  /// removed object would be culled back in on every future frame forever.
  test('grid and linear culls agree on random worlds after removals', () {
    final rng = Random(11);
    for (var trial = 0; trial < 40; trial++) {
      final cellSize = <double>[64, 256, 2048][trial % 3];
      final grid = UniformGrid(cellSize: cellSize, capacity: 8);
      final slots = <int>[];
      for (var i = 0; i < 300; i++) {
        final x = -8000 + rng.nextDouble() * 16000;
        final y = -8000 + rng.nextDouble() * 16000;
        final w = 1 + rng.nextDouble() * cellSize * 4;
        final h = 1 + rng.nextDouble() * cellSize * 4;
        slots.add(grid.insert(x, y, x + w, y + h));
      }
      slots.shuffle(rng);
      final removed = slots.take(90).toSet();
      for (final slot in removed) {
        grid.remove(slot);
      }

      final cx = -8000 + rng.nextDouble() * 16000;
      final cy = -8000 + rng.nextDouble() * 16000;
      final vw = 10 + rng.nextDouble() * 6000;
      final vh = 10 + rng.nextDouble() * 6000;

      final viaGrid = CullResult();
      final viaLinear = CullResult();
      grid.queryGrid(cx, cy, cx + vw, cy + vh, viaGrid);
      grid.queryLinear(cx, cy, cx + vw, cy + vh, viaLinear);

      expect(viaGrid.slots.toSet(), viaLinear.slots.toSet(),
          reason: 'trial $trial');
      expect(
        viaGrid.slots.toSet().intersection(removed),
        isEmpty,
        reason: 'a removed slot must never be culled back in, trial $trial',
      );
    }
  });

  test('remove is idempotent', () {
    final grid = UniformGrid(cellSize: 100);
    final a = grid.insert(0, 0, 10, 10);
    grid.insert(200, 200, 210, 210);
    expect(grid.liveLength, 2);

    grid.remove(a);
    expect(grid.liveLength, 1);

    grid.remove(a);
    expect(
      grid.liveLength,
      1,
      reason: 'removing an already-removed slot must not double count',
    );
  });

  test(
      'a removed slot is emitted by neither cull branch, '
      'on either side of the adaptive threshold', () {
    final grid = UniformGrid(cellSize: 100, capacity: 8);
    final slots = <int>[
      for (var i = 0; i < 40; i++) grid.insert(i * 50.0, 0, i * 50.0 + 10, 10),
    ];
    final target = slots[10];
    final entriesBefore = grid.bucketEntries;

    grid.remove(target);
    expect(
      grid.bucketEntries,
      entriesBefore - 1,
      reason: 'the slot must actually leave the bucket it was inserted into',
    );

    final gridOut = CullResult();
    final strategySmall = grid.query(-10, -10, 1010, 20, gridOut);
    expect(strategySmall, CullStrategy.grid);
    expect(gridOut.slots, isNot(contains(target)));

    final linearOut = CullResult();
    final strategyLarge = grid.query(-1e7, -1e7, 1e7, 1e7, linearOut);
    expect(strategyLarge, CullStrategy.linear);
    expect(linearOut.slots, isNot(contains(target)));
  });

  test('the adaptive threshold compares against _count, not liveLength', () {
    final grid = UniformGrid(cellSize: 1, capacity: 128);
    final slots = <int>[
      for (var i = 0; i < 100; i++) grid.insert(0, 0, 0.1, 0.1),
    ];
    for (var i = 0; i < 90; i++) {
      grid.remove(slots[i]);
    }
    expect(grid.liveLength, 10);

    final out = CullResult();
    final strategy = grid.query(0, 0, 49, 0.5, out);
    expect(
      strategy,
      CullStrategy.grid,
      reason: 'span (50) sits under length (100); using liveLength (10) '
          'would wrongly pick linear',
    );
  });

  /// [UniformGrid.move] against the same oracle the insert path already uses.
  ///
  /// The risk it exists for is a desynchronised bucket: `move` skips the
  /// bucket work when a box stays inside the cells it already spanned, so a
  /// wrong comparison there leaves an object indexed at its old cells and
  /// findable only by the linear scan. Random moves across a world with a
  /// small cell size hit both the same-cell and the crossing case.
  test('moved boxes stay findable, and the two scans still agree', () {
    final rng = Random(11);
    for (var trial = 0; trial < 40; trial++) {
      final cellSize = <double>[64, 256, 2048][trial % 3];
      final grid = UniformGrid(cellSize: cellSize, capacity: 8);
      final slots = <int>[];
      for (var i = 0; i < 120; i++) {
        final x = -4000 + rng.nextDouble() * 8000;
        final y = -4000 + rng.nextDouble() * 8000;
        final w = 1 + rng.nextDouble() * cellSize * 3;
        final h = 1 + rng.nextDouble() * cellSize * 3;
        slots.add(grid.insert(x, y, x + w, y + h));
      }

      final before = grid.length;
      for (var i = 0; i < 400; i++) {
        final slot = slots[rng.nextInt(slots.length)];
        final x = -4000 + rng.nextDouble() * 8000;
        final y = -4000 + rng.nextDouble() * 8000;
        final w = 1 + rng.nextDouble() * cellSize * 3;
        final h = 1 + rng.nextDouble() * cellSize * 3;
        grid.move(slot, x, y, x + w, y + h);
      }

      expect(
        grid.length,
        before,
        reason: 'a move must not hand out a slot; that is the leak it fixes',
      );
      expect(grid.liveLength, slots.length);

      final cx = -4000 + rng.nextDouble() * 8000;
      final cy = -4000 + rng.nextDouble() * 8000;
      final vw = 10 + rng.nextDouble() * 4000;
      final vh = 10 + rng.nextDouble() * 4000;

      final viaGrid = CullResult();
      final viaLinear = CullResult();
      grid.queryGrid(cx, cy, cx + vw, cy + vh, viaGrid);
      grid.queryLinear(cx, cy, cx + vw, cy + vh, viaLinear);
      expect(
        viaGrid.slots.toSet(),
        viaLinear.slots.toSet(),
        reason: 'trial $trial: a move left the buckets out of step with the '
            'bounds, so only the linear scan can still find the object',
      );
    }
  });

  test('a moved box is indexed nowhere it no longer covers', () {
    final grid = UniformGrid(cellSize: 100, capacity: 4);
    final slot = grid.insert(10, 10, 20, 20);

    grid.move(slot, 5000, 5000, 5010, 5010);

    final atOld = CullResult();
    grid.queryGrid(0, 0, 100, 100, atOld);
    expect(
      atOld.slots,
      isEmpty,
      reason: 'left behind in its old cell, a moved object is still hit at a '
          'place it no longer is',
    );

    final atNew = CullResult();
    grid.queryGrid(4990, 4990, 5020, 5020, atNew);
    expect(atNew.slots, [slot]);
  });

  test('moving a removed slot brings it back exactly once', () {
    final grid = UniformGrid(cellSize: 100, capacity: 4);
    final slot = grid.insert(10, 10, 20, 20);
    grid.remove(slot);
    expect(grid.liveLength, 0);

    grid.move(slot, 30, 30, 40, 40);

    expect(grid.liveLength, 1, reason: 'un-parking restores the live count');
    expect(grid.length, 1, reason: 'and still hands out no new slot');
    final found = CullResult();
    grid.queryGrid(25, 25, 45, 45, found);
    expect(found.slots, [slot]);
  });

  // Run with --platform chrome too: a 32-bit shift is zero in JavaScript and made a row one bucket.
  test('a query touches only the cell it covers, not the whole row', () {
    final grid = UniformGrid(cellSize: 100);
    for (var column = 0; column < 50; column++) {
      grid.insert(column * 100 + 10, 10, column * 100 + 20, 20);
    }
    final out = CullResult();
    grid.queryGrid(710, 10, 720, 20, out);
    expect(out.slots, hasLength(1));
    expect(out.candidates, 1);
  });

  test('cells left of and above the origin keep their own buckets', () {
    final grid = UniformGrid(cellSize: 100);
    grid.insert(-190, -190, -180, -180);
    grid.insert(-190, 110, -180, 120);
    grid.insert(110, -190, 120, -180);
    grid.insert(110, 110, 120, 120);
    final out = CullResult();
    grid.queryGrid(-190, -190, -180, -180, out);
    expect(out.slots, hasLength(1));
    expect(out.candidates, 1);
  });

  test('a reset grid does not skip a re-used slot on a stale stamp', () {
    final grid = UniformGrid(cellSize: 100);
    grid.insert(0, 0, 10, 10);
    final out = CullResult();
    for (var i = 0; i < 3; i++) {
      grid.queryGrid(0, 0, 10, 10, out);
    }

    grid.reset();
    grid.insert(0, 0, 10, 10);
    for (var i = 0; i < 2; i++) {
      grid.queryGrid(5000, 5000, 5010, 5010, out);
    }
    grid.queryGrid(0, 0, 10, 10, out);

    expect(out.slots.toList(), [0]);
  });
}
