// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The `+1` adjacency test a live op frame is judged by, used by the message
/// op stream (`message_ops_sync.dart`, `sync_controller.dart`). The canvas op
/// stream has its own reducer (`canvas_sync.dart`, decision 0087).
///
/// The stream is dense - one seq per mutation - so `seq == cursor + 1` is a
/// real "exactly the next op" test rather than a heuristic. Delivery order
/// across concurrent writers is best-effort, so a frame two ahead of the cursor
/// means something in between has not been seen; applying it anyway would move
/// the cursor past that gap forever.
library;

/// What a live op frame asks the caller to do.
enum LiveOpOutcome {
  /// Already applied, or older than the cursor. Nothing to do.
  ignored,

  /// Exactly the next op: apply it and advance the cursor.
  applied,

  /// A gap, so the payload must not be applied. Reconcile (catch up) instead.
  needsReconcile,
}

/// Decides what to do with one live op named [opSeq], given the current
/// [cursor], by the `+1` adjacency test.
///
/// A null [opSeq] is an old server with no op stream, and a null [cursor] is a
/// stream not yet seeded; either way the frame is applied the way it always was
/// and no cursor moves, because there is none to move.
LiveOpOutcome liveOpDecision(int? opSeq, int? cursor) {
  if (opSeq == null || cursor == null) return LiveOpOutcome.applied;
  if (opSeq <= cursor) return LiveOpOutcome.ignored;
  if (opSeq == cursor + 1) return LiveOpOutcome.applied;
  return LiveOpOutcome.needsReconcile;
}
