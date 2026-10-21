// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The recent ops a canvas document applied, kept so a viewport page that
/// turns out older than the document can be brought forward without a request.
library;

import 'dart:collection';

import 'package:slimm_api/api.dart' as api;

/// How many ops are remembered; a page older than this is read again.
const int canvasOpLogCapacity = 1024;

class CanvasOpLog {
  final Queue<api.CanvasOp> _ops = Queue<api.CanvasOp>();
  int _floor = 0;

  /// Starts empty at [seq], the point the document is known to reflect.
  void reset(int seq) {
    _ops.clear();
    _floor = seq;
  }

  /// Whether every op above [seq] that this log was told about is still held.
  bool covers(int seq) => seq >= _floor;

  void add(api.CanvasOp op) {
    if (!_replayable(op)) return;
    _ops.add(op);
    while (_ops.length > canvasOpLogCapacity) {
      final dropped = _ops.removeFirst().seq;
      if (dropped > _floor) _floor = dropped;
    }
  }

  /// A restore above [seq] brings back objects a snapshot at [seq] never held,
  /// so replaying the ops around it over that snapshot cannot be right.
  bool restoredAfter(int seq) =>
      after(seq).any((op) => op is api.CanvasRestoreOp);

  Iterable<api.CanvasOp> after(int seq) => _ops.where((op) => op.seq > seq);

  /// Objects an op above [seq] changed or removed, which a snapshot taken at
  /// [seq] cannot speak for.
  Set<String> touchedAfter(int seq) => {
    for (final op in after(seq))
      ...switch (op) {
        api.CanvasRemoveOp(:final objectIds) => objectIds,
        api.CanvasMoveOp(:final objectId) ||
        api.CanvasReorderOp(:final objectId) ||
        api.CanvasEditOp(:final objectId) => [objectId],
        _ => const <String>[],
      },
  };

  static bool _replayable(api.CanvasOp op) =>
      op is api.CanvasRestoreOp ||
      op is api.CanvasRemoveOp ||
      op is api.CanvasClearOp ||
      op is api.CanvasMoveOp ||
      op is api.CanvasReorderOp ||
      op is api.CanvasEditOp;
}
