// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every ordering of a short op log, not a sample of them: each permutation of
/// live delivery crossed with every point a catch-up can fire at, against a feed
/// that answers whole or a page at a time, and a late joiner seeded from every cut.
/// The randomised property test samples; this one cannot miss an order.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_convergence_property_test.dart' show expectConverged;
import 'support/canvas_convergence_harness.dart';
import 'support/canvas_convergence_model.dart';

/// A log that exercises the dependent pairs: a move after its place, a remove, and a later place.
final _log = <CanonOp>[
  CanonPlace(1, 'a', 0, 0, 10, 10),
  CanonPlace(2, 'b', 50, 50, 10, 10),
  const CanonMove(3, 'mv1', 'a', 20, 20, 10, 10),
  const CanonRemove(4, 'rm1', ['b']),
  CanonPlace(5, 'c', 90, 90, 10, 10),
];

Iterable<List<T>> _permutations<T>(List<T> items) sync* {
  if (items.length <= 1) {
    yield [...items];
    return;
  }
  for (var i = 0; i < items.length; i++) {
    final rest = [...items]..removeAt(i);
    for (final tail in _permutations(rest)) {
      yield [items[i], ...tail];
    }
  }
}

void main() {
  final oracle = CanvasLogOracle.replay(_log);

  for (final pageSize in <int?>[null, 2]) {
    test(
      'every live order and catch-up point converges (pages of '
      '${pageSize ?? 'all'})',
      timeout: const Timeout(Duration(minutes: 4)),
      () async {
        var runs = 0;
        for (final order in _permutations(_log)) {
          for (var catchUpAt = 0; catchUpAt <= order.length; catchUpAt++) {
            for (final overlapped in [false, true]) {
              var published = 0;
              final receiver = CanvasReceiver(
                'order-$runs',
                _log,
                pageSize: pageSize,
                publishedThrough: () => published,
              );
              receiver.sync.seedFromViewport(0);
              Future<void>? running;
              for (var i = 0; i < order.length; i++) {
                if (i == catchUpAt) {
                  // Overlapped, the frames that follow arrive while this read is in flight.
                  running = receiver.sync.catchUp();
                  if (!overlapped) await running;
                }
                // The feed grows as frames arrive: an op is in the log once any frame at or past it has been sent.
                published = math.max(published, order[i].seq);
                receiver.deliver(order[i]);
                if (overlapped) {
                  await Future<void>.delayed(Duration.zero);
                } else {
                  await settle();
                }
              }
              published = _log.length;
              if (catchUpAt == order.length) {
                running = receiver.sync.catchUp();
              }
              await running;
              await settle();
              // An overlapped run gets no extra read: the dropped request is what it is for.
              if (!overlapped) await receiver.sync.catchUp();
              expectConverged(
                receiver.document,
                oracle,
                label:
                    'order ${order.map((o) => o.seq).join()} catch-up at '
                    '$catchUpAt${overlapped ? ' overlapped' : ''}',
              );
              runs++;
            }
          }
        }
        expect(runs, 120 * 6 * 2);
      },
    );
  }

  test(
    'a late joiner converges from every cut, with the tail delivered in '
    'every order',
    timeout: const Timeout(Duration(minutes: 4)),
    () async {
      for (var cut = 0; cut <= _log.length; cut++) {
        final snapshot = CanvasLogOracle.replay(
          _log.where((o) => o.seq <= cut).toList(),
        );
        final tail = _log.where((o) => o.seq > cut).toList();
        for (final order in _permutations(tail)) {
          final receiver = CanvasReceiver('join-$cut', _log, pageSize: 2);
          for (final entry in snapshot.alive.entries) {
            final seq = snapshot.placementSeq[entry.key]!;
            receiver.document.applyPlaced(
              CanvasStrokeInput(
                id: entry.key,
                seq: seq,
                zIndex: seq,
                x: entry.value.x,
                y: entry.value.y,
                w: entry.value.w,
                h: entry.value.h,
                points: [0, 0, entry.value.w, entry.value.h],
                width: 3,
                colorKey: 'annotation',
              ),
            );
          }
          receiver.sync.seedFromViewport(cut);
          for (final op in order) {
            receiver.deliver(op);
            await settle();
          }
          await receiver.sync.catchUp();
          final reachable = snapshot.alive.keys.toSet();
          for (final op in tail) {
            if (op is CanonPlace) reachable.add(op.id);
          }
          expectConverged(
            receiver.document,
            oracle,
            label: 'cut $cut tail ${order.map((o) => o.seq).join()}',
            onlyIds: reachable,
          );
        }
      }
    },
  );
}
