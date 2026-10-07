// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Property test for Phase 6's convergence exit criterion: two or more
/// clients applying the same canvas op log through different delivery
/// patterns must reach the same materialized state, with no
/// clear-resurrection, no image-move race, and no late-joiner double-apply.
///
/// This drives real production code - `CanvasDocument`, `CanvasSync`, and
/// `dispatchCanvasLiveEvent`, the exact three pieces `CanvasPane` wires
/// together, reached through `support/canvas_convergence_harness.dart` -
/// against a hand-rolled, independent oracle
/// (`support/canvas_convergence_model.dart`) that never calls into any of
/// them, so a bug shared between the generator and the apply logic could
/// not make the test pass by agreeing with itself.
///
/// What this covers: client-side materialization under three delivery
/// patterns per generated log - live events in seq order, live events in a
/// random (possibly gapped, possibly duplicated) order, and a late joiner
/// seeded from a mid-log snapshot then replaying the tail, with a duplicate
/// redelivery on top. Every pattern must converge to the same alive set,
/// the same positions, and the same tombstoned set as the oracle.
///
/// What this does NOT cover: the server's own concurrent-write path (two
/// real HTTP requests racing to allocate a `canvas_ops` seq) - that is
/// `crates/slimm-server/tests/canvas_ops/convergence.rs`'s job, and it
/// checks a different thing (that the durable log never drifts from the
/// live `canvas_objects` table under real concurrency), not this one. Nor
/// does this drive a real WebSocket or a real second browser tab; the
/// "two clients" in "two-client canvas session" are two independent
/// `CanvasDocument`/`CanvasSync` pairs fed the same canonical log, which is
/// the right unit for testing *delivery-order* resilience and the wrong
/// unit for testing the SFU-adjacent transport itself.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'support/canvas_convergence_harness.dart';
import 'support/canvas_convergence_model.dart';

CanvasStrokeInput _originalInputFor(CanvasLogOracle oracle, String id) {
  final seq = oracle.placementSeq[id]!;
  return CanvasStrokeInput(
    id: id,
    seq: seq,
    zIndex: seq,
    x: 0,
    y: 0,
    w: 1,
    h: 1,
    points: const [0, 0, 1, 1],
    width: 3,
    colorKey: 'annotation',
  );
}

/// Asserts [document] converged to exactly what [oracle] says a correct
/// client should show, covering all three named failure modes at once: an
/// alive/position mismatch is a move race or a missed op, a tombstoned id
/// that can still be re-placed is a clear/remove resurrection, and a
/// restored id that cannot be re-placed is undo silently not working.
///
/// [onlyIds], when given, restricts every check to that subset: the late
/// joiner pattern passes its own `reachableIds`, since an id both placed
/// and removed strictly before that client's own snapshot cut was never
/// mentioned to it at all, by any delivery pattern, and asserting a
/// tombstone against it would be asserting a client behaviour that never
/// had anything to behave on.
void expectConverged(
  CanvasDocument document,
  CanvasLogOracle oracle, {
  required String label,
  Set<String>? onlyIds,
}) {
  final ids = onlyIds ?? oracle.placementSeq.keys.toSet();
  expect(
    document.objectCount.value,
    ids.where(oracle.alive.containsKey).length,
    reason: '$label: alive object count',
  );
  for (final id in ids) {
    final wantAlive = oracle.alive.containsKey(id);
    expect(document.isAlive(id), wantAlive, reason: '$label: alive($id)');
    if (wantAlive) {
      final bounds = document.objectBounds(id)!;
      final want = oracle.alive[id]!;
      expect(bounds.x, closeTo(want.x, 1e-9), reason: '$label: x($id)');
      expect(bounds.y, closeTo(want.y, 1e-9), reason: '$label: y($id)');
      expect(bounds.w, closeTo(want.w, 1e-9), reason: '$label: w($id)');
      expect(bounds.h, closeTo(want.h, 1e-9), reason: '$label: h($id)');
    }
  }
  for (final id in oracle.tombstoned.where(ids.contains)) {
    expect(
      document.applyPlaced(_originalInputFor(oracle, id)),
      isNull,
      reason: '$label: clear/remove resurrection for $id',
    );
  }
  for (final id in ids) {
    if (oracle.alive.containsKey(id) || oracle.tombstoned.contains(id)) {
      continue;
    }
    expect(
      document.isAlive(id),
      isFalse,
      reason:
          '$label: a restored-but-unfetched object must stay invisible '
          '($id)',
    );
    expect(
      document.applyPlaced(_originalInputFor(oracle, id)),
      isNotNull,
      reason: '$label: a restore must actually lift the tombstone for $id',
    );
  }
}

