// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Paging the rest of a board after the visible area: tiles are split when the
/// server could not return one whole, and a tile that stays crowded is reported.
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_board_pager.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_sync.dart';

const _board = Rect.fromLTWH(0, 0, 1920, 1080);
const _world = Rect.fromLTRB(-5000, -5000, 5000, 5000);

api.CanvasViewport _page({required bool more}) =>
    api.CanvasViewport(objects: const [], hasMore: more, latestSeq: 1);

void main() {
  test('a board that fits in one read is read once per seed tile', () async {
    final read = <Rect>[];
    final pager = CanvasBoardPager(
      read: (tile) async {
        read.add(tile);
        return _page(more: false);
      },
      apply: (_, _) => CanvasPageOutcome.applied,
      onProgress: (_) {},
      isCancelled: () => false,
    );

    final complete = await pager.run(CanvasBoardPager.seedsFor(_board, _world));

    expect(complete, isTrue);
    expect(
      read,
      hasLength(5),
      reason: 'the board and the four strips around it',
    );
    expect(read.first, _board, reason: 'the board comes before the rest');
  });

  test('a crowded tile is split until the server can answer it', () async {
    final read = <Rect>[];
    final pager = CanvasBoardPager(
      read: (tile) async {
        read.add(tile);
        return _page(more: tile.width > 500);
      },
      apply: (_, _) => CanvasPageOutcome.applied,
      onProgress: (_) {},
      isCancelled: () => false,
    );

    final complete = await pager.run([_board]);

    expect(complete, isTrue);
    expect(read.where((t) => t.width <= 500), isNotEmpty);
    expect(read.first, _board);
  });

  test('a tile that stays crowded at the smallest size is reported', () async {
    final pager = CanvasBoardPager(
      read: (_) async => _page(more: true),
      apply: (_, _) => CanvasPageOutcome.applied,
      onProgress: (_) {},
      isCancelled: () => false,
    );

    expect(await pager.run([const Rect.fromLTWH(0, 0, 64, 64)]), isFalse);
  });

  test('progress carries the first total the server reports', () async {
    final totals = <int?>[];
    final pager = CanvasBoardPager(
      read: (_) async => const api.CanvasViewport(
        objects: [],
        hasMore: false,
        latestSeq: 1,
        totalObjects: 321,
      ),
      apply: (_, _) => CanvasPageOutcome.applied,
      onProgress: totals.add,
      isCancelled: () => false,
    );

    await pager.run([_board, _board]);

    expect(totals, [321, 321]);
  });

  test(
    'a page older than the document is read again, then given up on',
    () async {
      var reads = 0;
      final pager = CanvasBoardPager(
        read: (_) async {
          reads++;
          return _page(more: false);
        },
        apply: (_, _) => CanvasPageOutcome.stale,
        onProgress: (_) {},
        isCancelled: () => false,
      );

      await pager.run([_board]);

      expect(reads, maxStaleTileReads);
    },
  );

  test('cancelling stops the walk', () async {
    var reads = 0;
    var cancelled = false;
    final pager = CanvasBoardPager(
      read: (_) async {
        reads++;
        cancelled = true;
        return _page(more: false);
      },
      apply: (_, _) => CanvasPageOutcome.applied,
      onProgress: (_) {},
      isCancelled: () => cancelled,
    );

    await pager.run(CanvasBoardPager.seedsFor(_board, _world));

    expect(reads, 1);
  });

  test(
    'a board that is always crowded stops after a bounded number of reads',
    () async {
      var reads = 0;
      final pager = CanvasBoardPager(
        read: (_) async {
          reads++;
          return _page(more: true);
        },
        apply: (_, _) => CanvasPageOutcome.applied,
        onProgress: (_) {},
        isCancelled: () => false,
      );

      final complete = await pager.run(
        CanvasBoardPager.seedsFor(_board, _world),
      );

      expect(complete, isFalse);
      expect(reads, maxPagedReads);
    },
  );
}
