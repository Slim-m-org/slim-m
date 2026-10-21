// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Paging the rest of a board after the visible area, by seq cursor.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_board_pager.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_sync.dart';

api.CanvasViewport _page({int? next, bool more = false, int? total}) =>
    api.CanvasViewport(
      objects: const [],
      hasMore: more,
      latestSeq: 1,
      nextCursor: next,
      totalObjects: total,
    );

CanvasBoardPager _pager(
  Future<api.CanvasViewport> Function(int cursor) read, {
  CanvasPageOutcome Function(api.CanvasViewport page)? apply,
  void Function(int? total)? onProgress,
  bool Function()? isCancelled,
}) => CanvasBoardPager(
  read: read,
  apply: apply ?? (_) => CanvasPageOutcome.applied,
  onProgress: onProgress ?? (_) {},
  isCancelled: isCancelled ?? () => false,
);

void main() {
  test('pages follow the cursor until the server has no more', () async {
    final asked = <int>[];
    final pager = _pager((cursor) async {
      asked.add(cursor);
      return cursor < 20 ? _page(next: cursor + 10, more: true) : _page();
    });

    expect(await pager.run(), isTrue);
    expect(asked, [0, 10, 20]);
  });

  test('progress carries the first total the server reports', () async {
    final totals = <int?>[];
    final pager = _pager(
      (cursor) async =>
          cursor == 0 ? _page(next: 5, total: 321) : _page(total: 999),
      onProgress: totals.add,
    );

    await pager.run();

    expect(totals, [321, 321]);
  });

  test(
    'a server that cannot page leaves the board reported incomplete',
    () async {
      final pager = _pager((_) async => _page(more: true));

      expect(await pager.run(), isFalse);
    },
  );

  test(
    'a page older than the document is read again, then given up on',
    () async {
      var reads = 0;
      final pager = _pager((_) async {
        reads++;
        return _page();
      }, apply: (_) => CanvasPageOutcome.stale);

      expect(await pager.run(), isFalse);
      expect(reads, maxStaleTileReads);
    },
  );

  test('cancelling stops the walk', () async {
    var reads = 0;
    var cancelled = false;
    final pager = _pager((_) async {
      reads++;
      cancelled = true;
      return _page(next: 9, more: true);
    }, isCancelled: () => cancelled);

    expect(await pager.run(), isFalse);
    expect(reads, 1);
  });

  test(
    'a cursor that never ends stops after a bounded number of pages',
    () async {
      var reads = 0;
      final pager = _pager((_) async {
        reads++;
        return _page(next: reads, more: true);
      });

      expect(await pager.run(), isFalse);
      expect(reads, maxPagedReads);
    },
  );
}