void main() {
  group('canvas convergence', () {
    // Fewer seeds as JavaScript, which runs this about ten times slower; the point there is JS number semantics, not volume.
    final seeds = kIsWeb ? 10 : 40;
    test(
      'randomised logs converge across delivery patterns',
      timeout: const Timeout(Duration(minutes: 2)),
      () async {
        for (var seed = 0; seed < seeds; seed++) {
          final log = CanvasLogGenerator(seed).generate(40);
          final oracle = CanvasLogOracle.replay(log);
          final rng = math.Random(seed);

          expectConverged(
            await liveInOrder('seed-$seed-a', log),
            oracle,
            label: 'seed $seed / live in order',
          );
          expectConverged(
            await liveScrambled('seed-$seed-b', log, rng),
            oracle,
            label: 'seed $seed / live scrambled',
          );
          final joined = await lateJoiner('seed-$seed-c', log, rng);
          expectConverged(
            joined.document,
            oracle,
            label: 'seed $seed / late joiner',
            onlyIds: joined.reachableIds,
          );
        }
      },
    );

    test('a remove tombstones an id this client never placed at all - the '
        'viewport-read-in-flight race the tombstone set exists for, where the '
        'freed-slot check the other tests exercise cannot help because there '
        'is no slot to free', () {
      final document = CanvasDocument();
      document.removeObject('never-placed');
      final replay = document.applyPlaced(
        const CanvasStrokeInput(
          id: 'never-placed',
          seq: 1,
          zIndex: 1,
          x: 0,
          y: 0,
          w: 1,
          h: 1,
          points: [0, 0, 1, 1],
          width: 3,
          colorKey: 'annotation',
        ),
      );
      expect(
        replay,
        isNull,
        reason: 'a late viewport response must not resurrect it',
      );
    });

    test('a clear does not resurrect an object whose place op is delivered '
        'after it, out of order', () async {
      final log = <CanonOp>[
        CanonPlace(1, 'a', 0, 0, 10, 10),
        const CanonClear(2, 'clear-1', 1, ['a']),
      ];
      final oracle = CanvasLogOracle.replay(log);
      final receiver = CanvasReceiver('clear-race', log);
      receiver.sync.seedFromViewport(0);

      // The clear (seq 2) arrives before the place (seq 1) it depends on.
      receiver.deliver(log[1]);
      await settle();
      receiver.deliver(log[0]);
      await settle();
      await receiver.sync.catchUp();

      expectConverged(receiver.document, oracle, label: 'clear race');
    });

    test('two moves on the same object converge to the last one by seq, not '
        'delivery order', () async {
      final log = <CanonOp>[
        CanonPlace(1, 'img', 0, 0, 50, 50),
        const CanonMove(2, 'mv-1', 'img', 100, 100, 50, 50),
        const CanonMove(3, 'mv-2', 'img', 200, 200, 50, 50),
      ];
      final oracle = CanvasLogOracle.replay(log);
      final receiver = CanvasReceiver('move-race', log);
      receiver.sync.seedFromViewport(0);

      // The winning move (seq 3) is delivered before the ops it followed.
      receiver.deliver(log[2]);
      await settle();
      receiver.deliver(log[1]);
      receiver.deliver(log[0]);
      await settle();
      await receiver.sync.catchUp();

      expectConverged(receiver.document, oracle, label: 'move race');
      final bounds = receiver.document.objectBounds('img')!;
      expect(bounds.x, 200, reason: 'the higher-seq move must win');
      expect(bounds.y, 200, reason: 'the higher-seq move must win');
    });

    test('a late joiner who snapshots then replays the tail does not '
        'double-apply a redelivered op', () async {
      final log = <CanonOp>[
        CanonPlace(1, 'x', 0, 0, 10, 10),
        const CanonMove(2, 'mv-1', 'x', 50, 50, 10, 10),
      ];
      final oracle = CanvasLogOracle.replay(log);
      final receiver = CanvasReceiver('late-joiner', log);

      // The snapshot already knows 'x' at its placement position.
      receiver.document.applyPlaced(
        const CanvasStrokeInput(
          id: 'x',
          seq: 1,
          zIndex: 1,
          x: 0,
          y: 0,
          w: 10,
          h: 10,
          points: [0, 0, 10, 10],
          width: 3,
          colorKey: 'annotation',
        ),
      );
      receiver.sync.seedFromViewport(1);
      await receiver.sync.catchUp();

      // The move that catch-up already applied arrives again live.
      receiver.deliver(log[1]);
      await settle();

      expectConverged(receiver.document, oracle, label: 'late joiner');
      expect(
        receiver.document.objectCount.value,
        1,
        reason: 'a duplicate redelivery must not create a second object',
      );
    });
  });
}
