// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one sentence `canvas_commit_queue.dart`, `canvas_quick_placement.dart`
/// and `canvas_image_paste.dart` each show for a draw refused with
/// `ApiException.forbidden`.
///
/// The server refuses a place/move/reorder for exactly two reasons: the
/// caller cannot view or use this channel's canvas at all, or the caller is
/// timed out (`http/canvas_write.rs`'s and `http/canvas_ops_write.rs`'s own
/// direct `timed_out_until` check, which freezes the pen without touching
/// `USE_CANVAS` - a timed-out member keeps seeing the canvas, just cannot
/// add to it). Nothing in the 403 body says which, so this reads the
/// caller's own already-fetched `Me.timedOutUntil` instead of adding a new
/// wire field for a distinction the client can already tell apart.
library;

import '../../format.dart';

/// [timedOutUntil] is the caller's own `Me.timedOutUntil` as read at the
/// moment the refusal is being explained, Unix milliseconds or null. Read
/// fresh rather than cached at pane-mount, since a timeout can start or
/// lapse while the pane stays open.
String canvasDrawForbiddenMessage(int? timedOutUntil) {
  if (timedOutUntil == null) {
    return "You don't have permission to draw here right now.";
  }
  final remaining = DateTime.fromMillisecondsSinceEpoch(
    timedOutUntil,
  ).difference(DateTime.now());
  if (remaining.isNegative) {
    // Lapsed between the refusal landing and this being read: nothing left to name.
    return "You don't have permission to draw here right now.";
  }
  return "You're timed out and can't draw for another "
      '${formatRemaining(remaining)}.';
}
